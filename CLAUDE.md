# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A homelab provisioning repo: a Nix flake builds NixOS images for Proxmox, and OpenTofu uses the `bpg/proxmox` provider to upload those images and create VMs on a Proxmox host (`pve`).

## Build / deploy commands

The flake exposes four image packages — each `nix build` produces a symlink that the Terraform layer reads via `TF_VAR_nixos_*_*_path` (set in `.envrc`):

```sh
nix build .#proxmox-lxc             -o nixos-lxc               # base LXC tarball (no consumer yet — see "LAN DNS" below)
nix build .#proxmox-vm              -o nixos-vm                # base VM qcow2
nix build .#proxmox-vm-k3s-server   -o nixos-vm-k3s-server     # k3s server VM qcow2
nix build .#proxmox-vm-dns          -o nixos-vm-dns            # dns VM qcow2 (unbound)
```

Refresh the local `.kubeconfig` after the k3s VM is recreated or its IP changes (the devShell exposes this as a script):

```sh
refresh-kubeconfig    # SCPs /etc/rancher/k3s/k3s.yaml off the k3s VM, rewrites server URL to its LAN IP
```

Apply infrastructure (devShell provides `opentofu`; direnv loads it automatically):

```sh
cd terraform && tofu init && tofu plan && tofu apply
```

In-place rebuild on a running host (uses `nixosConfigurations.{nixos,base,k3s-server,base-lxc,dns}`) — this is the normal way to roll changes out, not a VM rebuild via Terraform:

```sh
nixos-rebuild switch --flake .#k3s-server --target-host admin@<ip> --sudo
nixos-rebuild switch --flake .#dns        --target-host admin@<ip> --sudo
```

- **No local `sudo`.** With `--target-host`, nixos-rebuild only needs to read the local nix store and SSH out; both work as a normal user. Running it under `sudo` makes the SSH client run as root, which then fails to find `~/.ssh/homelab` and dies with `Permission denied (publickey)`.
- **`--sudo`** elevates the *remote* activation step, which is needed because `admin@` has no direct root over SSH. Passwordless wheel sudo on the target (set in `nixos/proxmox.nix`) makes this transparent. (`--use-remote-sudo` is the deprecated alias of the same flag.)
- **SSH key.** The repo provisions `~/.ssh/homelab` as the authorized key for `admin`. Either set it in `~/.ssh/config` (`IdentityFile ~/.ssh/homelab` for the host) or pass it ad-hoc with `NIX_SSHOPTS="-i ~/.ssh/homelab"`. Get the current IP from `tofu output -json k3s_server_vm_ipv4 | jq -r '.[0][0]'` (or use `k3s.local` if mDNS resolves from your shell).

## Workflow: who owns what

Three tools, three non-overlapping responsibilities. Don't reach across the line.

- **Terraform** owns external APIs only — VM lifecycle on Proxmox (cores/RAM/disk/vmid/network), and any future DNS/firewall resources. Run `tofu apply` to create or replace a VM. `lifecycle.ignore_changes = [disk[0].import_from]` makes re-runs no-ops when only the image hash changed; that's deliberate.
- **NixOS** owns the OS interior — packages, services, k3s, the auto-deploy manifests that bootstrap ingress-nginx + ArgoCD. Day-to-day changes flow through `nixos-rebuild` against a *running* VM, not via Terraform replacing it.
- **ArgoCD** owns everything inside the cluster after bootstrap — workloads under `gitops/`, drift detection, sync. Once Argo is up, neither Terraform nor NixOS should touch cluster resources.

When to actually re-run Terraform: first-time provisioning, you changed something Terraform owns (cores, RAM, vmid), the VM is unrecoverable, or you want to validate that a fresh image self-bootstraps end-to-end (`tofu apply -replace=proxmox_virtual_environment_vm.k3s_server`).

## Architecture

