# Policy for the identity Terraform runs as (./lab.sh tf mints a 30-minute token with it).
# It can manage configuration: mounts, auth methods, policies, roles, quotas.
# It cannot read application secrets under secret/, unmount engines it does not own,
# list or change audit devices, seal Vault or touch Raft (tested in the lab: 403 on each).
# Terraform state describes access rules, not credentials, so the identity that
# writes it does not need to read credentials.

# token housekeeping used by the provider
path "auth/token/lookup-self" { capabilities = ["read"] }

# secrets engines: only the mounts Terraform owns, so it cannot unmount secret/
# and destroy application data by mistake. The trailing * covers <mount>/tune.
path "sys/mounts" { capabilities = ["read"] }
path "sys/mounts/platform*" { capabilities = ["create", "read", "update", "delete"] }
path "sys/mounts/tfdemo*"   { capabilities = ["create", "read", "update", "delete"] }
path "sys/mounts/noisy*"    { capabilities = ["create", "read", "update", "delete"] } # adopt exercise

# auth methods, same idea (enabling and disabling an auth method needs sudo)
path "sys/auth" { capabilities = ["read"] }
path "sys/auth/approle-platform*" { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "sys/auth/approle-tfdemo*"   { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "sys/auth/userpass*"         { capabilities = ["create", "read", "update", "delete", "sudo"] } # adopt exercise
path "sys/mounts/auth/*"          { capabilities = ["read"] }

# ACL policies (the provider uses both API paths)
path "sys/policy"        { capabilities = ["read", "list"] }
path "sys/policy/*"      { capabilities = ["create", "read", "update", "delete"] }
path "sys/policies/acl"   { capabilities = ["list"] }
path "sys/policies/acl/*" { capabilities = ["create", "read", "update", "delete"] }

# quotas
path "sys/quotas/config"       { capabilities = ["read", "update"] }
path "sys/quotas/rate-limit/*" { capabilities = ["create", "read", "update", "delete", "list"] }

# auth method configuration and roles managed by Terraform in this lab
path "auth/approle-platform/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "auth/approle-tfdemo/*"   { capabilities = ["create", "read", "update", "delete", "list"] }
path "auth/userpass/users/*"   { capabilities = ["create", "read", "update", "delete", "list"] }

# KV mounts owned by Terraform: platform/ (baseline) and tfdemo/ (state-secrets demo).
# Note the KV v2 API paths: data/ and metadata/, not the CLI path.
path "platform/data/*"     { capabilities = ["create", "read", "update", "delete"] }
path "platform/metadata/*" { capabilities = ["read", "delete", "list"] }
path "tfdemo/data/*"       { capabilities = ["create", "read", "update", "delete"] }
path "tfdemo/metadata/*"   { capabilities = ["read", "delete", "list"] }

# terraform/lab, applied by the GitHub Actions pipeline (role terraform-apply):
# one KV mount per team (team-<name>/), team policies and AppRole roles under approle-teams/
path "sys/mounts/team-*"        { capabilities = ["create", "read", "update", "delete"] }
path "sys/auth/approle-teams*"  { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "auth/approle-teams/*"     { capabilities = ["create", "read", "update", "delete", "list"] }
