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

### Workload image strategy

Workloads currently run as **vanilla container images** (whatever ArgoCD pulls from upstream registries via the manifests under `gitops/`). When image bloat actually starts to hurt, there's a spectrum of progressively smaller options that lean on the k3s node's Nix store:

1. **Vanilla containers** *(current)* — biggest images, full upstream ecosystem. ArgoCD just deploys what's on Docker Hub / GHCR.
2. **Nix-built OCI images** — `pkgs.dockerTools.buildLayeredImage` produces images with no distro base layer; each store path becomes its own layer, so containerd's content-addressed storage dedups across all Nix-built images on the node. Push to a registry (in-cluster or external), reference from manifests, ArgoCD flow is unchanged. Meaningful savings, normal k8s.
3. **nix-snapshotter** (`pdtpartners/nix-snapshotter`) — containerd plugin: pods reference Nix store paths directly and are materialized from the host's `/nix/store` instead of pulled as image layers. Anything the host already has costs zero extra disk. ArgoCD doesn't care; the magic is below containerd. Smallest possible workloads while staying in k8s, but it's a custom containerd plugin — extra moving part on the node, smaller community. Would need wiring into `services.k3s` (custom containerd config) on `nixos/k3s-server.nix`.
4. **Drop k8s entirely** — services as `systemd` units in the NixOS config, deploys via `nixos-rebuild` (or `deploy-rs` / `colmena`). Smallest system overall, but you give up the container ecosystem (Helm charts, operators, anything where upstream only ships an image), and ArgoCD is no longer in the picture.

For this single-node homelab, (2) is the easy incremental win on a per-workload basis (best for services we'd build ourselves anyway); (3) is the "go all the way while keeping ArgoCD" answer if/when disk pressure justifies the extra plumbing. (4) is a different posture entirely — only worth it if k8s itself is the thing being questioned.

### TODO — centralize laptop-local state on the Proxmox host

Two things currently live on the laptop that would benefit from moving onto an always-on host. The **Proxmox host** is the natural target for both: it's up before any guest, has the most disk, and sits *outside* the k3s cluster (so there's no chicken-and-egg on cluster recovery). Nix on the Debian side is a clean one-line install and doesn't disturb Proxmox itself.

**1. Shared Nix store.** Today the laptop and every NixOS guest each carry their own `/nix/store`, and the laptop rebuilds from scratch on a fresh clone. Two flavors:

- **Binary cache** (`nix-serve` or `harmonia`) on the Proxmox host. Each guest keeps its own local `/nix/store` but only holds the closures it actually uses; rebuilds become peer copies instead of full builds. No boot-time coupling, low risk. **Start here.**
- **NFS-mounted `/nix/store`** for the guests. One physical copy, every guest sees every path — maximum savings, but the NFS server becomes load-bearing for activation, file-locking on NFS has historical flake, and boot now depends on a network mount. The "go all the way" version if disk later becomes the actual constraint.

Pairs with (3) under "Workload image strategy" — the same store host could eventually feed `nix-snapshotter` for in-cluster workloads, so the whole homelab references one physical copy of each path.

**2. Terraform state.** `terraform/` currently uses the default local backend, so `terraform.tfstate` lives in the working directory on whichever laptop ran `tofu apply` last — no collaboration, no recovery from a lost laptop. Move to a remote backend on the Proxmox host:

- **MinIO** (S3-compatible) → Terraform `s3` backend. Most familiar, useful for other things later, but a whole service to run.
- **Postgres** → Terraform `pg` backend. Simpler if you don't want object storage for anything else.
- **HTTP backend** against a tiny service → simplest, lowest-feature.

Whichever, **don't put the backend in k3s** — Terraform owns the k3s VM's lifecycle, so state living in the cluster means you can't bootstrap or recover the cluster from scratch.

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
