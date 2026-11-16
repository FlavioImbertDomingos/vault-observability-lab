# Exercises

[Back to README](../README.md) · [Access](access.md) · [Architecture](architecture.md) · [Metrics](metrics.md) · [SIEM](siem.md)

Each exercise lists what to run and what you should see. Most map to Vault Operations Advanced objectives: monitoring (2), fault tolerance (4), performance (6), access control (7).

Set this once in your shell:

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=$(./lab.sh token)
```

## 1. Failover

```bash
docker compose stop vault-1
```

- Grafana: "Active node" moves to vault-2 or vault-3. "Fault tolerance" drops to 0.
- Prometheus: `VaultNodeDown` and `VaultRaftFailureToleranceZero` fire after their `for` period.
- Wazuh: 100206 (election started) and 100204 (node became active).

Bring it back: `docker compose start vault-1 && ./lab.sh unseal`.

## 2. Incident response

```bash
./lab.sh incident
```

Find each step in Wazuh > Dashboards > Vault SIEM: the brute force and the lockout, root token use, the new root token, generate-root and rekey, the policy change, the user probing a secret. Which two only the server log caught?

## 3. Rate limits

```bash
docker compose exec -e VAULT_TOKEN=$VAULT_TOKEN vault-1 \
  sh -c 'for i in $(seq 1 30); do vault kv get noisy/item >/dev/null 2>&1 & done; wait'
```

Compare "Rate limit quota violations" in Grafana with rule 100125 in Wazuh. Then turn off `enable_rate_limit_audit_logging` and repeat: the metric still moves, the SIEM goes quiet.

## 4. Lease growth

```bash
for i in $(seq 1 2000); do vault token create -ttl=1h -policy=default -field=token >/dev/null; done
```

Watch "Active leases", "Tokens by policy" and memory. Clean up with `vault token revoke -mode=path auth/token/create`. Then repeat with `-type=batch` and see that leases do not grow.

## 5. Raft and quorum

```bash
docker compose exec -e VAULT_TOKEN=$VAULT_TOKEN vault-1 vault operator raft list-peers
docker compose exec -e VAULT_TOKEN=$VAULT_TOKEN vault-1 vault operator raft autopilot state
docker compose exec -e VAULT_TOKEN=$VAULT_TOKEN vault-1 vault operator raft snapshot save /vault/file/lab.snap
```

Stop two nodes. The last one cannot elect itself leader, requests fail, and "Leader last contact" stops. Start them again and unseal.

## 6. Search the audit log for a token

Audit entries store tokens as HMACs. Compute the HMAC of a known value and search for it:

```bash
vault write sys/audit-hash/file input="$VAULT_TOKEN"
```

Search the returned `hmac-sha256:...` value in Wazuh (`data.auth.client_token`).

## 7. Planned leader change

```bash
docker compose exec -e VAULT_TOKEN=$VAULT_TOKEN vault-1 vault operator step-down
```

A graceful version of exercise 1. The active node gives up leadership without stopping. Grafana shows the new active node; Wazuh raises 100208 (active node stepped down) and 100204 (node became active). The step-down request is in the audit log as a request line only, which is why the rule reads the server log. This is the step you run on the active node last during a rolling upgrade.

## 8. Rolling upgrade

```bash
./lab.sh versions
./lab.sh upgrade 1.20.4
```

Watch Grafana while it runs: the active node moves once, applied index on the restarted node catches up, fault tolerance stays at 1 between nodes. In Wazuh you will see 100203 (sealed) for each restart, 100208 and 100204 for the leader change. Then repeat with the Ansible playbook (`ansible/vault-rolling-upgrade`, `inventory.lab.ini`) to the next version. See [upgrades.md](upgrades.md).

## 9. Write your own detection

Add a rule that alerts when someone reads `secret/data/admin/break-glass` successfully, test it with `wazuh-logtest`, restart the manager and trigger it with the root token.
