# Troubleshooting

[Back to README](../README.md) · [Multi-cloud](multicloud.md) · [Terraform](terraform.md) · [Access](access.md)

| Symptom | Fix |
|---|---|
| `Bind for 0.0.0.0:8200 failed: port is already allocated` | Something else holds the port. `lsof -nP -iTCP:8200 -sTCP:LISTEN` and `docker ps --filter publish=8200` show what. Stop it, or set `VAULT_PORT=18200` in `.env`. `lab.sh` checks ports before starting. |
| `service "vault-init" didn't complete successfully` | `lab.sh` prints the last lines of its log. After an earlier failed start, `docker compose down && ./lab.sh up` recreates the containers and keeps data. |
| Vault is sealed after a reboot | `./lab.sh unseal` (or `./lab.sh up`). |
| Wazuh page "refused to connect" | Use `https://`, accept the self-signed certificate, and give the dashboard a few minutes on the first run. `./lab.sh status` shows the port. |
| Vault SIEM dashboard missing | `./lab.sh dashboards` |
| Wazuh indexer keeps restarting | Give Docker at least 6 GB of memory. On Linux: `sudo sysctl -w vm.max_map_count=262144`. |
| Grafana tiles show "No data" | Usage gauges appear after a minute or two; quota and lockout series only after the first event. |
| Terraform: `permission denied` (403) on a path | Terraform runs with the `terraform` policy, not root. Add the path to `terraform/terraform-policy.hcl`; the next `./lab.sh tf` run writes it. |
| Terraform: `Error generating AppRole SecretID` or 404 reading a secret on the first apply | An ephemeral resource was opened during plan, before what it reads existed. Set its `mount_id` to the mount's id so it waits for apply (see `terraform/state-secrets/main.tf`). |
| `terraform/adopt`: `expected tune.0.listing_visibility to be one of ["unauth" "hidden"]` | Generated config for the userpass mount is invalid. Delete the `tune` block from the generated file. |
| Docker Hub `429 Too Many Requests` | `docker login`, then try again. |
| Permission denied running `./lab.sh` | `chmod +x lab.sh vault/scripts/*.sh wazuh/gen-certs.sh` |
| Start over | `./lab.sh reset` deletes all data, secrets and certificates. |
