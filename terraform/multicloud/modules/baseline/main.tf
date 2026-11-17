terraform {
  required_providers {
    vault = { source = "hashicorp/vault" }
  }
}

variable "cluster" {
  description = "Cluster name, used in values and descriptions"
  type        = string
}

variable "region" {
  description = "Cloud and region this cluster stands for"
  type        = string
}

# --- secrets engine shared by every cluster -------------------------------
resource "vault_mount" "platform" {
  path        = "platform"
  type        = "kv"
  options     = { version = "2" }
  description = "Platform team secrets, same layout in every cluster"
}

resource "vault_kv_secret_v2" "cluster_info" {
  mount = vault_mount.platform.path
  name  = "config/cluster"
  data_json = jsonencode({
    cluster = var.cluster
    region  = var.region
    owner   = "platform-team"
  })
}

# --- policies ---------------------------------------------------------------
resource "vault_policy" "platform_reader" {
  name   = "platform-reader"
  policy = <<-EOT
    path "platform/data/*"     { capabilities = ["read"] }
    path "platform/metadata/*" { capabilities = ["list"] }
  EOT
}

resource "vault_policy" "platform_deployer" {
  name   = "platform-deployer"
  policy = <<-EOT
    path "platform/data/config/*" { capabilities = ["read"] }
    path "platform/data/deploy/*" { capabilities = ["create", "read", "update"] }
  EOT
}

# --- machine auth -----------------------------------------------------------
resource "vault_auth_backend" "approle" {
  type        = "approle"
  path        = "approle-platform"
  description = "Platform deployers"
}

resource "vault_approle_auth_backend_role" "deployer" {
  backend        = vault_auth_backend.approle.path
  role_name      = "deployer"
  token_policies = [vault_policy.platform_deployer.name]
  token_ttl      = 1200
  token_max_ttl  = 1800
  secret_id_ttl  = 86400
}

# --- guard rail ---------------------------------------------------------------
resource "vault_quota_rate_limit" "platform" {
  name = "platform"
  path = "${vault_mount.platform.path}/"
  rate = 50
}

output "deployer_role_id" {
  value = vault_approle_auth_backend_role.deployer.role_id
}
