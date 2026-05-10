variable "SSH_HOMELAB_PUB_PATH" {
  type        = string
  description = "Path to the homelab ssh key"
}
variable "S3_BUCKET_ENDPOINT" {
  type        = string
  description = "s3 bucket endpoint to store state"
}

variable "SERVICE_K3S_MAC" {
  type        = string
  description = "MAC address of the k3s service"
}
