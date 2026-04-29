terraform {
  backend "s3" {
    bucket = "tofu-state"
    key    = "homelab/hosts/001/terraform.tfstate"
    region = "garage"

    endpoints = {
      s3 = "http://192.168.1.100:3900"
    }

    # Garage isn't AWS — silence the AWS-specific validations.
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true

    # Garage doesn't do virtual-hosted bucket addressing.
    use_path_style = true

    # Native S3 conditional-write locking (OpenTofu 1.10+, no DynamoDB needed).
    use_lockfile = true
  }
}
