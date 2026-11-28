# Containers: what each one does

[Back to README](../README.md) · [Architecture](architecture.md) · [SIEM](siem.md) · [Troubleshooting](troubleshooting.md)

`docker compose ps` or Docker Desktop lists about fifteen containers under the project `vault-lab`. This page explains what each one is for, which of them talk to Vault, and how to find out which container sent the request behind an IP address in a Vault audit log or a Wazuh alert.

## Container index

Started by `./lab.sh up`:

| Container | Image | Host port | What it does |
|---|---|---|---|
| `vault-1`, `vault-2`, `vault-3` | `hashicorp/vault` | 8200, 8210, 8220 | The three-node Vault cluster with Raft storage. One node is active; the standbys forward requests to it. Each node writes `audit.log` and its server log to its own volume (`vault-N-logs`). |
| `vault-init` | `hashicorp/vault` | none | Runs once per start: initializes and unseals the cluster. On the very first run it also creates the policies, userpass users, AppRole, the rate-limit quota and the loadgen token, then writes `secrets/.seeded`. It exits when done, so Docker shows it as stopped. That is normal. |
| `loadgen` | `hashicorp/vault` | none | Sends background traffic so the dashboards have data: logins, AppRole, KV, transit, short-lived tokens, plus some errors on purpose (see below). Script: `vault/scripts/loadgen.sh`. |
| `audit-rotate` | `hashicorp/vault` | none | Every 5 minutes, copies any `audit.log` larger than 200 MB to `audit.log.1` and empties it, so the disk does not fill. It does not talk to Vault. |
| `prometheus` | `prometheus/prometheus` | 9090 | Scrapes `/v1/sys/metrics` on the three nodes. No token is needed because the listener allows unauthenticated metrics in this lab. |
| `grafana` | `grafana/grafana` | 3000 | Dashboards on top of Prometheus. |
| `wazuh-agent-vault-1/2/3` | `wazuh/wazuh-agent` | none | One per Vault node, like an agent installed on each Vault server. Each reads its node's log volume read-only and sends events to the manager. They do not talk to Vault. |
| `wazuh.manager` | `wazuh/wazuh-manager` | 1514, 1515 | Receives agent events (1514; enrollment on 1515), applies the rules in `wazuh/rules/vault_rules.xml` and creates alerts. |
| `wazuh.indexer` | `wazuh/wazuh-indexer` | none | OpenSearch database that stores the alerts. Uses the most memory in the lab. |
| `wazuh.dashboard` | `wazuh/wazuh-dashboard` | 8443 (https) | The Wazuh web UI, including the Vault SIEM dashboard. |

Started by optional profiles:

| Container | Started by | Host port | What it does |
|---|---|---|---|
| `keycloak` | `./lab.sh oidc up` | 8180 | OIDC identity provider for human logins (realm `lab`). See [oidc.md](oidc.md). |
| `vaultb-1/2/3`, `vaultb-init`, `loadgen-b` | `./lab.sh multicloud up` | 8300, 8310, 8320 | A second, independent cluster with its own init and traffic. See [multicloud.md](multicloud.md). |
| `wazuh-agent-vaultb-1/2/3` | `./lab.sh multicloud up` | none | Agents for the second cluster. |
| `tfstate` | `./lab.sh iac up` | 127.0.0.1:5433 | Postgres that holds the Terraform state for `terraform/lab`. |
| `gh-runner` | `./lab.sh iac up` | none | Self-hosted GitHub Actions runner. Its jobs log in to Vault with GitHub OIDC tokens. See [iac.md](iac.md). |

Who sends requests to Vault: `vault-init`, `loadgen` (and `loadgen-b`), `prometheus` (metrics only), `gh-runner` jobs, `keycloak` (never: Vault calls Keycloak, not the other way round), and you, from the CLI, the UI or `./lab.sh`. The Wazuh containers, `grafana`, `audit-rotate` and `tfstate` never call Vault.

## Which container has this IP?

Vault audit entries and Wazuh alerts show the client as `request.remote_address`, for example `172.26.0.14`. Those are addresses on the Compose network `vault-lab_default`. Docker hands them out when containers start, so look them up while the lab is running and do not write them down for later.

All containers on the lab network with their addresses, sorted by IP:

```bash
docker network inspect vault-lab_default \
  --format '{{range .Containers}}{{.Name}}  {{.IPv4Address}}{{"\n"}}{{end}}' | sort -t. -k4 -n
```

Find the container for one address:

```bash
IP=172.26.0.14
docker ps -q | xargs docker inspect \
  --format '{{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' | grep -w "$IP"
```

The address of one container:

```bash
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' vault-lab-loadgen-1
```

Which clients have been calling a node, with request counts:

```bash
docker compose exec vault-1 sh -c \
  'grep -o "\"remote_address\":\"[^\"]*\"" /vault/logs/audit.log | sort | uniq -c | sort -rn'
```

Requests from your own machine (CLI or browser on `localhost:8200`) show the address of Docker's gateway on that network, usually the `.1` address, not your Mac's IP.

## Errors the lab makes on purpose

`loadgen` runs a round every 3 seconds (`LOADGEN_SLEEP`). Some rounds include requests that are meant to fail, so the SIEM has something to detect:

| Event | How often | Wazuh rule |
|---|---|---|
| userpass login as `bob` with a wrong password | Every 60 rounds, about every 3 to 4 minutes | 100110 failed login |
| AppRole token reads `secret/admin/break-glass` (403) | Every 20 rounds | 100120 permission denied |
| 15 parallel reads on the rate-limited `noisy/` mount (429) | Every 120 rounds, about every 10 minutes | 100125 rate limit |

`./lab.sh incident` adds a burst of failed logins for `carol` and other incident activity, only when you run it.

Anything outside this pattern, such as a steady stream of denials every few seconds, is not part of the design and is worth a look.

## Example: `permission denied` on `auth/token/create` every few seconds

Seen in the Vault SIEM dashboard: rule 100120, level 5, "permission denied for  on auth/token/create", an empty `auth.display_name`, the same `remote_address` every 2 to 4 seconds.

1. The address belonged to `loadgen` (commands above). It is also the only container that calls `auth/token/create` in a loop.
2. The empty display name means Vault did not recognize the token at all. Reproduced on Vault 1.20.4: a request with an invalid token returns `permission denied` and `invalid token`, and the audit entry has no `auth` block. A valid token with the wrong policy would show `token-loadgen` as the name.
3. Likely cause: `secrets/loadgen-token` is a periodic token with a 24-hour period. `loadgen` renews it every 100 rounds while it runs. If the lab is stopped for more than 24 hours, the token expires. On the next start, `vault-init` sees `secrets/.seeded`, skips seeding and does not issue a new token, so `loadgen` keeps using the dead one.

Check the token:

```bash
docker compose exec loadgen sh -c \
  'VAULT_ADDR=http://vault-1:8200 VAULT_TOKEN=$(cat /secrets/loadgen-token) vault token lookup'
```

If it fails with `bad token` or `permission denied`, issue a new one and restart `loadgen`:

```bash
docker compose exec -T -e VAULT_TOKEN=$(./lab.sh token) vault-1 \
  vault token create -policy=loadgen -policy=app -period=24h -display-name=loadgen -field=token \
  > secrets/loadgen-token
docker compose restart loadgen
```

If the lookup succeeds, the cause is something else: compare the raw audit entry (`docker compose exec vault-1 tail -n 50 /vault/logs/audit.log`) with the request `loadgen.sh` makes.
