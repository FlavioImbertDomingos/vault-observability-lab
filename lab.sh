#!/usr/bin/env bash
# Vault observability lab helper.
#   ./lab.sh up         start everything (generates Wazuh certs on first run)
#   ./lab.sh core       start only Vault + Prometheus + Grafana (no Wazuh, ~1 GB RAM)
#   ./lab.sh status     containers, Raft peers, URLs
#   ./lab.sh incident   simulate suspicious activity for the SIEM
#   ./lab.sh dashboards (re)import the "Vault SIEM" dashboard into Wazuh
#   ./lab.sh unseal     re-run init/unseal (after a restart of the Vault containers)
#   ./lab.sh token      print the root token
#   ./lab.sh versions   Vault version and role of each node
#   ./lab.sh snapshot   save a Raft snapshot to ./backups
#   ./lab.sh upgrade V  rolling upgrade to Vault version V (for example 1.20.4)
#   ./lab.sh multicloud up|down|status   second independent cluster ("cloud-b") on 8300-8320
#   ./lab.sh tf plan|apply|...           Terraform baseline applied to both clusters
#   ./lab.sh tf state-secrets|adopt ...  Terraform demos (secrets in state, importing existing config)
#   ./lab.sh secrets-check               which Terraform resources hold the demo password in state
#   ./lab.sh oidc up|down|status         Keycloak as OIDC provider, Vault logins mapped from its groups
#   ./lab.sh iac up|runner|status|down   GitHub Actions pipeline for terraform/lab (plan, approve, apply)
#   ./lab.sh token b    print the root token of cloud-b
#   ./lab.sh down       stop (keeps data)
#   ./lab.sh reset      stop and delete ALL data, secrets and Wazuh certs
set -euo pipefail
cd "$(dirname "$0")"

# optional overrides (ports, versions, passwords)
if [ -f .env ]; then set -a; . ./.env; set +a; fi
VAULT_PORT=${VAULT_PORT:-8200}; VAULT2_PORT=${VAULT2_PORT:-8210}; VAULT3_PORT=${VAULT3_PORT:-8220}
PROMETHEUS_PORT=${PROMETHEUS_PORT:-9090}; GRAFANA_PORT=${GRAFANA_PORT:-3000}; WAZUH_PORT=${WAZUH_PORT:-8443}
WAZUH_AGENT_PORT=${WAZUH_AGENT_PORT:-1514}; WAZUH_ENROLL_PORT=${WAZUH_ENROLL_PORT:-1515}

CERTS=wazuh/config/wazuh_indexer_ssl_certs
CORE="vault-1 vault-2 vault-3 vault-init loadgen audit-rotate prometheus grafana"

root_token() { sed -n 's/.*"root_token": *"\([^"]*\)".*/\1/p' secrets/init.json 2>/dev/null; }
root_token_b() { sed -n 's/.*"root_token": *"\([^"]*\)".*/\1/p' secrets/cloud-b/init.json 2>/dev/null; }

urls() {
  cat <<EOF

  Vault UI     http://localhost:$VAULT_PORT      token: ./lab.sh token
  Prometheus   http://localhost:$PROMETHEUS_PORT      alerts: http://localhost:$PROMETHEUS_PORT/alerts
  Grafana      http://localhost:$GRAFANA_PORT      admin / ${GRAFANA_PASSWORD:-vaultlab}
  Wazuh        https://localhost:$WAZUH_PORT     admin / SecretPassword   (self-signed cert)
EOF
}

