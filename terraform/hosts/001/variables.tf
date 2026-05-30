variable "SSH_HOMELAB_PUB_PATH" {
  type        = string
  description = "Path to the homelab ssh key"
}
variable "S3_BUCKET_ENDPOINT" {
  type        = string
  description = "s3 bucket endpoint to store state"
}

variable "NODE01_MAC" {
  type        = string
  description = "MAC address of the node01 k3s VM"
}
