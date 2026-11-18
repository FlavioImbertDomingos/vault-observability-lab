#!/bin/sh
# Configure Vault's OIDC auth method against the lab Keycloak realm.
# Runs inside a Vault container (./lab.sh oidc up pipes it in), so it uses the
# vault CLI there. Safe to run again: every step overwrites or checks first.
# Needs: VAULT_TOKEN, OIDC_URL, CLIENT_SECRET, VAULT_PORTS (UI ports for redirects).
set -eu

MOUNT=oidc

vault auth list -format=json | grep -q "\"$MOUNT/\"" || vault auth enable -path=$MOUNT oidc

# Vault fetches $OIDC_URL/.well-known/openid-configuration and the signing keys from
# the container network, and checks that the "iss" in each token equals $OIDC_URL.
vault write auth/$MOUNT/config \
  oidc_discovery_url="$OIDC_URL" \
  oidc_client_id="vault" \
  oidc_client_secret="$CLIENT_SECRET" \
  default_role="default"

# Redirects: the CLI listener on 8250 and the web UI on each node's port.
REDIRECTS="http://localhost:8250/oidc/callback"
for p in $VAULT_PORTS; do
  REDIRECTS="$REDIRECTS,http://localhost:$p/ui/vault/auth/$MOUNT/oidc/callback"
done

# user_claim names the entity alias. preferred_username is readable in the audit log;
# in production prefer a claim that never changes or gets reused, such as sub or oid.
REDIRECT_JSON=$(echo "$REDIRECTS" | sed 's/,/", "/g')
vault write auth/$MOUNT/role/default - >/dev/null <<JSON
{
  "role_type": "oidc",
  "user_claim": "preferred_username",
  "groups_claim": "groups",
  "claim_mappings": { "preferred_username": "username", "email": "email" },
  "oidc_scopes": ["profile", "email"],
  "allowed_redirect_uris": ["$REDIRECT_JSON"],
  "token_policies": ["default"],
  "token_ttl": "1h",
  "token_max_ttl": "8h"
}
JSON
echo "Success! Data written to: auth/$MOUNT/role/default"

# Policies come from group membership in Keycloak, not from the role:
# an external group per Keycloak group, linked by a group alias with the same name.
vault policy write secrets-admin /tmp/secrets-admin.hcl >/dev/null
ACCESSOR=$(vault auth list -format=json | sed -n "/\"$MOUNT\/\"/,/accessor/s/.*\"accessor\": \"\([^\"]*\)\".*/\1/p" | head -1)

map_group() {   # map_group <keycloak group> <vault policies>
  vault write identity/group/name/"$1" type=external policies="$2" >/dev/null   # create or update
  gid=$(vault read -field=id identity/group/name/"$1")
  if vault write -format=json identity/lookup/group alias_name="$1" alias_mount_accessor="$ACCESSOR" 2>/dev/null | grep -q '"id"'; then
    echo "  group $1 -> $2 (alias exists)"
  else
    vault write identity/group-alias name="$1" mount_accessor="$ACCESSOR" canonical_id="$gid" >/dev/null
    echo "  group $1 -> $2"
  fi
}
map_group vault-admins  "secrets-admin"
map_group vault-readers "app"

echo "OIDC auth configured at auth/$MOUNT/ (issuer $OIDC_URL)"
