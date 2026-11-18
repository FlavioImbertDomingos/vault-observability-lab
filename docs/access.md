# Accessing Vault

[Back to README](../README.md) · [Architecture](architecture.md) · [Upgrades](upgrades.md) · [Multi-cloud](multicloud.md) · [Terraform](terraform.md) · [OIDC](oidc.md) · [Exercises](exercises.md) · [Troubleshooting](troubleshooting.md)

Each node has its own port on your machine, so you can reach any of them directly:

| Node | Address |
|---|---|
| vault-1 | http://localhost:8200 |
| vault-2 | http://localhost:8210 |
| vault-3 | http://localhost:8220 |

Ports can be changed in `.env` (`VAULT_PORT`, `VAULT2_PORT`, `VAULT3_PORT`). Standbys forward requests to the active node, so reads and writes work on any port. `vault status` on a port tells you whether that node is active or standby.

## Credentials

| Who | How to get in | Allowed |
|---|---|---|
| Root | token from `./lab.sh token` | everything (lab only) |
| alice, bob | userpass, passwords `alice-pass`, `bob-pass` | policy `app`: read `secret/app/*`, transit on `payments` |
| carol | userpass, password `carol-pass` | same as alice; target of `./lab.sh incident`, so she is locked out for 15 minutes after it runs |
| olivia, oscar, nora | OIDC through Keycloak, after `./lab.sh oidc up`; passwords `olivia-pass`, `oscar-pass`, `nora-pass` | from their Keycloak group: olivia `secrets-admin`, oscar `app`, nora refused (no group). See [oidc.md](oidc.md) |

## Option 1: Vault CLI on your machine

Install the CLI.

macOS:

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/vault
```

Linux and Windows: see https://developer.hashicorp.com/vault/install.

Point it at the lab, from the repository folder:

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=$(./lab.sh token)

vault status
vault operator raft list-peers
vault operator raft autopilot state
vault kv get -mount=secret app/config
```

Talk to one node:

```bash
VAULT_ADDR=http://localhost:8210 vault status     # vault-2, this command only
export VAULT_ADDR=http://localhost:8220           # vault-3 from now on
```

Log in as a user instead of root, which is closer to how applications and people use Vault:

```bash
unset VAULT_TOKEN                                 # an exported VAULT_TOKEN beats ~/.vault-token
vault login -method=userpass username=alice password=alice-pass
vault kv get -mount=secret app/config             # allowed
vault kv get -mount=secret admin/break-glass      # permission denied, by design
vault token lookup                                # policies, TTL, entity
```

`vault login` saves the token in `~/.vault-token`. A newer CLI than the lab's Vault version is fine for everyday commands.

A shell shortcut (adjust the path):

```bash
alias vlab='export VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=$(~/vault-observability-lab/lab.sh token)'
```

## Option 2: CLI inside a container

Nothing to install. Each Vault container has the CLI, with `VAULT_ADDR` already pointing at itself.

```bash
docker compose exec -e VAULT_TOKEN=$(./lab.sh token) vault-1 vault status
docker compose exec -e VAULT_TOKEN=$(./lab.sh token) vault-2 vault operator raft list-peers

# interactive shell on a node
docker compose exec -e VAULT_TOKEN=$(./lab.sh token) vault-3 sh
```

## Option 3: Web UI

Open http://localhost:8200 (or 8210, 8220).

- Root: Method "Token", paste the output of `./lab.sh token`.
- User: Method "Username", for example alice / alice-pass.
- OIDC (after `./lab.sh oidc up`): Method "OIDC", role empty, "Sign in with OIDC Provider", then olivia / olivia-pass in the Keycloak window.

Logged in as root, "Raft Storage" shows the three peers and their state, and "Secrets Engines" lets you browse `secret/` and `noisy/`.

## Option 4: HTTP API

```bash
curl -s http://localhost:8200/v1/sys/health | jq        # no token needed
curl -s -H "X-Vault-Token: $(./lab.sh token)" \
     http://localhost:8200/v1/secret/data/app/config | jq .data.data
curl -s http://localhost:8210/v1/sys/metrics?format=prometheus | head   # metrics, any node
```

`/v1/sys/health` returns 200 on the active node and 429 on standbys, which is what a load balancer uses to route traffic.

## Useful first commands

| Command | Shows |
|---|---|
| `vault status` | sealed or not, version, HA mode (active or standby) |
| `vault operator raft list-peers` | the three nodes, leader, voters |
| `vault operator raft autopilot state` | health, failure tolerance, version per node |
| `vault audit list -detailed` | the file audit device feeding Wazuh |
| `vault auth list` / `vault secrets list` | mounts seeded by the lab |
| `vault policy read app` | the policy alice and bob get |
| `vault read sys/quotas/rate-limit/noisy` | the rate limit used for the 429 demo |
| `./lab.sh versions` | version and role of each node in one line each |
