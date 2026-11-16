# Minimum policy for the upgrade playbook. Create a short-lived token with it:
#   vault policy write vault-upgrade upgrade-policy.hcl
#   export VAULT_TOKEN=$(vault token create -policy=vault-upgrade -ttl=1h -field=token)
path "sys/storage/raft/autopilot/state" { capabilities = ["read"] }
path "sys/storage/raft/configuration"   { capabilities = ["read"] }
path "sys/storage/raft/snapshot"        { capabilities = ["read"] }
path "sys/step-down"                    { capabilities = ["update", "sudo"] }