import_dashboards() {
  echo "Waiting for the Wazuh dashboard to import the Vault SIEM dashboard (up to 10 min)..."
  for i in $(seq 1 120); do
    if curl -sk -o /dev/null -w '%{http_code}' -u admin:SecretPassword https://localhost:$WAZUH_PORT/api/status | grep -q 200; then
      # index pattern first, never overwriting the one the Wazuh app creates
      curl -sk -o /dev/null -u admin:SecretPassword -H 'osd-xsrf: true' \
        --form file=@wazuh/wazuh-alerts-index-pattern.ndjson \
        "https://localhost:$WAZUH_PORT/api/saved_objects/_import?overwrite=false"
      curl -sk -u admin:SecretPassword -H 'osd-xsrf: true' \
        --form file=@wazuh/vault-siem-dashboard.ndjson \
        "https://localhost:$WAZUH_PORT/api/saved_objects/_import?overwrite=true" | grep -q '"success":true' \
        && { echo "Imported: Wazuh > Dashboards > Vault SIEM"; return 0; }
    fi
    sleep 5
  done
  echo "Wazuh dashboard not ready yet; run ./lab.sh dashboards later."
}

# Stop early with a clear message if another program already holds one of our ports.
check_ports() {   # check_ports <var names...>
  local ours bad=0 v p
  ours=$(docker ps --filter label=com.docker.compose.project=vault-lab --format '{{.Ports}}' 2>/dev/null || true)
  for v in "$@"; do
    p=${!v}
    echo "$ours" | grep -q ":$p->" && continue          # already ours, running
    if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
      echo "Port $p ($v) is already in use by another program."
      echo "  See what holds it:   lsof -nP -iTCP:$p -sTCP:LISTEN"
      echo "  Or use another port: echo $v=1$p >> .env"
      bad=1
    fi
  done
  [ $bad -eq 0 ] || { echo; echo "Fix the port(s) above, then run the command again."; exit 1; }
}
ALL_PORTS="VAULT_PORT VAULT2_PORT VAULT3_PORT PROMETHEUS_PORT GRAFANA_PORT WAZUH_PORT WAZUH_AGENT_PORT WAZUH_ENROLL_PORT"
CORE_PORTS="VAULT_PORT VAULT2_PORT VAULT3_PORT PROMETHEUS_PORT GRAFANA_PORT"
VAULTB1_PORT=${VAULTB1_PORT:-8300}; VAULTB2_PORT=${VAULTB2_PORT:-8310}; VAULTB3_PORT=${VAULTB3_PORT:-8320}
B_PORTS="VAULTB1_PORT VAULTB2_PORT VAULTB3_PORT"
B_SERVICES="vaultb-1 vaultb-2 vaultb-3 vaultb-init loadgen-b"
MC="docker compose --profile multicloud --profile oidc --profile iac"   # down/reset cover every profile
IAC="docker compose --profile iac"
TFSTATE_PORT=${TFSTATE_PORT:-5433}
GITHUB_REPO=${GITHUB_REPO:-FlavioImbertDomingos/vault-observability-lab}
KEYCLOAK_PORT=${KEYCLOAK_PORT:-8180}
OIDC="docker compose --profile oidc"

# ------------------------------------------------------------ multi-cloud helpers
versions_b() {
  local n v r
  for n in 1 2 3; do
    v=$(docker compose exec -T vaultb-"$n" vault status -format=json 2>/dev/null || true)
    r=$(echo "$v" | grep -q '"is_self": true' && echo active || echo standby)
    printf "  vaultb-%s %-8s %s\n" "$n" "$(echo "$v" | sed -n 's/^ *"version": "\([^"]*\)".*/\1/p')" "$r"
  done
}

multicloud() {
  case "${1:-}" in
    up)
      check_ports $B_PORTS
      $MC up -d $B_SERVICES || { $MC logs --tail 25 vaultb-init; exit 1; }
      $MC wait vaultb-init >/dev/null 2>&1 || true
      $MC logs vaultb-init | tail -6
      cat > prometheus/targets/cloud-b.json <<JSON
[{ "targets": ["vaultb-1:8200", "vaultb-2:8200", "vaultb-3:8200"], "labels": { "cluster": "cloud-b" } }]
JSON
      curl -s -X POST "http://localhost:$PROMETHEUS_PORT/-/reload" >/dev/null 2>&1 || true
      # the Wazuh log collector only picks up files that exist when it starts
      if [ -n "$(docker compose ps -q wazuh.manager 2>/dev/null)" ]; then docker compose restart wazuh.manager >/dev/null; fi
      echo
      echo "cloud-b is up: http://localhost:$VAULTB1_PORT (also $VAULTB2_PORT, $VAULTB3_PORT), token: ./lab.sh token b"
      echo "Grafana: Vault multi-cloud dashboard, or pick cluster=cloud-b in Vault overview."
      echo "Next: ./lab.sh tf apply   (same baseline on both clusters)" ;;
    down)
      $MC stop $B_SERVICES
      echo '[]' > prometheus/targets/cloud-b.json ;;
    status|"")
      echo "cloud-a:"; versions; echo "cloud-b:"; versions_b ;;
    *) echo "Usage: ./lab.sh multicloud up|down|status"; exit 1 ;;
  esac
}

