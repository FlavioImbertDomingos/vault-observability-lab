#!/bin/sh
# One-time bootstrap for the IaC pipeline, run inside vault-1 by "./lab.sh iac up".
# This is the break-glass part that cannot come from the pipeline itself: it uses the
# root token to create the identity the pipeline logs in with. Safe to run again.
#
# Needs: VAULT_TOKEN (root), GITHUB_REPO (owner/repo), policy files in /tmp.
# Optional: JWT_VALIDATION_PUBKEY (PEM) to test offline instead of GitHub's keys.
set -eu

MOUNT=jwt-github
ISSUER="https://token.actions.githubusercontent.com"

vault policy write terraform      /tmp/terraform-policy.hcl >/dev/null
vault policy write terraform-plan /tmp/terraform-plan-policy.hcl >/dev/null
echo "  policies: terraform (apply), terraform-plan (read only)"

vault auth list -format=json | grep -q "\"$MOUNT/\"" || \
  vault auth enable -path=$MOUNT -description="GitHub Actions OIDC tokens" jwt >/dev/null

# Vault checks each job token's signature against GitHub's published keys and its
# "iss" against bound_issuer. Vault needs outbound HTTPS to fetch the keys.
if [ -n "${JWT_VALIDATION_PUBKEY:-}" ]; then
  printf '%s\n' "$JWT_VALIDATION_PUBKEY" > /tmp/jwt-test.pem
  vault write auth/$MOUNT/config jwt_validation_pubkeys=@/tmp/jwt-test.pem bound_issuer="$ISSUER" >/dev/null
  echo "  auth/$MOUNT: offline test key (not GitHub)"
else
  vault write auth/$MOUNT/config oidc_discovery_url="$ISSUER" bound_issuer="$ISSUER" >/dev/null
  echo "  auth/$MOUNT: trusts $ISSUER"
fi

# Both roles: only jobs from this repository, audience "vault", 15-minute tokens.
# claim_mappings copy who and what ran the job into the token metadata, so every
# request in the Vault audit log shows the GitHub user, commit, workflow and run.
role() {   # role <name> <policy> <extra bound claims JSON>
  vault write auth/$MOUNT/role/"$1" - >/dev/null <<JSON
{
  "role_type": "jwt",
  "bound_audiences": ["vault"],
  "user_claim": "actor",
  "bound_claims_type": "string",
  "bound_claims": { "repository": "$GITHUB_REPO" $3 },
  "claim_mappings": {
    "actor": "actor", "repository": "repository", "ref": "ref", "sha": "sha",
    "workflow": "workflow", "run_id": "run_id", "event_name": "event_name"
  },
  "token_policies": ["$2"],
  "token_ttl": "15m",
  "token_max_ttl": "30m",
  "token_no_default_policy": true
}
JSON
  echo "  role $1 -> policy $2 ($GITHUB_REPO$4)"
}
role terraform-plan  terraform-plan "" ""
role terraform-apply terraform ', "ref": "refs/heads/main", "environment": "lab"' ", main branch, environment lab"
