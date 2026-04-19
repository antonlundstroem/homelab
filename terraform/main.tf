resource "proxmox_virtual_environment_file" "nixos_image" {
  content_type = "import"
  datastore_id = "local"
  node_name    = local.node_name

  source_file {
    path      = var.nixos_vm_image_path
    file_name = "nixos.qcow2"
    checksum  = filesha256(var.nixos_vm_image_path)
  }
}

resource "proxmox_virtual_environment_vm" "nixos" {
  name      = "nixos"
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
    dedicated = 4096
  }

  disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
    interface    = "scsi0"
    import_from  = proxmox_virtual_environment_file.nixos_image.id
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

output "nixos_vm_ipv4" {
  value = proxmox_virtual_environment_vm.nixos.ipv4_addresses
}

resource "proxmox_virtual_environment_file" "nixos_dns_template" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = local.node_name

  source_file {
    path      = var.nixos_dns_lxc_template_path
    file_name = "nixos-dns.tar.xz"
    checksum  = filesha256(var.nixos_dns_lxc_template_path)
  }
}

resource "proxmox_virtual_environment_container" "dns" {
  node_name     = local.node_name
  vm_id         = 200
  unprivileged  = true
  start_on_boot = true
  started       = true

  operating_system {
    template_file_id = proxmox_virtual_environment_file.nixos_dns_template.id
    type             = "nixos"
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 256
    swap      = 0
  }

  disk {
    datastore_id = "local-lvm"
    size         = 4
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  initialization {
    hostname = "dns"

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  lifecycle {
    ignore_changes = [operating_system[0].template_file_id]
  }
}

output "dns_lxc_ipv4" {
  value = proxmox_virtual_environment_container.dns.ipv4_addresses
}
