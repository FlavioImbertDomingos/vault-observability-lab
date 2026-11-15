#!/usr/bin/env bash
# Vault observability lab helper.
#   ./lab.sh up         start everything (generates Wazuh certs on first run)
#   ./lab.sh core       start only Vault + Prometheus + Grafana (no Wazuh, ~1 GB RAM)
#   ./lab.sh status     containers, Raft peers, URLs
#   ./lab.sh incident   simulate suspicious activity for the SIEM
#   ./lab.sh dashboards (re)import the "Vault SIEM" dashboard into Wazuh
#   ./lab.sh unseal     re-run init/unseal (after a restart of the Vault containers)
#   ./lab.sh token      print the root token
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
    urls ;;
  dashboards)
    import_dashboards ;;
  incident)
    docker compose run --rm --no-deps vault-init /scripts/incident.sh ;;
  unseal)
    docker compose up -d --force-recreate vault-init
    docker compose wait vault-init >/dev/null 2>&1 || true
    docker compose logs vault-init | tail -8 ;;
  token)
    root_token ;;
  down)
    docker compose down ;;
  reset)
    read -r -p "Delete all lab data, secrets and Wazuh certs? [y/N] " a
    [ "$a" = "y" ] || exit 0
    docker compose down -v
    rm -f secrets/init.json secrets/loadgen-token secrets/.seeded
    rm -rf "$CERTS" ;;
  *)
    sed -n '2,12p' "$0" ;;
esac