# ------------------------------------------------------------ OIDC (Keycloak)
oidc() {
  local url="http://keycloak:$KEYCLOAK_PORT/realms/lab"
  case "${1:-}" in
    up)
      [ -n "$(root_token)" ] || { echo "cloud-a is not initialized. Run: ./lab.sh up"; exit 1; }
      check_ports KEYCLOAK_PORT
      $OIDC up -d keycloak
      printf "Waiting for Keycloak"
      local i
      for i in $(seq 1 90); do
        [ "$(docker inspect -f '{{.State.Health.Status}}' "$($OIDC ps -q keycloak)" 2>/dev/null)" = healthy ] && break
        printf "."; sleep 2
      done; echo
      docker compose cp oidc/secrets-admin.hcl vault-1:/tmp/secrets-admin.hcl >/dev/null 2>&1
      docker compose exec -T -e VAULT_TOKEN="$(root_token)" -e OIDC_URL="$url" \
        -e CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-vault-lab-oidc-secret}" \
        -e VAULT_PORTS="$VAULT_PORT $VAULT2_PORT $VAULT3_PORT" vault-1 sh -s < oidc/configure-vault.sh
      echo
      if ! curl -s -o /dev/null --max-time 3 "$url/.well-known/openid-configuration"; then
        echo "This machine cannot open $url yet. Add the host name once:"
        echo "  echo '127.0.0.1 keycloak' | sudo tee -a /etc/hosts"
        echo
      fi
      echo "Keycloak:  http://keycloak:$KEYCLOAK_PORT  (admin console: admin / ${KEYCLOAK_ADMIN_PASSWORD:-admin})"
      echo "Users:     olivia / olivia-pass (vault-admins), oscar / oscar-pass (vault-readers), nora / nora-pass (no group)"
      echo "Log in:    vault login -method=oidc    or the Vault UI, method OIDC" ;;
    down)
      $OIDC rm -sf keycloak >/dev/null 2>&1   # Keycloak keeps its data in the container; the realm is re-imported on the next up
      echo "Keycloak stopped and removed. Vault keeps auth/oidc; ./lab.sh oidc up brings Keycloak back." ;;
    status|"")
      $OIDC ps keycloak
      curl -s --max-time 3 "http://localhost:$KEYCLOAK_PORT/realms/lab/.well-known/openid-configuration" \
        | grep -o '"issuer":"[^"]*"' || echo "Keycloak is not answering on port $KEYCLOAK_PORT" ;;
    *) echo "Usage: ./lab.sh oidc up|down|status"; exit 1 ;;
  esac
}

