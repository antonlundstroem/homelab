# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A homelab provisioning repo: a Nix flake builds NixOS images, and OpenTofu uses the `lxc/incus` provider to create VMs on host001 (NixOS baremetal running Incus).

## Build / deploy commands

Refresh the local `.kubeconfig` after the k3s VM is recreated or its IP changes (the devShell exposes this as a script):

```sh
refresh-kubeconfig    # SCPs /etc/rancher/k3s/k3s.yaml off the k3s VM, rewrites server URL to its LAN IP
```

Apply infrastructure (devShell provides `opentofu`; direnv loads it automatically):

```sh
cd terraform/hosts/001 && tofu init && tofu plan && tofu apply
```

In-place rebuild on a running host (uses `nixosConfigurations.{host001,k3s}`) — this is the normal way to roll changes out, not a VM rebuild via Terraform:

```sh
nixos-rebuild switch --flake .#k3s     --target-host admin@<ip> --sudo
nixos-rebuild switch --flake .#host001 --target-host admin@<ip> --sudo
```

- **No local `sudo`.** With `--target-host`, nixos-rebuild only needs to read the local nix store and SSH out; both work as a normal user. Running it under `sudo` makes the SSH client run as root, which then fails to find `~/.ssh/homelab` and dies with `Permission denied (publickey)`.
- **`--sudo`** elevates the *remote* activation step, which is needed because `admin@` has no direct root over SSH. Passwordless wheel sudo on the target (set in `nixos/settings/system/configuration.nix`) makes this transparent. (`--use-remote-sudo` is the deprecated alias of the same flag.)
- **SSH key.** The repo provisions `~/.ssh/homelab` as the authorized key for `admin`. Either set it in `~/.ssh/config` (`IdentityFile ~/.ssh/homelab` for the host) or pass it ad-hoc with `NIX_SSHOPTS="-i ~/.ssh/homelab"`.

## Workflow: who owns what

Three tools, three non-overlapping responsibilities. Don't reach across the line.

- **Terraform** owns external APIs only — VM lifecycle on Incus (cores/memory/network), and any future DNS/firewall resources. Run `tofu apply` to create or replace a VM.
- **NixOS** owns the OS interior — packages, services, k3s, the auto-deploy manifests that bootstrap ingress-nginx + ArgoCD. Day-to-day changes flow through `nixos-rebuild` against a *running* VM, not via Terraform replacing it.
- **ArgoCD** owns everything inside the cluster after bootstrap — workloads under `gitops/`, drift detection, sync. Once Argo is up, neither Terraform nor NixOS should touch cluster resources.

When to actually re-run Terraform: first-time provisioning, you changed something Terraform owns, the VM is unrecoverable, or you want to validate that a fresh image self-bootstraps end-to-end (`tofu apply -replace=incus_instance.k3s`).

### GitOps layout

The k3s VM bootstraps itself into a working GitOps state with no manual `kubectl` step. `nixos/services/k3s/configuration.nix` writes three resources into the k3s auto-deploy directory via `services.k3s.manifests`: an `ingress-nginx` `HelmChart`, an `argo-cd` `HelmChart` (with a Tailscale Ingress exposed at `argocd.<tailnet>.ts.net`), and a single root `Application` pointing at `gitops/argocd/` in this repo. From there ArgoCD takes over: every YAML in `gitops/argocd/` is a child `Application` describing one workload, and each one references its actual manifests under `gitops/manifests/<name>/`. To add a new service: drop manifests into `gitops/manifests/<name>/`, add `gitops/argocd/<name>.yaml` pointing at it, commit — no rebuild required.

### Scheduling on the GPU node

`gpu01` is a NixOS k3s agent with an NVIDIA GPU (see `nixos/nodes/gpu01/`). It's tainted `nvidia.com/gpu=true:NoSchedule` so unrelated workloads can't land there. To schedule a pod on it, both fields are required:

```yaml
spec:
  tolerations:
    - key: nvidia.com/gpu
      operator: Equal
      value: "true"
      effect: NoSchedule
  containers:
    - name: ...
      image: ...
      resources:
        limits:
          nvidia.com/gpu: 1   # or however many
```

The taint blocks accidental scheduling; the resource limit triggers GPU injection via the device plugin + CDI. No `runtimeClassName` is needed on workload pods — that's only on the bootstrap pods (`nvidia-device-plugin`, `gpu-feature-discovery`) so they can call NVML during startup. Compute and `nvidia-smi` both work in workload pods (the host's nvidia binaries are patchelf'd to use FHS interpreter paths — see `nixos/nodes/gpu01/configuration.nix`).