- **`flake.nix`** wires three things: (1) `nixosConfigurations.*` are full system definitions, (2) `packages.*` are thin wrappers that pull `config.system.build.images.<variant>` off the corresponding configuration (using upstream nixpkgs image infrastructure — `nixos-generators` is no longer used; it was upstreamed in NixOS 25.05). VM packages use the `qemu` variant (produces qcow2); LXC packages use the `proxmox-lxc` variant (produces tar.xz). The `extractFile` helper unwraps the variant's output directory into a single-file derivation so Terraform's `filesha256` can read it. (3) `devShells.default` provides `opentofu`. Image modules are layered: `proxmox.nix` is the base for VMs; `proxmox-lxc.nix` is the base for LXCs; `k3s-server.nix` and `dns.nix` add on top.
- **`nixos/proxmox.nix`** is the canonical VM base — qemu-guest, GRUB, DHCP, mDNS, sshd (key-only), `admin` user with hardcoded SSH key, flakes enabled. Anything that should be true on every VM lives here.
- **`nixos/k3s-server.nix`** layers an all-in-one k3s node (control plane + agent, traefik disabled) on top of the base. Forces hostname to `k3s`, opens the API/kubelet/flannel ports, disables swap.
- **`nixos/proxmox-lxc.nix`** is the LXC counterpart to `proxmox.nix` — same admin user, mDNS, sshd, flakes, but stripped of kernel/bootloader/qemu-guest concerns (LXC shares the host kernel). Currently has no consumer (`base-lxc` config exists but isn't deployed); kept ready for the LXC migration described under "LAN DNS" below.
- **`nixos/dns.nix`** layers an `unbound` resolver on top of the VM base (`proxmox.nix`) for the LAN DNS server. Forces hostname to `dns`, opens port 53. Should ideally run on `proxmox-lxc.nix` instead — see the TODO under "LAN DNS".
- **`nixos/build-server.nix`** and **`nixos/file-server.nix`** define optional nginx-based hosts (image build cron, file serving) — not currently wired into any `nixosConfigurations`.
- **`terraform/main.tf`** uploads images to Proxmox `local` and creates two VMs on node `pve`: VM 300 (`k3s_server`, the all-in-one k3s node) and VM 200 (`dns`). Both import qcow2s. Both use `lifecycle.ignore_changes` on the image source so re-runs don't recreate the guest when only the image hash changed. (DNS is a VM rather than an LXC for now — see "LAN DNS".)

### GitOps layout

The k3s VM bootstraps itself into a working GitOps state with no manual `kubectl` step. `nixos/k3s-server.nix` writes three resources into the k3s auto-deploy directory via `services.k3s.manifests`: an `ingress-nginx` `HelmChart`, an `argo-cd` `HelmChart` (with an Ingress at `argocd.k3s.local`), and a single root `Application` pointing at `gitops/argocd/` in this repo. From there ArgoCD takes over: every YAML in `gitops/argocd/` is a child `Application` describing one workload, and each one references its actual manifests under `gitops/manifests/<name>/`. To add a new service: drop manifests into `gitops/manifests/<name>/`, add `gitops/argocd/<name>.yaml` pointing at it, commit — no rebuild required.

### LAN DNS

The `dns` VM (vmid 200) runs `unbound` and is the LAN's resolver. It answers `*.lan` with the k3s ingress IP (hardcoded in `nixos/dns.nix` as `ingressIp`) and forwards everything else to `1.1.1.1` / `1.0.0.1`. Once the router's DHCP option 6 points clients at the VM's IP, `argocd.lan` / `grafana.lan` / etc. just work — add an `Ingress` with the right host header in the cluster, no per-device hosts-file edits. DNS lives **outside** the cluster (separate guest, not a k8s pod) so LAN-wide name resolution doesn't die during cluster maintenance.

**TODO — move dns back to an LXC.** The original design ran dns as an LXC (~30MB RAM vs. ~500MB for a VM, same NixOS workflow). It's a VM today only because Proxmox refused to let our non-root API token set the `keyctl` feature flag, which systemd 259's credential subsystem needs in unprivileged LXCs (otherwise `systemd-networkd` fails with `243/CREDENTIALS` and the container never gets an IP). Two paths to flip back:

1. **Create a `root@pam` API token** (Proxmox UI → Datacenter → Permissions → API Tokens, with Privilege Separation off), put it in `.envrc.local`. Then add `features { keyctl = true; nesting = true; }` back to the LXC resource in `terraform/main.tf`. Proxmox restricts feature-flag changes to literal `root@pam` — no role you can grant a regular token unlocks it; the check is identity-based, not permission-based.
2. **Pre-create the LXC manually with `pct`** (logged in as root on the Proxmox host) with the right features, then `terraform import` it and add `lifecycle { ignore_changes = [features] }`.

The flake is structured for the flip: `nixosConfigurations.base-lxc` + `packages.proxmox-lxc` already exist, and `nixos/dns.nix` only needs `lib.mkForce "dns"` → `lib.mkOverride 49 "dns"` reverted (the upstream proxmox-lxc image module's `mkForce ""` collides otherwise). See `# TODO(dns-as-lxc)` markers in `flake.nix` and `terraform/main.tf`.

## Configuration / secrets

- `.envrc` (committed) sets `TF_VAR_*_image_path` to `$PWD/nixos-*` and `KUBECONFIG=$PWD/.kubeconfig`.
- `.envrc.local` (gitignored) sets the Proxmox endpoint + API token for the bpg provider. **`.envrc.local.example` is the canonical schema** — copy it to `.envrc.local`, fill in real values, run `direnv allow`. When adding a new local-only env var, update the `.example` file in the same change so the docs stay current.
- **`nixos/lan.nix`** (gitignored) holds LAN topology values (`ingressIp`, `lanCidr`) used by `nixos/dns.nix`. **`nixos/lan.example.nix`** is the schema. Bootstrap on a fresh clone:
  ```sh
  cp nixos/lan.example.nix nixos/lan.nix
  # edit with real values
  git add -fN nixos/lan.nix    # --force --intent-to-add so the flake can read it
  ```
  Without the `git add -fN`, `nix build` / `nixos-rebuild` fails with `path nixos/lan.nix does not exist` — flakes only see git-tracked or intent-to-add'd files. Same pattern as `.envrc.local` but at the file layer, because Nix can't read env vars at eval time without breaking pure flakes. When adding a new value, update both `lan.nix` and `lan.example.nix` in the same change.
- `local.node_name = "pve"` in `terraform/locals.tf` is the Proxmox node; change there if your node has a different name.
- Authorized SSH keys are inlined in `nixos/proxmox.nix`, `nixos/proxmox-lxc.nix`, and `nixos/host.nix` — update all three when rotating.

## MCP servers

`.mcp.json` registers `terraform` (HashiCorp registry tooling) and `nixos` (NixOS package/option search) — prefer these over web search when looking up provider arguments or NixOS options.
