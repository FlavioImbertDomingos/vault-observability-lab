variable "cloud_a_address" {
  description = "Address of the main cluster (cloud-a)"
  type        = string
  default     = "http://localhost:8200"
}

variable "cloud_b_address" {
  description = "Address of the second cluster (cloud-b)"
  type        = string
  default     = "http://localhost:8300"
}

variable "cloud_a_token" {
  description = "Token for cloud-a (lab: ./lab.sh tf mints a 30-minute token with the terraform policy)"
  type        = string
  sensitive   = true
}

variable "cloud_b_token" {
  description = "Token for cloud-b (same, minted on cloud-b)"
  type        = string
  sensitive   = true
}
