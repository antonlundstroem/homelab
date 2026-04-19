resource "proxmox_virtual_environment_file" "k3s_server_image" {
  content_type = "import"
  datastore_id = "local"
  node_name    = local.node_name

  source_file {
    path      = var.k3s_server_vm_image_path
    file_name = "k3s-server.qcow2"
    checksum  = filesha256(var.k3s_server_vm_image_path)
  }
}

# k3s "server" runs both control plane and agent on this single VM
# (k3s default — schedules pods on itself). For a single-node cluster
# this *is* the whole cluster. Add k3s_agent_<n> resources later if scaling out.
resource "proxmox_virtual_environment_vm" "k3s_server" {
  name      = "k3s-server"
  node_name = local.node_name
  vm_id     = 300

  agent {
    enabled = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 8192
  }

  disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
    interface    = "virtio0"
    import_from  = proxmox_virtual_environment_file.k3s_server_image.id
    size         = 20
  }

  network_device {
    bridge = "vmbr0"
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    ignore_changes = [disk[0].import_from]
  }
}

output "k3s_server_vm_ipv4" {
  value = proxmox_virtual_environment_vm.k3s_server.ipv4_addresses
}

# TODO(dns-as-lxc): once the Proxmox keyctl/root@pam friction is resolved,
# replace this VM block with a proxmox_virtual_environment_container.
# See CLAUDE.md "LAN DNS" for the migration plan; flake.nix and dns.nix
# are already structured to flip back without further changes.
resource "proxmox_virtual_environment_file" "nixos_dns_image" {
  content_type = "import"
  datastore_id = "local"
  node_name    = local.node_name

  source_file {
    path      = var.nixos_dns_vm_image_path
    file_name = "nixos-dns.qcow2"
    checksum  = filesha256(var.nixos_dns_vm_image_path)
  }
}

resource "proxmox_virtual_environment_vm" "dns" {
  name      = "dns"
  node_name = local.node_name
  vm_id     = 200

  agent {
    enabled = true
  }

  cpu {
    cores = 1
    type  = "host"
  }

  memory {
    dedicated = 512
  }

  disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
    interface    = "virtio0"
    import_from  = proxmox_virtual_environment_file.nixos_dns_image.id
    size         = 6
  }

  network_device {
    bridge = "vmbr0"
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    ignore_changes = [disk[0].import_from]
  }
}

output "dns_vm_ipv4" {
  value = one([
    for ip in flatten(proxmox_virtual_environment_vm.dns.ipv4_addresses) :
    ip if startswith(ip, "192.168.")
  ])
}