# ------------------------------------------------------------ IaC pipeline
iac() {
  case "${1:-}" in
    up)
      [ -n "$(root_token)" ] || { echo "cloud-a is not initialized. Run: ./lab.sh up"; exit 1; }
      check_ports TFSTATE_PORT
      $IAC up -d tfstate
      printf "Waiting for the state database"
      local i
      for i in $(seq 1 60); do
        [ "$(docker inspect -f '{{.State.Health.Status}}' "$($IAC ps -q tfstate)" 2>/dev/null)" = healthy ] && break
        printf "."; sleep 2
      done; echo
      echo "Bootstrapping Vault for $GITHUB_REPO:"
      docker compose cp terraform/terraform-policy.hcl vault-1:/tmp/terraform-policy.hcl >/dev/null 2>&1
      docker compose cp iac/terraform-plan-policy.hcl vault-1:/tmp/terraform-plan-policy.hcl >/dev/null 2>&1
      docker compose exec -T -e VAULT_TOKEN="$(root_token)" -e GITHUB_REPO="$GITHUB_REPO" \
        -e JWT_VALIDATION_PUBKEY="${JWT_VALIDATION_PUBKEY:-}" vault-1 sh -s < iac/bootstrap-vault.sh
      if $IAC run --rm --no-deps --entrypoint test gh-runner -f /home/runner/.runner >/dev/null 2>&1; then
        $IAC up -d gh-runner; echo "Runner started (already registered)."
      else
        echo
        echo "Next: register the runner. In GitHub: Settings > Actions > Runners > New self-hosted runner,"
        echo "copy the token from the ./config.sh line, then run: ./lab.sh iac runner <token>"
        echo "(or with the GitHub CLI: ./lab.sh iac runner \$(gh api -X POST repos/$GITHUB_REPO/actions/runners/registration-token -q .token))"
      fi ;;
    runner)
      [ -n "${2:-}" ] || { echo "Usage: ./lab.sh iac runner <registration-token>"; exit 1; }
      RUNNER_TOKEN="$2" $IAC up -d gh-runner
      printf "Registering"
      local i
      for i in $(seq 1 60); do
        $IAC logs gh-runner 2>&1 | grep -q "Listening for Jobs" && { echo; echo "Runner online: GitHub > Settings > Actions > Runners shows vault-lab as Idle."; return; }
        # stop waiting only if the container exited (bad or expired token)
        [ "$(docker inspect -f '{{.State.Running}}' "$($IAC ps -aq gh-runner)" 2>/dev/null)" = true ] || break
        printf "."; sleep 2
      done; echo
      echo "Runner did not report \"Listening for Jobs\". Last lines:"
      $IAC logs --tail 15 gh-runner 2>&1 | grep -v " INFO " ;;
    status)
      $IAC ps tfstate gh-runner
      $IAC logs --tail 3 gh-runner 2>/dev/null || true ;;
    down)
      $IAC stop gh-runner tfstate >/dev/null 2>&1
      echo "Runner and state database stopped. Data kept; ./lab.sh iac up starts them again." ;;
    *) echo "Usage: ./lab.sh iac up|runner <token>|status|down"; exit 1 ;;
  esac
}

# ------------------------------------------------------------ terraform
# Terraform does not run as root. Root (the bootstrap credential) writes the
# "terraform" policy once, then every run gets a fresh 30-minute token with it.
TF_DIRS="multicloud state-secrets adopt lab"

tf_token() {   # tf_token a|b [plan]  -> short-lived token with the terraform (or terraform-plan) policy
  local svc=vault-1 tok mc="docker compose" pol=terraform file=terraform/terraform-policy.hcl
  tok=$(root_token)
  if [ "$1" = "b" ]; then svc=vaultb-1; tok=$(root_token_b); mc=$MC; fi
  if [ "${2:-}" = "plan" ]; then pol=terraform-plan; file=iac/terraform-plan-policy.hcl; fi
  [ -n "$tok" ] || return 0
  $mc exec -T -e VAULT_TOKEN="$tok" "$svc" vault policy write $pol - < $file >/dev/null
  $mc exec -T -e VAULT_TOKEN="$tok" "$svc" vault token create -policy=$pol \
    -ttl=30m -display-name=$pol -field=token
}

