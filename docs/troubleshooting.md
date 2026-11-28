# Troubleshooting

[Back to README](../README.md) · [Containers](containers.md) · [Multi-cloud](multicloud.md) · [Terraform](terraform.md) · [IaC pipeline](iac.md) · [OIDC](oidc.md) · [Access](access.md)

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
| OIDC: the browser cannot open `http://keycloak:8180` | Add `127.0.0.1 keycloak` to `/etc/hosts`. The name must be the same for the browser and the Vault containers (see [oidc.md](oidc.md#why-the-etchosts-line)). |
| OIDC: Keycloak says "Invalid parameter: redirect_uri" | The callback URL is not in the Keycloak client. If you changed `VAULT_PORT`, run `./lab.sh oidc down` and `up` so the realm is imported with the new ports. |
| OIDC: `"groups" claim not found in token` | The user is in no Keycloak group, so Keycloak leaves the claim out. Add the user to `vault-admins` or `vault-readers`. |
| OIDC: an issuer mismatch or discovery error when Vault validates the token | `oidc_discovery_url` and the URL Keycloak puts in tokens differ. Keycloak is started with `--hostname=http://keycloak:<port>`; keep `KEYCLOAK_PORT` the same for both. |
| Wazuh shows `permission denied` from the same IP every few seconds | Find the container behind the IP and check the loadgen token: [containers.md](containers.md#example-permission-denied-on-authtokencreate-every-few-seconds). |
| Docker Hub `429 Too Many Requests` | `docker login`, then try again. |
| Permission denied running `./lab.sh` | `chmod +x lab.sh vault/scripts/*.sh wazuh/gen-certs.sh` |
| Start over | `./lab.sh reset` deletes all data, secrets and certificates. |
