resource "incus_instance" "node01" {
  name     = "node01"
  type     = "virtual-machine"
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
# locally per haos-vm.md — and registered here as a Terraform-managed image.
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
    "limits.memory"       = "8GiB"
  }

  # HAOS runs no Incus guest agent and br0 is an unmanaged bridge (the LAN router
  # does DHCP, not Incus), so Incus can never learn the VM's IP — `agent`/`ipv4`
  # would hang until timeout. Wait a fixed boot window; the IP is pinned out-of-
  # band via a router DHCP reservation on var.HOMEASSISTANT_MAC (see haos-vm.md).
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
