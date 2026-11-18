# Where do secrets end up when Terraform touches them?
# Each pair below does the same job twice: once the classic way, which stores the
# secret in terraform.tfstate in plain text, and once with an ephemeral resource or
# a write-only argument, which never stores it. "sensitive" only hides values from
# the screen; it does not keep them out of state.
#
#   ./lab.sh tf state-secrets apply
#   ./lab.sh secrets-check

resource "vault_mount" "tfdemo" {
  path        = "tfdemo"
  type        = "kv"
  options     = { version = "2" }
  description = "Terraform secrets-in-state demo"
}

# --- 1. Writing a secret into Vault ----------------------------------------

# Classic: data_json is a normal argument, so the value is saved in state.
# (An ephemeral variable is not allowed here; Terraform would stop at validate.)
resource "vault_kv_secret_v2" "write_classic" {
  mount     = vault_mount.tfdemo.path
  name      = "app/db-classic"
  data_json = jsonencode({ password = var.classic_password })
}

# Write-only: data_json_wo is sent to Vault and then forgotten.
resource "vault_kv_secret_v2" "write_only" {
  mount                = vault_mount.tfdemo.path
  name                 = "app/db"
  data_json_wo         = jsonencode({ password = var.demo_password })
  data_json_wo_version = var.secret_version
}

# --- 2. Reading a secret from Vault and handing it to another resource -----

# Classic: a data source. Everything it reads is saved in state. Recent provider
# versions mark this data source deprecated in favour of the ephemeral resource,
# so the deprecation warnings on plan and validate are expected here.
data "vault_kv_secret_v2" "read_classic" {
  mount = vault_mount.tfdemo.path
  name  = vault_kv_secret_v2.write_only.name
}

resource "vault_kv_secret_v2" "consumer_classic" {
  mount     = vault_mount.tfdemo.path
  name      = "downstream/classic"
  data_json = jsonencode({ db_password = data.vault_kv_secret_v2.read_classic.data["password"] })
}

# Ephemeral: read at plan and apply time, never saved. Terraform refuses to put an
# ephemeral value into a normal argument, so it can only flow into write-only
# arguments, provider blocks or other ephemeral contexts.
ephemeral "vault_kv_secret_v2" "read" {
  mount = vault_mount.tfdemo.path
  name  = vault_kv_secret_v2.write_only.name
  # mount_id is unknown until the mount exists, which tells the provider to wait
  # for apply instead of reading during the first plan (the secret is not there yet)
  mount_id = vault_mount.tfdemo.id
}

# Stands in for any resource with a write-only argument, for example
# aws_db_instance.password_wo (with password_wo_version).
resource "vault_kv_secret_v2" "consumer" {
  mount                = vault_mount.tfdemo.path
  name                 = "downstream/ephemeral"
  data_json_wo         = jsonencode({ db_password = ephemeral.vault_kv_secret_v2.read.data["password"] })
  data_json_wo_version = var.secret_version
}

# --- 3. Issuing a machine credential ---------------------------------------

resource "vault_auth_backend" "approle" {
  type = "approle"
  path = "approle-tfdemo"
}

resource "vault_approle_auth_backend_role" "ci" {
  backend        = vault_auth_backend.approle.path
  role_name      = "ci"
  token_policies = ["default"]
  token_ttl      = 600
  secret_id_ttl  = 3600 # every plan and apply issues a new SecretID, so keep them short-lived
}

# A new SecretID, never written to state. Here it lands in a write-only KV field;
# in a real pipeline the target would be the CI system's secret store, through a
# resource with a write-only argument.
ephemeral "vault_approle_auth_backend_role_secret_id" "ci" {
  backend   = vault_auth_backend.approle.path
  role_name = vault_approle_auth_backend_role.ci.role_name
  mount_id  = vault_auth_backend.approle.id # same trick: wait for apply on the first run
}

resource "vault_kv_secret_v2" "ci_credentials" {
  mount = vault_mount.tfdemo.path
  name  = "ci/approle"
  data_json_wo = jsonencode({
    role_id   = vault_approle_auth_backend_role.ci.role_id
    secret_id = ephemeral.vault_approle_auth_backend_role_secret_id.ci.secret_id
  })
  data_json_wo_version = var.secret_version
}
