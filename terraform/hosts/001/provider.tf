terraform {
  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "~> 1.0.2"
    }
  }
}

provider "incus" {
  remote = {
  }
  # We're setting the Endpoint and API token in .envrc.local
  insecure = true # set to false if using a valid TLS certificate
}

#INCUS_REMOTE - The name of the remote.
#INCUS_ADDR - The address of the Incus remote.
#INCUS_PROTOCOL - The server protocol to use.
#INCUS_AUTHENTICATION_TYPE - Server authentication type.
#INCUS_TOKEN - The trust token of the Incus remote.
