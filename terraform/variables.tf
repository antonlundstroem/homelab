variable "nixos_lxc_image_path" {
  type        = string
  description = "Path to the NixOS proxmox-lxc tarball built by the flake. Set via TF_VAR_nixos_lxc_image_path in .envrc."
}

variable "nixos_vm_image_path" {
  type        = string
  description = "Path to the NixOS proxmox-vm tarball built by the flake. Set via TF_VAR_nixos_vm_image_path in .envrc."
}

variable "nixos_dns_lxc_template_path" {
  type        = string
  description = "Path to the NixOS dns LXC tarball built by the flake (.#proxmox-lxc-dns). Set via TF_VAR_nixos_dns_lxc_template_path in .envrc."
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to the SSH public key to authorize as root on provisioned VMs. Used by nixos-anywhere bootstrap."
  default     = "~/.ssh/homelab.pub"
}
