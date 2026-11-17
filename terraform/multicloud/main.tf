# One baseline, applied to every cluster. Each cluster stays independent (no replication),
# but Terraform keeps their configuration identical and shows drift on "plan".

provider "vault" {
  alias            = "cloud_a"
  address          = var.cloud_a_address
  token            = var.cloud_a_token
  skip_child_token = true
}

provider "vault" {
  alias            = "cloud_b"
  address          = var.cloud_b_address
  token            = var.cloud_b_token
  skip_child_token = true
}

module "cloud_a" {
  source    = "./modules/baseline"
  providers = { vault = vault.cloud_a }

  cluster = "cloud-a"
  region  = "aws-us-east-1"
}

module "cloud_b" {
  source    = "./modules/baseline"
  providers = { vault = vault.cloud_b }

  cluster = "cloud-b"
  region  = "azure-westeurope"
}

output "deployer_role_ids" {
  description = "AppRole role_id of the platform deployer in each cluster (not secret)"
  value = {
    cloud-a = module.cloud_a.deployer_role_id
    cloud-b = module.cloud_b.deployer_role_id
  }
}
