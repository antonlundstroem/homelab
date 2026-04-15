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
