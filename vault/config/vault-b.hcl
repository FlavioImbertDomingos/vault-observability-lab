# Shared config for the second cluster ("cloud-b"): vaultb-1, vaultb-2, vaultb-3.
# Node-specific values come from environment variables in docker-compose.yml:
#   VAULT_RAFT_NODE_ID, VAULT_API_ADDR, VAULT_CLUSTER_ADDR
# and from vault/nodes/vaultb-N.hcl (log file per node).
# LAB ONLY: TLS is disabled so the stack starts without a PKI. Never do this in production.

ui            = true
disable_mlock = true          # recommended with Integrated Storage
cluster_name  = "vault-lab-b"
log_level     = "info"
log_format    = "json"        # operational logs in JSON, easier to ship to a SIEM

storage "raft" {
  path = "/vault/file"

  retry_join {
    leader_api_addr = "http://vaultb-1:8200"
  }
  retry_join {
    leader_api_addr = "http://vaultb-2:8200"
  }
  retry_join {
    leader_api_addr = "http://vaultb-3:8200"
  }
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = true

  telemetry {
    # lets every node, standbys included, answer /v1/sys/metrics without a token
    unauthenticated_metrics_access = true
  }
}

telemetry {
  prometheus_retention_time = "24h"   # 0 would disable the Prometheus endpoint
  disable_hostname          = true    # metric names without the hostname prefix
  usage_gauge_period        = "1m"    # token/entity/secret counts; default is 10m
}
