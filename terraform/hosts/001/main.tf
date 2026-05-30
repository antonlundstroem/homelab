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