tf() {   # ./lab.sh tf [multicloud|state-secrets|adopt] <terraform args>
  local name=multicloud
  case " $TF_DIRS " in *" ${1:-} "*) name=$1; shift ;; esac
  local dir=terraform/$name
  [ $# -gt 0 ] || { echo "usage: ./lab.sh tf [${TF_DIRS// /|}] plan|apply|destroy|..."; exit 1; }
  [ -n "$(root_token)" ] || { echo "cloud-a is not initialized. Run: ./lab.sh up"; exit 1; }
  if [ "$name" = multicloud ] && [ -z "$(root_token_b)" ]; then
    echo "cloud-b is not initialized. Run: ./lab.sh multicloud up"; exit 1
  fi
  local ta tb pg="" pgd=""
  if [ "$name" = lab ]; then
    # terraform/lab belongs to the pipeline: on this machine you get a plan-only token,
    # so "apply" fails with 403. Changes go through a pull request.
    ta=$(tf_token a plan); tb=""
    pg="postgres://terraform:${TFSTATE_DB_PASSWORD:-terraform-lab}@localhost:$TFSTATE_PORT/tfstate?sslmode=disable"
    pgd="postgres://terraform:${TFSTATE_DB_PASSWORD:-terraform-lab}@tfstate:5432/tfstate?sslmode=disable"
  else
    ta=$(tf_token a); tb=$(tf_token b 2>/dev/null || true)   # cloud-b may be stopped
  fi
  if command -v terraform >/dev/null 2>&1; then
    ( cd "$dir"
      export TF_VAR_cloud_a_token="$ta" TF_VAR_cloud_b_token="$tb" PG_CONN_STR="$pg" \
        VAULT_ADDR="http://localhost:$VAULT_PORT" VAULT_TOKEN="$ta" \
        TF_VAR_cloud_a_address="http://localhost:$VAULT_PORT" TF_VAR_cloud_b_address="http://localhost:$VAULTB1_PORT"
      [ -d .terraform ] || terraform init -input=false >/dev/null
      terraform "$@" )
  else   # no local Terraform: use the official image on the lab network
    local run="docker run --rm --network vault-lab_default -v $PWD/$dir:/work -w /work \
      -e TF_VAR_cloud_a_token=$ta -e TF_VAR_cloud_b_token=$tb -e PG_CONN_STR=$pgd \
      -e VAULT_ADDR=http://vault-1:8200 -e VAULT_TOKEN=$ta \
      -e TF_VAR_cloud_a_address=http://vault-1:8200 -e TF_VAR_cloud_b_address=http://vaultb-1:8200 \
      hashicorp/terraform:${TERRAFORM_VERSION:-1.17}"
    [ -d "$dir/.terraform" ] || $run init -input=false >/dev/null
    $run "$@"
  fi
}

secrets_check() {   # where does the demo password end up? (terraform/state-secrets)
  local f=terraform/state-secrets/terraform.tfstate pw=lab-demo-S3cret-4242
  [ -f "$f" ] || { echo "Run first: ./lab.sh tf state-secrets apply"; exit 1; }
  echo "Resources in $f and whether the demo password ($pw) is stored with them:"
  awk -v pw="$pw" '
    # resource headers sit at a fixed indent in the state JSON (6 spaces)
    /^      "mode": / { m = ($0 ~ /"data"/) ? "data." : "" }
    /^      "type": / { t = $0; sub(/.*"type": "/, "", t); sub(/".*/, "", t) }
    /^      "name": / { n = $0; sub(/.*"name": "/, "", n); sub(/".*/, "", n); a = m t "." n; seen[a] = 0; order[++k] = a }
    index($0, pw) && a != "" { seen[a]++ }
    END { for (i = 1; i <= k; i++) printf "  %-9s %s\n", (seen[order[i]] ? "IN STATE" : "clean"), order[i] }
  ' "$f"
  echo "Plain-text copies in the file: $(grep -c "$pw" "$f" || true)"
}

# ------------------------------------------------------------ upgrade helpers
VNODES="1 2 3"
vstat() { docker compose exec -T vault-"$1" vault status -format=json 2>/dev/null || true; }
jfield() { sed -n "s/^ *\"$1\": *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\} *$/\1/p" | head -1; }
node_version() { vstat "$1" | jfield version; }
leader() { for n in $VNODES; do vstat "$n" | grep -q "\"is_self\": true" && { echo "$n"; return 0; }; done; return 0; }
vexec() { local n=$1; shift; docker compose exec -T -e VAULT_TOKEN="$(root_token)" vault-"$n" vault "$@"; }

