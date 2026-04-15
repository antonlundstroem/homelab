terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.101"
    }
  }
}

provider "proxmox" {
  endpoint = var.proxmox_endpoint
  # We're setting the API token in .envrc.local
  insecure = true # set to false if using a valid TLS certificate
}
