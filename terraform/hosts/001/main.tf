resource "incus_instance" "node01" {
  name     = "node01"
  type     = "virtual-machine"
  # NOTE: this alias no longer exists on the image server (Oct 2026: only
  # nixos/26.05 and nixos/unstable). Do not edit it on the running VM — a changed
  # image forces a replace. Switch to nixos/26.05 only when deliberately recreating.
  image    = "images:nixos/25.11"
  profiles = ["default", "lan"]

  config = {
    "security.secureboot" = "false"
    "limits.cpu"          = "4"
    "limits.memory"       = "16GiB"
  }

  wait_for { type = "agent" }

  file {
    source_path        = pathexpand(var.SSH_HOMELAB_PUB_PATH)
    target_path        = "/root/.ssh/authorized_keys"
    uid                = 0
    gid                = 0
    mode               = "0600"
    create_directories = true
  }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      nictype = "bridged"
      parent  = "br0"
      hwaddr  = var.NODE01_MAC
    }
  }

  # Per-VM root disk. Overrides the Incus default profile's root device so VM
  # sizing lives here (Terraform owns VM lifecycle) rather than in incus.nix.
  # Thin/sparse zvol — only consumes what's written, so 200GiB is a ceiling, not
  # an allocation. The host OS is protected from a full VM by ZFS reservations on
  # rpool/nix + rpool/root (nixos/hosts/001/disko.nix).
  device {
    name = "root"
    type = "disk"
    properties = {
      pool = "default"
      path = "/"
      size = "200GiB"
    }
  }
}

# ---- Home Assistant OS -------------------------------------------------------
# HAOS is a Buildroot appliance (NOT NixOS), so it can't follow node01's path
# (boot a remote images: alias, then nixos-rebuild). It's also not on any Incus
# image server, so it's imported from Home Assistant's prebuilt qcow2 — staged
# locally per docs/haos-vm.md — and registered here as a Terraform-managed image.
resource "incus_image" "haos" {
  source_file = {
    # The DECOMPRESSED qcow2. Incus infers VM-vs-container from the file's magic
    # bytes — a still-.xz file imports as a container and breaks the VM below.
    data_path     = "${path.module}/.haos/haos_ova-17.3.qcow2"
    metadata_path = "${path.module}/.haos/metadata.tar.gz"
  }

  # No `alias` block: the nested alias on incus_image trips a provider bug
  # ("inconsistent result after apply: .alias … does not correlate",
  # lxc/terraform-provider-incus#445). The instance below references this image
  # by .fingerprint, so the alias is unnecessary. Want a friendly name? Add it
  # out-of-band: `incus image alias create haos-17.3 <fingerprint>`.
}

resource "incus_instance" "haos" {
  name     = "haos"
  type     = "virtual-machine"
  image    = incus_image.haos.fingerprint # image imports first, then the VM builds
  profiles = ["default", "lan"]

  config = {
    "security.secureboot" = "false" # HAOS image is unsigned — required (like node01)
    "limits.cpu"          = "4"
    # Trimmed 8 → 4 GiB (2026-10-17) to make room for the claude VM: HAOS sits at
    # ~2.4 GiB and Home Assistant documents 2 GB as the VM minimum. Incus shrinks a
    # running VM via the balloon driver; if it does not fully release, the new
    # limit lands at the next HAOS restart. Memory changes are in-place, not a replace.
    "limits.memory"       = "4GiB"
  }

  # HAOS runs no Incus guest agent and br0 is an unmanaged bridge (the LAN router
  # does DHCP, not Incus), so Incus can never learn the VM's IP — `agent`/`ipv4`
  # would hang until timeout. Wait a fixed boot window; the IP is pinned out-of-
  # band via a router DHCP reservation on var.HAOS_MAC (see docs/haos-vm.md).
  wait_for {
    type  = "delay"
    delay = "120s"
  }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      nictype = "bridged"
      parent  = "br0"
      hwaddr  = var.HAOS_MAC
    }
  }

  # HAOS auto-grows its data partition to fill this. Sparse zvol on the same pool
  # as node01 — a ceiling, not an allocation.
  device {
    name = "root"
    type = "disk"
    properties = {
      pool = "default"
      path = "/"
      size = "64GiB"
    }
  }
}

# ---- claude: always-on Claude Code host ---------------------------------------
# NixOS VM like node01 (boot the images: alias, then nixos-rebuild owns the inside).
# Remote Control + herdr for the keyboard repos; spec in docs/CLAUDE-CODE-HOST.md.
# Sized 2 vCPU / 8 GiB with the HAOS trim above so committed VM RAM stays 28 GiB
# on the 31 GiB host; both limits are live-updatable from here.
resource "incus_instance" "claude" {
  name     = "claude"
  type     = "virtual-machine"
  # Bootstrap only; nixos-rebuild replaces everything inside. The image server
  # dropped the nixos/25.11 alias in Oct 2026 (26.05 and unstable remain).
  image    = "images:nixos/26.05"
  profiles = ["default", "lan"]

  config = {
    "security.secureboot" = "false"
    "limits.cpu"          = "2"
    "limits.memory"       = "8GiB"
  }

  wait_for { type = "agent" }

  # First-boot access for the initial nixos-rebuild (as root, before the NixOS
  # config creates the admin/claude users).
  file {
    source_path        = pathexpand(var.SSH_HOMELAB_PUB_PATH)
    target_path        = "/root/.ssh/authorized_keys"
    uid                = 0
    gid                = 0
    mode               = "0600"
    create_directories = true
  }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      nictype = "bridged"
      parent  = "br0"
      hwaddr  = var.CLAUDE_MAC
    }
  }

  # Thin zvol: a ceiling, not an allocation (same reasoning as node01).
  device {
    name = "root"
    type = "disk"
    properties = {
      pool = "default"
      path = "/"
      size = "64GiB"
    }
  }
}