set_env() {   # set_env KEY VALUE  (persist in .env and in this shell)
  touch .env; { grep -v "^$1=" .env || true; } > .env.tmp; echo "$1=$2" >> .env.tmp; mv .env.tmp .env; export "$1=$2"
}
unset_env() { [ -f .env ] && { grep -v "^$1=" .env || true; } > .env.tmp && mv .env.tmp .env; unset "$1"; }

versions() {
  local l; l=$(leader)
  for n in $VNODES; do
    printf "  vault-%s  %-8s %s\n" "$n" "$(node_version "$n")" "$([ "$n" = "$l" ] && echo active || echo standby)"
  done
}

snapshot() {
  mkdir -p backups
  local f="pre-upgrade-$(date +%Y%m%d-%H%M%S).snap" l; l=$(leader)
  [ -n "$l" ] || { echo "No active node. Unseal first: ./lab.sh unseal"; exit 1; }
  docker compose run --rm --no-deps -e VAULT_ADDR="http://vault-$l:8200" -e VAULT_TOKEN="$(root_token)" \
    vault-init -c "vault operator raft snapshot save /backups/$f" >/dev/null 2>&1 || true
  [ -s "backups/$f" ] || { echo "Snapshot failed"; exit 1; }
  echo "  snapshot: backups/$f ($(wc -c < "backups/$f" | tr -d ' ') bytes)"
}

wait_healthy() {   # wait_healthy [NODE VERSION]: autopilot healthy, can lose one voter, NODE on VERSION
  local l s blk
  sleep 5
  for i in $(seq 1 60); do
    l=$(leader)
    if [ -n "$l" ]; then
      s=$(vexec "$l" operator raft autopilot state -format=json 2>/dev/null || true)
      # first "Healthy" in the JSON is the cluster-level value
      if echo "$s" | grep -m1 -Ei '"healthy":' | grep -q true \
         && echo "$s" | grep -Eq '"(FailureTolerance|failure_tolerance)": [1-9]'; then
        [ -z "${1:-}" ] && return 0
        blk=$(echo "$s" | awk -v n="\"vault-$1\": {" 'index($0,n){f=1} f{print} f&&/NodeType/{exit}')
        echo "$blk" | grep -q "\"Version\": \"$2\"" && echo "$blk" | grep -q '"Healthy": true' && return 0
      fi
    fi
    sleep 5
  done
  echo "Cluster not healthy after 5 minutes. Check: ./lab.sh status"; exit 1
}

upgrade_node() {   # upgrade_node N VERSION
  local n=$1 v=$2 rc
  echo "- vault-$n: $(node_version "$n") -> $v"
  set_env "VAULT${n}_VERSION" "$v"
  docker compose up -d --no-deps vault-"$n" >/dev/null 2>&1
  for i in $(seq 1 60); do   # wait until the new process answers (0 unsealed, 2 sealed)
    rc=0; docker compose exec -T vault-"$n" vault status >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 1 ] && break; sleep 2
  done
  docker compose run --rm --no-deps vault-init /scripts/init.sh > "backups/unseal-vault-$n.log" 2>&1 \
    || { echo "  unseal failed, see backups/unseal-vault-$n.log"; exit 1; }
  wait_healthy "$n" "$v"
  echo "  vault-$n is $(node_version "$n"), unsealed, healthy in autopilot"
}

upgrade() {
  local target=${1:-} l n new todo
  [ -n "$target" ] || { echo "Usage: ./lab.sh upgrade <version>   (tags: https://hub.docker.com/r/hashicorp/vault/tags)"; exit 1; }
  mkdir -p backups
  echo "Pulling hashicorp/vault:$target ..."; docker pull -q "hashicorp/vault:$target" >/dev/null
  echo "Before:"; versions
  echo "1. Pre-checks and snapshot"
  wait_healthy; snapshot
  echo "2. Upgrade standbys one at a time, the active node last"
  while :; do
    l=$(leader); todo=""
    for n in $VNODES; do [ "$(node_version "$n")" != "$target" ] && todo="$todo $n"; done
    [ -z "$todo" ] && break
    n=""; for c in $todo; do [ "$c" != "$l" ] && { n=$c; break; }; done
    if [ -z "$n" ]; then
      echo "- vault-$l is active and still on $(node_version "$l"): stepping it down"
      vexec "$l" operator step-down >/dev/null 2>&1 || true
      for i in $(seq 1 30); do new=$(leader); [ -n "$new" ] && [ "$new" != "$l" ] && break; sleep 2; done
      echo "  new active node: vault-$new ($(node_version "$new"))"
      n=$l
    fi
    upgrade_node "$n" "$target"
  done
  for n in $VNODES; do unset_env "VAULT${n}_VERSION"; done
  set_env VAULT_VERSION "$target"
  echo "Done. After:"; versions
  echo "Rollback, if ever needed: stop the cluster, set VAULT_VERSION back, restore the snapshot from backups/."
}

