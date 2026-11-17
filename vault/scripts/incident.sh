#!/bin/sh
# Simulates suspicious activity so you can watch Wazuh alerts and Grafana panels react.
# Every step is harmless and undone where needed.
set -u
export VAULT_ADDR=http://${TARGET:-vault-1}:8200
ROOT=$(tr -d '\n ' < ${SECRETS_DIR:-/secrets}/init.json | sed -n 's/.*"root_token":"\([^"]*\)".*/\1/p')

step() { echo; echo "== $*"; }

step "1. Brute force: 8 failed logins for carol (Vault locks her out after 5 by default)"
for i in 1 2 3 4 5 6 7 8; do
  vault login -no-store -method=userpass username=carol password="guess$i" >/dev/null 2>&1
done

step "2. Root token used for routine reads"
VAULT_TOKEN=$ROOT vault kv get secret/admin/break-glass >/dev/null
VAULT_TOKEN=$ROOT vault audit list >/dev/null

step "3. A new root token is minted"
NEWROOT=$(VAULT_TOKEN=$ROOT vault token create -policy=root -ttl=5m -field=token)
VAULT_TOKEN=$ROOT vault token revoke "$NEWROOT" >/dev/null

step "4. Generate-root attempt started and cancelled"
VAULT_TOKEN=$ROOT vault operator generate-root -init >/dev/null 2>&1
VAULT_TOKEN=$ROOT vault operator generate-root -cancel >/dev/null 2>&1

step "5. Rekey attempt started and cancelled (not in the audit log: watch the server log rule)"
VAULT_TOKEN=$ROOT vault operator rekey -init -key-shares=1 -key-threshold=1 >/dev/null 2>&1
VAULT_TOKEN=$ROOT vault operator rekey -cancel >/dev/null 2>&1

step "6. Policy modified"
VAULT_TOKEN=$ROOT vault policy write temp-escalation - >/dev/null <<'EOF'
path "secret/*" { capabilities = ["read", "list"] }
EOF
VAULT_TOKEN=$ROOT vault policy delete temp-escalation >/dev/null

step "7. Repeated permission denied on the break-glass secret"
APP=$(vault login -no-store -method=userpass -field=token username=bob password=bob-pass 2>/dev/null)
for i in 1 2 3 4 5 6; do VAULT_TOKEN=$APP vault kv get secret/admin/break-glass >/dev/null 2>&1; done

echo
echo "Done. Wazuh: Threat Hunting > Events, filter rule.groups:vault. Grafana: Vault overview."
