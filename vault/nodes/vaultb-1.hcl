# Node-specific settings for vaultb-1 (mounted as /vault/config/node.hcl).
# Operational log to a file on the shared volume so Wazuh can read it.
log_file             = "/vault/logs/vaultb-1.log"
log_rotate_bytes     = 52428800   # 50 MB
log_rotate_max_files = 3
