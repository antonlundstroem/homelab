resource "incus_instance" "k3s" {
  name     = "k3s"
  type     = "virtual-machine"
  image    = "images:nixos/25.11"
  profiles = ["default", "lan"]

  config = {
    "security.secureboot" = "false"
    "limits.cpu"          = "4"
    "limits.memory"       = "8GiB"
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
      hwaddr  = var.SERVICE_K3S_MAC
    }
  }
}
