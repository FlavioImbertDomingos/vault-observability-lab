# Troubleshooting

[Back to README](../README.md)

| Symptom | Fix |
|---|---|
| `Bind for 0.0.0.0:8200 failed: port is already allocated` | Something else holds the port. `lsof -nP -iTCP:8200 -sTCP:LISTEN` and `docker ps --filter publish=8200` show what. Stop it, or set `VAULT_PORT=18200` in `.env`. `lab.sh` checks ports before starting. |
| `service "vault-init" didn't complete successfully` | `lab.sh` prints the last lines of its log. After an earlier failed start, `docker compose down && ./lab.sh up` recreates the containers and keeps data. |
| Vault is sealed after a reboot | `./lab.sh unseal` (or `./lab.sh up`). |
| Wazuh page "refused to connect" | Use `https://`, accept the self-signed certificate, and give the dashboard a few minutes on the first run. `./lab.sh status` shows the port. |
| Vault SIEM dashboard missing | `./lab.sh dashboards` |
| Wazuh indexer keeps restarting | Give Docker at least 6 GB of memory. On Linux: `sudo sysctl -w vm.max_map_count=262144`. |
| Grafana tiles show "No data" | Usage gauges appear after a minute or two; quota and lockout series only after the first event. |
| Docker Hub `429 Too Many Requests` | `docker login`, then try again. |
| Permission denied running `./lab.sh` | `chmod +x lab.sh vault/scripts/*.sh wazuh/gen-certs.sh` |
| Start over | `./lab.sh reset` deletes all data, secrets and certificates. |