Caveat: the taint only blocks pods that lack the toleration; it does *not* enforce that pods with the toleration must request GPU. Be intentional — only add the toleration to pods that actually need GPU. (If you ever want hard enforcement, layer in a Kyverno/Gatekeeper policy.)

### Workload image strategy

Workloads currently run as **vanilla container images** (whatever ArgoCD pulls from upstream registries via the manifests under `gitops/`). When image bloat actually starts to hurt, there's a spectrum of progressively smaller options that lean on the k3s node's Nix store:

1. **Vanilla containers** *(current)* — biggest images, full upstream ecosystem. ArgoCD just deploys what's on Docker Hub / GHCR.
2. **Nix-built OCI images** — `pkgs.dockerTools.buildLayeredImage` produces images with no distro base layer; each store path becomes its own layer, so containerd's content-addressed storage dedups across all Nix-built images on the node. Push to a registry (in-cluster or external), reference from manifests, ArgoCD flow is unchanged. Meaningful savings, normal k8s.
3. **nix-snapshotter** (`pdtpartners/nix-snapshotter`) — containerd plugin: pods reference Nix store paths directly and are materialized from the host's `/nix/store` instead of pulled as image layers. Anything the host already has costs zero extra disk. ArgoCD doesn't care; the magic is below containerd. Smallest possible workloads while staying in k8s, but it's a custom containerd plugin — extra moving part on the node, smaller community. Would need wiring into `services.k3s` (custom containerd config) on `nixos/services/k3s/configuration.nix`.
4. **Drop k8s entirely** — services as `systemd` units in the NixOS config, deploys via `nixos-rebuild` (or `deploy-rs` / `colmena`). Smallest system overall, but you give up the container ecosystem (Helm charts, operators, anything where upstream only ships an image), and ArgoCD is no longer in the picture.

For this single-node homelab, (2) is the easy incremental win on a per-workload basis (best for services we'd build ourselves anyway); (3) is the "go all the way while keeping ArgoCD" answer if/when disk pressure justifies the extra plumbing. (4) is a different posture entirely — only worth it if k8s itself is the thing being questioned.

### TODO — centralize laptop-local state on host001

`host001` is the NixOS baremetal box running Incus (see `nixos/hosts/001/`). It's the natural home for shared homelab plumbing: always-on, most disk, sits *outside* the k3s cluster (so cluster recovery doesn't chicken-and-egg through it), and already NixOS so adding services is a flake change rather than a new install.

**1. Shared Nix store.** Today the laptop and every NixOS guest each carry their own `/nix/store`, and the laptop rebuilds from scratch on a fresh clone. Two flavors:

- **Binary cache** (`nix-serve` or `harmonia`) on host001. Each guest keeps its own local `/nix/store` but only holds the closures it actually uses; rebuilds become peer copies instead of full builds. No boot-time coupling, low risk. **Start here.**
- **NFS-mounted `/nix/store`** for the guests. One physical copy, every guest sees every path — maximum savings, but the NFS server becomes load-bearing for activation, file-locking on NFS has historical flake, and boot now depends on a network mount. The "go all the way" version if disk later becomes the actual constraint.

Pairs with (3) under "Workload image strategy" — the same store host could eventually feed `nix-snapshotter` for in-cluster workloads, so the whole homelab references one physical copy of each path.

**2. Terraform state.** *(Done — moved to a Garage S3 backend on host001, see `terraform/hosts/001/backend.tf`.)*

## Configuration / secrets

- `.envrc` (committed) sets `KUBECONFIG=$PWD/.kubeconfig` and sources `.envrc.local`.
- `.envrc.local` (gitignored) sets the Incus remote + S3 credentials for the OpenTofu Garage backend. **`.envrc.local.example` is the canonical schema** — copy it to `.envrc.local`, fill in real values, run `direnv allow`. When adding a new local-only env var, update the `.example` file in the same change so the docs stay current.
- **`nixos/settings/networking/configuration.nix`** (gitignored, intent-to-add) holds LAN topology values (gateway, k3s VM IP/MAC). **`nixos/settings/networking/configuration.example.nix`** is the schema. Bootstrap on a fresh clone:
  ```sh
  cp nixos/settings/networking/configuration.example.nix nixos/settings/networking/configuration.nix
  # edit with real values
  git add -fN nixos/settings/networking/configuration.nix    # --force --intent-to-add so the flake can read it
  ```
  Without the `git add -fN`, `nix build` / `nixos-rebuild` fails with a "path does not exist" error — flakes only see git-tracked or intent-to-add'd files. Same pattern as `.envrc.local` but at the file layer, because Nix can't read env vars at eval time without breaking pure flakes. When adding a new value, update both `configuration.nix` and `configuration.example.nix` in the same change.
