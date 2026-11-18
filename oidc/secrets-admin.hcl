# Policy for members of the Keycloak group vault-admins (through a Vault external group).
# Manage application secrets under secret/; nothing under sys/.
path "secret/data/*"     { capabilities = ["create", "read", "update", "delete"] }
path "secret/metadata/*" { capabilities = ["read", "list", "delete"] }
path "secret/delete/*"   { capabilities = ["update"] }
path "secret/undelete/*" { capabilities = ["update"] }
