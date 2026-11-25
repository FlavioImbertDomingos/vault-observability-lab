# Version constraints for the module itself (tflint: terraform_required_version,
# terraform_required_providers). They match the root module in terraform/lab.
terraform {
  required_version = ">= 1.11"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.13"
    }
  }
}