- Authorized SSH keys are inlined in `nixos/settings/system/configuration.nix` (shared base for VMs) and `nixos/hosts/001/configuration.nix` (host001-specific) — update both when rotating.

### Secrets — sops-nix

Real secrets live in the repo as age-encrypted blobs under `secrets/hosts/<host>/`, decrypted at activation by `sops-nix` (Mic92's module) using each host's SSH host key (`/etc/ssh/ssh_host_ed25519_key`, already present on every NixOS box). Decrypted secrets surface as `/run/secrets/<name>` (tmpfs, regenerated each boot from the encrypted blob in the closure).

`.sops.yaml` lists two recipients: `&base` (the laptop's age key, for editing) and `&host001` (host001's host SSH key converted via `ssh-to-age`, for activation-time decryption). To add a new secret, drop a YAML file under `secrets/hosts/001/`, encrypt with `sops`, then declare `sops.secrets.<name> = { ... };` in the host's NixOS config and reference `config.sops.secrets.<name>.path` from the consuming service. Pattern: replace `services.X.environmentFile = "/etc/X/secrets.env"` with `environmentFile = config.sops.secrets.X_env.path`.

Gotchas:
- For services using `DynamicUser=true` (Garage, others), don't set `owner`/`group` on the secret — the user doesn't exist as a persistent account, and `sops-install-secrets` will fail manifest validation (`failed to lookup user 'garage': unknown user`). Leave it root-owned 0400; systemd reads `EnvironmentFile` as root before dropping privileges, and the env vars only end up in the dynamic-user process anyway.
- Reinstall hazard: a wipe regenerates the SSH host key, so existing encrypted secrets become undecryptable on the new host. Either preserve `/etc/ssh/ssh_host_ed25519_key{,.pub}` across reinstalls (USB / 1Password), or run `sops updatekeys secrets/hosts/001/*.yaml` from the laptop after the new host has booted (and update the `&host001` recipient in `.sops.yaml`).

`.envrc.local` (laptop-local, not deployed) and `nixos/settings/networking/configuration.nix` (topology, not secret) intentionally stay out of sops.

### TODO — give disk-hungry services their own quota'd ZFS datasets on host001

Today disk-hungry services on host001 live directly on `rpool/root`, sharing the pool with the OS, `/home`, etc. Their service-level capacity settings (where they exist) are soft self-limits — not disk reservations — so nothing prevents one of them from filling the whole pool. Fix by giving each its own dataset with a hard ZFS quota: extend `nixos/hosts/001/disko.nix` with the dataset (legacy mountpoint, same `compression=zstd` etc. as siblings), set `quota` in `rootFsOptions`, and align the service's own cap to match. After that, the service gets `ENOSPC` at the filesystem layer if it tries to exceed — a real ceiling, not a soft hint.

Services that need this:

- **Garage** — `/var/lib/garage/{meta,data}` → `rpool/garage`, e.g. `quota = "50G"`, then bump `capacity` in `nixos/hosts/001/garage.nix` to match. Garage's `capacity` in the layout is a soft self-limit only.
- **Incus** — `/var/lib/incus/storage-pools/default` → `rpool/incus` (or switch the storage pool to the `zfs` driver pointing at the dataset, which also makes the per-instance `size` in the default profile an enforced ZFS quota instead of an unenforced hint under the `dir` driver). See `nixos/hosts/001/incus.nix`.

Worth doing before adding more disk-hungry services to host001 (VMs, container image cache, future binary-cache growth) so they can't accidentally crowd each other out. Note: changing disko on a live system isn't a `nixos-rebuild` away — it requires creating the dataset by hand with `zfs create` first, then moving the existing data into it, then matching the disko config so a fresh install recreates the same layout.

## MCP servers

`.mcp.json` registers `terraform` (HashiCorp registry tooling) and `nixos` (NixOS package/option search) — prefer these over web search when looking up provider arguments or NixOS options.