certs() {
  if [ ! -f "$CERTS/root-ca.pem" ]; then
    echo "Generating Wazuh certificates (first run only)..."
    mkdir -p "$CERTS"
    docker run --rm --entrypoint sh -v "$PWD/$CERTS:/certificates" -v "$PWD/wazuh/gen-certs.sh:/gen-certs.sh:ro" \
      wazuh/wazuh-certs-generator:0.0.5 /gen-certs.sh
  fi
}

case "${1:-}" in
  up)
    check_ports $ALL_PORTS
    certs
    docker compose up -d || { echo; echo "--- vault-init log ---"; docker compose logs --tail 25 vault-init; exit 1; }
    echo "Waiting for Vault init/unseal..."
    docker compose wait vault-init >/dev/null 2>&1 || true
    docker compose logs vault-init | tail -8
    import_dashboards
    urls ;;
  core)
    check_ports $CORE_PORTS
    docker compose up -d $CORE || { echo; echo "--- vault-init log ---"; docker compose logs --tail 25 vault-init; exit 1; }
    docker compose wait vault-init >/dev/null 2>&1 || true
    docker compose logs vault-init | tail -8
    urls ;;
  status)
    docker compose ps --format "table {{.Service}}\t{{.State}}\t{{.Status}}"
    echo
    docker compose exec -e VAULT_TOKEN="$(root_token)" vault-1 vault operator raft list-peers || true
    echo; versions
    urls ;;
  dashboards)
    import_dashboards ;;
  incident)
    if [ "${2:-}" = "b" ]; then
      $MC run --rm --no-deps -e TARGET=vaultb-1 -e SECRETS_DIR=/secrets/cloud-b vaultb-init /scripts/incident.sh
    else
      docker compose run --rm --no-deps vault-init /scripts/incident.sh
    fi ;;
  multicloud)
    multicloud "${2:-}" ;;
  tf)
    shift; tf "$@" ;;
  secrets-check)
    secrets_check ;;
  oidc)
    shift; oidc "$@" ;;
  iac)
    shift; iac "$@" ;;
  unseal)
    docker compose up -d --force-recreate vault-init
    docker compose wait vault-init >/dev/null 2>&1 || true
    docker compose logs vault-init | tail -8 ;;
  token)
    if [ "${2:-}" = "b" ]; then root_token_b; else root_token; fi ;;
  versions)
    versions ;;
  snapshot)
    snapshot ;;
  upgrade)
    upgrade "${2:-}" ;;
  down)
    $MC down ;;
  reset)
    read -r -p "Delete all lab data, secrets and Wazuh certs? [y/N] " a
    [ "$a" = "y" ] || exit 0
    $MC down -v
    rm -f secrets/init.json secrets/loadgen-token secrets/.seeded
    rm -rf secrets/cloud-b
    echo '[]' > prometheus/targets/cloud-b.json
    for d in multicloud state-secrets adopt lab; do
      rm -rf terraform/$d/.terraform terraform/$d/terraform.tfstate* terraform/$d/generated-*.tf
    done
    rm -rf terraform/adopt/[0-9]-*.tf terraform/adopt/policies.tf terraform/adopt/policies
    rm -rf "$CERTS" ;;
  *)
    sed -n '2,21p' "$0" ;;
esac
