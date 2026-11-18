terraform {
  # ephemeral resources need 1.10, write-only arguments 1.11
  required_version = ">= 1.11"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.13"
    }
  }
}

variable "cloud_a_address" {
  type    = string
  default = "http://localhost:8200"
}

variable "cloud_a_token" {
  description = "Short-lived token with the terraform policy (./lab.sh tf mints it)"
  type        = string
  sensitive   = true
  ephemeral   = true # not written to the plan file or the state
}

variable "demo_password" {
  description = "A fake secret. ./lab.sh secrets-check searches the state for it."
  type        = string
  sensitive   = true
  ephemeral   = true
  default     = "lab-demo-S3cret-4242"
}

variable "classic_password" {
  description = "The same fake secret as a normal variable, the way it would come from a .tfvars file"
  type        = string
  sensitive   = true
  default     = "lab-demo-S3cret-4242"
}

variable "secret_version" {
  description = "Bump this when the password changes: Terraform cannot see write-only values, so it cannot detect the change"
  type        = number
  default     = 1
}

provider "vault" {
  address          = var.cloud_a_address
  token            = var.cloud_a_token
  skip_child_token = true
}
