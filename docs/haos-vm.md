# Provisioning the Home Assistant OS VM (`homeassistant`)

Brings up **Home Assistant OS (HAOS)** as a second Incus VM on host001, alongside `node01`.
This re-introduces Home Assistant — removed from gitops in the node01 restructure (see
`k3s-node01-migration.md`) — but now as a **dedicated appliance VM** rather than an in-cluster app.

**Why this isn't like node01.** HAOS is a Buildroot appliance, **not NixOS**: no `nixosConfiguration`,
no `nixos-rebuild`, and it's published nowhere as an `images:` remote. So the OS image is Home
Assistant's prebuilt qcow2, staged by hand and imported into Incus via Terraform's
`incus_image.source_file` (resources live in `terraform/hosts/001/main.tf`). After first boot, Home
Assistant manages itself — Terraform only owns the VM shell (cores/memory/disk/NIC) and the image import.

## Prerequisites
- Repo changes for the HAOS VM committed (the Terraform resources + provider bump).
- devShell active (`opentofu` on PATH; `direnv` loaded `.envrc.local`).
- `wget`, `xz`, `tar` available locally (in the devShell / system).
- The Incus remote reachable (`INCUS_*` set in `.envrc.local`, as for node01).

---

## 1. Pick a MAC and reserve its IP on the router
Choose a MAC in the Incus `00:16:3e:` range, distinct from node01's `00:16:3e:42:00:01` — e.g.
**`00:16:3e:42:00:02`**. On your router, bind that MAC → a fixed LAN IP **outside** the DHCP pool
(e.g. `192.168.1.50`). Do this **before** boot so HA comes up at the intended address.

Why a router reservation (not the NixOS networking file): HAOS isn't NixOS, so it can't use the
match-on-MAC static-IP config the NixOS nodes use. The MAC is owned by Terraform and is stable across
rebuilds, so the reservation hands back the same IP every time — zero in-HAOS steps.

## 2. Set the local Terraform variable
In `.envrc.local` (gitignored), set the MAC you chose, then reload:
```sh
# export TF_VAR_HOMEASSISTANT_MAC="00:16:3e:42:00:02"
direnv allow
```

## 3. Stage the image (the manual step — Terraform can't fetch a URL or decompress)
Download HAOS's OVA/KVM qcow2, **decompress it**, and build the split-image metadata tarball into a
gitignored `terraform/hosts/001/.haos/`:
```sh
mkdir -p terraform/hosts/001/.haos && cd terraform/hosts/001/.haos
wget https://github.com/home-assistant/operating-system/releases/download/17.3/haos_ova-17.3.qcow2.xz
xz -d haos_ova-17.3.qcow2.xz          # -> haos_ova-17.3.qcow2 (raw qcow2)
```
⚠️ **Do not skip `xz -d`.** Incus decides container-vs-VM by sniffing the file's magic bytes; importing
the still-`.xz` file registers it as a *container*, which the `type = "virtual-machine"` instance can't use.

```sh
cat > metadata.yaml <<'EOF'
architecture: x86_64
creation_date: 1746000000
properties:
  description: Home Assistant OS 17.3
  os: HAOS
  release: "17.3"
EOF
tar -czf metadata.tar.gz metadata.yaml
```
(`architecture` + `creation_date` are the only mandatory fields; `creation_date` is any valid epoch.)

> Bumping HAOS later: stage the new `haos_ova-<ver>.qcow2`, update the `data_path`/`metadata_path` in
> `main.tf` to match. But note — changing the instance's `image` **replaces the VM and wipes its data**
> (step 5 warning). The normal upgrade path is **in-OS** (Settings → System → Updates), not Terraform.

## 4. Provision
```sh
cd terraform/hosts/001
tofu init -upgrade   # picks up provider 1.1.x (incus_image.source_file + wait_for delay)
tofu plan            # expect: node01 UNCHANGED; ADD incus_image.haos + incus_instance.homeassistant;
                     # var HOMEASSISTANT_MAC bound
tofu apply
```
`incus_image.source_file` reads the staged files locally and uploads the ~1 GB qcow2 to host001 over the
Incus API (a few seconds on LAN). It re-uploads only if the image is recreated or state is lost.

