variable "nixos_lxc_image_path" {
  type        = string
  description = "Path to the NixOS proxmox-lxc tarball built by the flake. Set via TF_VAR_nixos_lxc_image_path in .envrc."
}

variable "k3s_server_vm_image_path" {
  type        = string
  description = "Path to the NixOS k3s VM qcow2 built by the flake (.#proxmox-vm-k3s). Set via TF_VAR_k3s_server_vm_image_path in .envrc."
}

variable "nixos_dns_vm_image_path" {
  type        = string
  description = "Path to the NixOS dns VM qcow2 built by the flake (.#proxmox-vm-dns). Set via TF_VAR_nixos_dns_vm_image_path in .envrc."
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to the SSH public key to authorize as root on provisioned VMs. Used by nixos-anywhere bootstrap."
  default     = "~/.ssh/homelab.pub"
}
