#!/bin/sh
# Initializes, unseals and seeds the 3-node lab cluster.
# Safe to run again: on later runs it only unseals.
# LAB ONLY: one unseal key (threshold 1) and the root token are written to ./secrets.
set -eu

# Defaults are the main cluster ("cloud-a"). The second cluster sets these in docker-compose.yml.
SECRETS=${SECRETS_DIR:-/secrets}
INIT_FILE=$SECRETS/init.json
NODES=${NODES:-"vault-1 vault-2 vault-3"}
FIRST_NODE=${NODES%% *}
mkdir -p "$SECRETS"

log() { echo "[vault-init] $*"; }

status_code() {   # 0 = unsealed, 2 = sealed, 1 = error / not reachable
  VAULT_ADDR="http://$1:8200" vault status >/dev/null 2>&1 && echo 0 || echo $?
}

wait_reachable() {
  for i in $(seq 1 90); do
    c=$(status_code "$1")
    [ "$c" != "1" ] && return 0
    sleep 2
  done
  log "$1 not reachable at http://$1:8200 for 3 minutes."
  log "If an earlier start failed (for example a port conflict), recreate the containers:"
  log "  docker compose down && ./lab.sh up      (keeps all data)"
  exit 1
}

json_field() {    # json_field <file> <key>  -> first string value (or first array element)
  tr -d '\n ' < "$1" | sed -n "s/.*\"$2\":\[*\"\([^\"]*\)\".*/\1/p"
}

for n in $NODES; do wait_reachable "$n"; done

export VAULT_ADDR=http://$FIRST_NODE:8200

if ! vault status -format=json 2>/dev/null | grep -q '"initialized": true'; then
  log "initializing $FIRST_NODE (1 key share, threshold 1: lab only)"
  vault operator init -key-shares=1 -key-threshold=1 -format=json > "$INIT_FILE"
  chmod 600 "$INIT_FILE"
  FIRST_RUN=1
else
  FIRST_RUN=0
fi

UNSEAL_KEY=$(json_field "$INIT_FILE" unseal_keys_b64)
ROOT_TOKEN=$(json_field "$INIT_FILE" root_token)
[ -n "$UNSEAL_KEY" ] || { log "cannot read unseal key from $INIT_FILE"; exit 1; }

unseal() {
  for i in $(seq 1 60); do
    c=$(status_code "$1")
    [ "$c" = "0" ] && { log "$1 unsealed"; return 0; }
    VAULT_ADDR="http://$1:8200" vault operator unseal "$UNSEAL_KEY" >/dev/null 2>&1 || true
    sleep 2
  done
  log "could not unseal $1"; exit 1
}

for n in $NODES; do unseal "$n"; done   # on the first run this also joins the followers

# wait for a Raft leader (after a restart, the nodes need a few seconds to elect one)
wait_leader() {
  for i in $(seq 1 60); do
    VAULT_TOKEN=$ROOT_TOKEN vault operator raft list-peers >/dev/null 2>&1 && return 0
    sleep 2
  done
  log "no Raft leader after 120s"; return 1
}
wait_leader

export VAULT_TOKEN=$ROOT_TOKEN

if [ "$FIRST_RUN" = "1" ] || [ ! -f "$SECRETS/.seeded" ]; then
  log "seeding lab configuration"

  # audit device: the file the SIEM reads (shared volume, mounted read-only in Wazuh)
  # mode 0640 instead of the default 0600, so a log shipper in the vault group can read it
  vault audit enable file file_path=/vault/logs/audit.log mode=0640

  # secrets engines
  vault secrets enable -path=secret -version=2 kv
  vault secrets enable transit
  vault write -f transit/keys/payments
  vault kv put secret/app/config api_key=lab-123 db_host=db.lab.local >/dev/null
  vault kv put secret/app/db username=app password=initial-pass >/dev/null
  vault kv put secret/admin/break-glass note="only admins" >/dev/null
  vault secrets enable -path=noisy -version=2 kv
  vault kv put noisy/item value=1 >/dev/null

  # policies
  vault policy write app - <<'EOF'
path "secret/data/app/*"      { capabilities = ["read"] }
path "secret/metadata/app/*"  { capabilities = ["list"] }
path "noisy/data/*"           { capabilities = ["read"] }
path "transit/encrypt/payments" { capabilities = ["update"] }
path "transit/decrypt/payments" { capabilities = ["update"] }
EOF
  vault policy write loadgen - <<'EOF'
path "secret/*"                { capabilities = ["create", "read", "update", "patch", "list"] }
path "transit/*"               { capabilities = ["update"] }
path "auth/token/create"       { capabilities = ["update"] }
path "auth/token/revoke"       { capabilities = ["update"] }
path "auth/approle/role/web/secret-id" { capabilities = ["update"] }
path "auth/approle/role/web/role-id"   { capabilities = ["read"] }
EOF

  # auth methods
  vault auth enable userpass
  vault write auth/userpass/users/alice password=alice-pass token_policies=app token_ttl=15m
  vault write auth/userpass/users/bob   password=bob-pass   token_policies=app token_ttl=15m
  vault write auth/userpass/users/carol password=carol-pass token_policies=app token_ttl=15m  # target of ./lab.sh incident
  vault auth enable approle
  vault write auth/approle/role/web token_policies=app token_ttl=10m secret_id_ttl=1h

  # rate limit quota on one mount so quota metrics have something to show
  vault write sys/quotas/rate-limit/noisy path=noisy/ rate=5 interval=1s
  # rejected (429) requests are not audited unless you turn this on
  vault write sys/quotas/config enable_rate_limit_audit_logging=true

  # token for the load generator
  vault token create -policy=loadgen -policy=app -period=24h -display-name=loadgen -field=token > "$SECRETS/loadgen-token"
  chmod 600 "$SECRETS/loadgen-token"

  touch "$SECRETS/.seeded"
fi

log "cluster ready"
wait_leader && vault operator raft list-peers || true
log "root token saved in $INIT_FILE (./lab.sh token, ./lab.sh token b)"
