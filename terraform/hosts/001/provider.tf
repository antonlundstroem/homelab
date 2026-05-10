terraform {
  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "~> 1.0.2"
    }
  }
}

provider "incus" {
  generate_client_certificates = true
  accept_remote_certificate    = true

  # We're setting the remote in .envrc.local
  #INCUS_REMOTE - The name of the remote.
  #INCUS_ADDR - The address of the Incus remote.
  #INCUS_PROTOCOL - The server protocol to use.
  #INCUS_AUTHENTICATION_TYPE - Server authentication type.
  #INCUS_TOKEN - The trust token of the Incus remote.
}
