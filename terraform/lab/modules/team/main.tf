variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "Team names are lowercase letters, digits and dashes, 2 to 31 characters."
  }
}
variable "description" { type = string }
variable "token_ttl" {
  type = number
  validation {
    condition     = var.token_ttl >= 300 && var.token_ttl <= 14400
    error_message = "Application tokens live between 5 minutes and 4 hours."
  }
}
variable "approle_mount" { type = string }

resource "vault_mount" "kv" {
  path        = "team-${var.name}"
  type        = "kv"
  options     = { version = "2" }
  description = var.description
}

resource "vault_policy" "read" {
  name   = "team-${var.name}-read"
  policy = <<-HCL
    path "${vault_mount.kv.path}/data/*"     { capabilities = ["read"] }
    path "${vault_mount.kv.path}/metadata/*" { capabilities = ["read", "list"] }
  HCL
}

resource "vault_policy" "write" {
  name   = "team-${var.name}-write"
  policy = <<-HCL
    path "${vault_mount.kv.path}/data/*"     { capabilities = ["create", "read", "update", "delete"] }
    path "${vault_mount.kv.path}/metadata/*" { capabilities = ["read", "list", "delete"] }
    path "${vault_mount.kv.path}/delete/*"   { capabilities = ["update"] }
    path "${vault_mount.kv.path}/undelete/*" { capabilities = ["update"] }
  HCL
}

resource "vault_approle_auth_backend_role" "app" {
  backend            = var.approle_mount
  role_name          = "${var.name}-app"
  token_policies     = [vault_policy.read.name]
  token_ttl          = var.token_ttl
  token_max_ttl      = 14400
  secret_id_ttl      = 86400
  secret_id_num_uses = 10
}

output "mount" { value = vault_mount.kv.path }
output "approle_role" { value = vault_approle_auth_backend_role.app.role_name }
