# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A homelab provisioning repo: a Nix flake builds NixOS images for Proxmox, and OpenTofu uses the `bpg/proxmox` provider to upload those images and create VMs on a Proxmox host (`pve`).

## Build / deploy commands

The flake exposes four image packages — each `nix build` produces a symlink that the Terraform layer reads via `TF_VAR_nixos_*_*_path` (set in `.envrc`):

```sh
nix build .#proxmox-lxc      -o nixos-lxc        # base LXC tarball
nix build .#proxmox-lxc-dns  -o nixos-lxc-dns    # dns LXC tarball (unbound)
nix build .#proxmox-vm       -o nixos-vm         # base VM qcow2
nix build .#proxmox-vm-k3s   -o nixos-vm-k3s     # k3s VM qcow2
```

Apply infrastructure (devShell provides `opentofu`; direnv loads it automatically):

```sh
cd terraform && tofu init && tofu plan && tofu apply
```

In-place rebuild on a running host (uses `nixosConfigurations.{nixos,base,k3s,dns}`) — this is the normal way to roll changes out, not a VM rebuild via Terraform:

```sh
nixos-rebuild switch --flake .#k3s --target-host admin@<ip> --sudo
nixos-rebuild switch --flake .#dns --target-host admin@<ip> --sudo
```

- **No local `sudo`.** With `--target-host`, nixos-rebuild only needs to read the local nix store and SSH out; both work as a normal user. Running it under `sudo` makes the SSH client run as root, which then fails to find `~/.ssh/homelab` and dies with `Permission denied (publickey)`.
- **`--sudo`** elevates the *remote* activation step, which is needed because `admin@` has no direct root over SSH. Passwordless wheel sudo on the target (set in `nixos/proxmox.nix`) makes this transparent. (`--use-remote-sudo` is the deprecated alias of the same flag.)
- **SSH key.** The repo provisions `~/.ssh/homelab` as the authorized key for `admin`. Either set it in `~/.ssh/config` (`IdentityFile ~/.ssh/homelab` for the host) or pass it ad-hoc with `NIX_SSHOPTS="-i ~/.ssh/homelab"`. Get the current IP from `tofu output -json nixos_vm_ipv4 | jq -r '.[0]'` (or use `k3s.local` if mDNS resolves from your shell).

## Workflow: who owns what

Three tools, three non-overlapping responsibilities. Don't reach across the line.

- **Terraform** owns external APIs only — VM lifecycle on Proxmox (cores/RAM/disk/vmid/network), and any future DNS/firewall resources. Run `tofu apply` to create or replace a VM. `lifecycle.ignore_changes = [disk[0].import_from]` makes re-runs no-ops when only the image hash changed; that's deliberate.
- **NixOS** owns the OS interior — packages, services, k3s, the auto-deploy manifests that bootstrap ingress-nginx + ArgoCD. Day-to-day changes flow through `nixos-rebuild` against a *running* VM, not via Terraform replacing it.
- **ArgoCD** owns everything inside the cluster after bootstrap — workloads under `gitops/`, drift detection, sync. Once Argo is up, neither Terraform nor NixOS should touch cluster resources.

When to actually re-run Terraform: first-time provisioning, you changed something Terraform owns (cores, RAM, vmid), the VM is unrecoverable, or you want to validate that a fresh image self-bootstraps end-to-end (`tofu apply -replace=proxmox_virtual_environment_vm.nixos`).

## Architecture

- **`flake.nix`** wires three things: (1) `packages.*` use `nixos-generators` to bake images for Proxmox, (2) `nixosConfigurations.*` are the same modules exposed as full systems for `nixos-rebuild`, (3) `devShells.default` provides `opentofu`. Image modules are layered: `proxmox.nix` is the base for VM images; `k3s.nix` adds on top of it. `host.nix` + `disko.nix` are used by `nixosConfigurations.nixos` for the disko-anywhere bootstrap path.
- **`nixos/proxmox.nix`** is the canonical VM base — qemu-guest, GRUB, DHCP, mDNS, sshd (key-only), `admin` user with hardcoded SSH key, flakes enabled. Anything that should be true on every VM lives here.
- **`nixos/k3s.nix`** layers a single-node k3s server (traefik disabled) on top of the base. Forces hostname to `k3s`, opens the API/kubelet/flannel ports, disables swap.
- **`nixos/proxmox-lxc.nix`** is the LXC counterpart to `proxmox.nix` — same admin user, mDNS, sshd, flakes, but stripped of kernel/bootloader/qemu-guest concerns (LXC shares the host kernel). Use this as the base for any future LXC.
- **`nixos/dns.nix`** layers an `unbound` resolver on top of the LXC base for the LAN DNS server. Forces hostname to `dns` (via `lib.mkOverride 49` to win against the upstream proxmox-lxc image module's `mkForce ""`), opens port 53.
- **`nixos/build-server.nix`** and **`nixos/file-server.nix`** define optional nginx-based hosts (image build cron, file serving) — not currently wired into any `nixosConfigurations`.
- **`terraform/main.tf`** uploads images to Proxmox `local` and creates two guests on node `pve`: VM 300 (`nixos`, k3s) imports a qcow2; LXC 200 (`dns`) is a container created from a `vztmpl` tarball. Both use `lifecycle.ignore_changes` on the image source so re-runs don't recreate the guest when only the image hash changed.

### GitOps layout

The k3s VM bootstraps itself into a working GitOps state with no manual `kubectl` step. `nixos/k3s.nix` writes three resources into the k3s auto-deploy directory via `services.k3s.manifests`: an `ingress-nginx` `HelmChart`, an `argo-cd` `HelmChart` (with an Ingress at `argocd.k3s.local`), and a single root `Application` pointing at `gitops/argocd/` in this repo. From there ArgoCD takes over: every YAML in `gitops/argocd/` is a child `Application` describing one workload, and each one references its actual manifests under `gitops/manifests/<name>/`. To add a new service: drop manifests into `gitops/manifests/<name>/`, add `gitops/argocd/<name>.yaml` pointing at it, commit — no rebuild required.

### LAN DNS

The `dns` LXC runs `unbound` and is the LAN's resolver. It answers `*.lan` with the k3s ingress IP (hardcoded in `nixos/dns.nix` as `ingressIp`) and forwards everything else to `1.1.1.1` / `1.0.0.1`. Once the router's DHCP option 6 points clients at the LXC's IP, `argocd.lan` / `grafana.lan` / etc. just work — you only need to add an `Ingress` with the right host header in the cluster, no per-device hosts-file edits. **Why an LXC, not a VM, and why outside the cluster:** DNS is foundational — putting it in k3s would mean LAN-wide name resolution dies during cluster maintenance. An LXC has ~30MB RAM overhead vs. ~500MB for a VM and uses the same NixOS workflow.

## Configuration / secrets

- `.envrc` (committed) sets `TF_VAR_nixos_*_image_path` to `$PWD/nixos-*` and `KUBECONFIG=$PWD/.kubeconfig`.
- `.envrc.local` (gitignored) sets Proxmox endpoint + API token for the provider — see `terraform/provider.tf`.
- `local.node_name = "pve"` in `terraform/locals.tf` is the Proxmox node; change there if your node has a different name.
- Authorized SSH keys are inlined in `nixos/proxmox.nix`, `nixos/proxmox-lxc.nix`, and `nixos/host.nix` — update all three when rotating.

## MCP servers

`.mcp.json` registers `terraform` (HashiCorp registry tooling) and `nixos` (NixOS package/option search) — prefer these over web search when looking up provider arguments or NixOS options.
