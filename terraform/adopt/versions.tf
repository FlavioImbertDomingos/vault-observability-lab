# Adopt configuration that already exists in cloud-a (created by hand, here by
# vault/scripts/init.sh) without recreating or changing it. Work in stages: copy one
# file from stages/ into this folder, let Terraform write the matching config, check
# that the plan only imports, apply, then move on. See docs/terraform.md.

terraform {
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
  type      = string
  sensitive = true
  ephemeral = true
}

provider "vault" {
  address          = var.cloud_a_address
  token            = var.cloud_a_token
  skip_child_token = true
}