## 5. ⚠️ Data durability — HAOS state is precious
All HA config / automations / history / add-ons live on this VM's **root disk**. Unlike the cluster's
`local-path` PVCs (intentionally disposable, rebuilt from git), this is **not** reproducible. A
`tofu apply -replace=incus_instance.homeassistant` — or changing `image`, `type`, or disk size — **destroys
it permanently.** Protect it:
- **Upgrade HAOS in-OS**, not via the Terraform `image` (see step 3 note).
- **Wire HA automatic backups → host001 Garage S3** (the repo's durability pattern — app backups → a
  Garage bucket), in the HA UI right after onboarding, before you depend on the instance. The
  `haos-backup` access key is provisioned automatically by `garage-bootstrap`
  (`nixos/hosts/001/garage.nix`) — read+write on the `haos` bucket, re-imported on every rebuild — so
  there's no Garage-side step beyond having its `HAOS_KEY_ID`/`HAOS_KEY_SECRET` in the `garage_env`
  sops secret. In HA: install **HACS → "S3 Compatible Backup"** (bauer-group; the built-in `aws_s3`
  integration is Amazon-only and rejects custom endpoints), then add it with endpoint
  `http://<host001-ip>:3900`, region `garage`, bucket `haos`, and that key. Use host001's **IP
  literal** (forces path-style — Garage's `.s3.garage.lan` vhost domain isn't real DNS) and plain
  `http` (`:3900` is the only S3 port open on the LAN; no TLS).
- `incus snapshot create homeassistant pre-tofu` before any risky `tofu` operation.

---

## 6. Remote access via Tailscale (add-on)
Another **in-HAOS step** (not Terraform/Nix) — same bucket as the backups above. Use the Tailscale
**add-on**, *not* the Tailscale *integration* (the integration only monitors a tailnet; it doesn't put
HA on it). The add-on requires HAOS/Supervised — which this VM is.

1. **Settings → Add-ons → Add-on Store → Tailscale → Install** (don't start it yet).
2. **Mint an auth key** in the Tailscale admin console (Settings → Keys); tag it (e.g. `tag:homeassistant`)
   if you gate access with ACLs — same tailnet as the ArgoCD `argocd.<tailnet>.ts.net` ingress.
3. Add-on **Configuration** tab:
   ```yaml
   auth_key: tskey-auth-xxxxxxxxxxxx
   hostname: homeassistant        # -> reachable at homeassistant.<tailnet>.ts.net:8123
   ```
4. **Start** the add-on; confirm in the **Log** tab that it authenticated.
5. In the admin console, open the `homeassistant` machine and **disable key expiry** — otherwise it
   silently drops off the tailnet in ~90 days (the #1 "Tailscale stopped working" cause).

Notes:
- **Complements the `br0` NIC, doesn't replace it** — keep the LAN interface for mDNS / local device
  discovery; Tailscale is only for secure remote access.
- **The auth key is an out-of-band secret**: it lives in the add-on options on HAOS's data partition
  (precious state — survives reboots, wiped by a `tofu -replace`), and sits **outside** `sops-nix` /
  `sealed-secrets` (neither reaches HAOS). Mint it from the same tailnet and paste it in.
- **Optional subnet router**: to reach *other* LAN devices over Tailscale, set
  `advertise_routes: 192.168.1.0/24` in the add-on config, then **approve the route** in the admin
  console (Machines → the HA host → review subnets) or it silently won't route. Skip if another node
  already advertises that range.

---

## 7. Verify
Run on host001 (`incus ...`) unless noted:
```sh
incus image list                                 # new image: TYPE=VIRTUAL-MACHINE, DESCRIPTION "Home Assistant OS 17.3"
                                                 #   (TYPE=container ⇒ the .xz wasn't decompressed — re-stage)
incus list homeassistant                         # RUNNING, TYPE = VIRTUAL-MACHINE
incus console homeassistant --show-log           # HAOS boot log + login banner showing the IP
                                                 #   (hang at OVMF ⇒ security.secureboot wasn't false)
ip neigh show dev br0 | grep 00:16:3e:42:00:02   # confirms it's live on the LAN at the reserved IP
```
From any LAN host:
```sh
curl -sI http://192.168.1.50:8123               # 200/302 — then open it for the HA onboarding wizard
avahi-browse -rt _home-assistant._tcp           # mDNS discovery works (bridged br0 = first-class LAN)
```

## Notes / troubleshooting
- **No in-place rollback** of the data (there's no NixOS-style activation here). Recovery is forward:
  fix the staging/config, re-`apply`; restore HA state from a Garage S3 backup.
- If `tofu`/`incus` against host001 throws a misleading **x509 / SAN cert error**, it's a stale
  server-cert pin from a host001 reinstall — fix with `rm ~/.config/incus/servercerts/host001.crt`
  (not a SAN/ordering problem).
- Zigbee/Thread USB stick: pass it through later with `incus config device add homeassistant <name> usb
  vendorid=… productid=…` (some controllers need the whole USB/PCI controller forwarded; stop/start the VM).
