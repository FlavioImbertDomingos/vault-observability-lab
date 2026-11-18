# Exercises

[Back to README](../README.md) · [Multi-cloud](multicloud.md) · [Terraform](terraform.md) · [OIDC](oidc.md) · [Access](access.md) · [Architecture](architecture.md) · [Metrics](metrics.md) · [SIEM](siem.md)

Each exercise lists what to run and what you should see. Most map to Vault Operations Advanced objectives: monitoring (2), fault tolerance (4), performance (6), access control (7). Exercises 10 and 11 cover Terraform with Vault, exercise 12 OIDC logins.

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

## 9. Multi-cloud drift

```bash
./lab.sh multicloud up
./lab.sh tf apply
VAULT_ADDR=http://localhost:8300 VAULT_TOKEN=$(./lab.sh token b) vault policy write platform-deployer - <<'EOF'
path "platform/*" { capabilities = ["create", "read", "update", "delete", "list"] }
EOF
./lab.sh tf plan
```

Terraform shows the change on cloud-b only. Find the same change in Wazuh (rule 100142, location `/var/log/vault-b/audit.log`), then `./lab.sh tf apply` to restore it. Open the "Vault multi-cloud" dashboard and compare the two clusters. See [multicloud.md](multicloud.md).

## 10. Keep secrets out of Terraform state

```bash
./lab.sh tf state-secrets apply
./lab.sh secrets-check
grep -c lab-demo-S3cret-4242 terraform/state-secrets/terraform.tfstate
```

Three resources show `IN STATE` (the classic resource, the data source and the resource fed by it) and the ephemeral and write-only ones show `clean`, although Vault holds the same values for both. Then break it on purpose: copy `terraform/state-secrets` to a scratch folder, put `ephemeral.vault_kv_secret_v2.read.data["password"]` into a normal `data_json` argument and run `terraform validate`; it fails with "Invalid use of ephemeral value". Finally rotate: `./lab.sh tf state-secrets apply -var secret_version=2` and read `tfdemo/app/db` again. See [terraform.md](terraform.md#2-secrets-in-state).

## 11. Adopt hand-made config into Terraform

```bash
cp terraform/adopt/stages/1-policies.tf terraform/adopt/
./lab.sh tf adopt plan -generate-config-out=generated-1.tf
./lab.sh tf adopt plan
./lab.sh tf adopt apply
```

Repeat for stages 2 to 5. Apply only when the plan says import. Expect two surprises: the generated userpass config in stage 3 fails validation until you delete its `tune` block, and stage 4 needs each user's `password_wo` set from the variable in `4-users.tf`, after which the plan shows in-place changes because the passwords are written again. At the end, change a user by hand (`vault write auth/userpass/users/bob token_policies=app,default`) and watch `plan` catch it. See [terraform.md](terraform.md#3-adopting-configuration-that-already-exists).

## 12. Log in through an identity provider

```bash
echo '127.0.0.1 keycloak' | sudo tee -a /etc/hosts   # once
./lab.sh oidc up
vault login -method=oidc        # sign in as oscar / oscar-pass
vault kv put secret/team/x a=b  # 403: oscar is in vault-readers
```

Now, in the Keycloak admin console (http://keycloak:8180, admin / admin, realm lab), add oscar to `vault-admins`, log in again and repeat the `kv put`: it works, and nothing changed in Vault. Then log in as nora (no group) and read the refusal. Finally fail six logins in a row and find rules 100112 and 100113 in Wazuh, then use `sys/audit-hash/file` to prove which error message the hashed `response.data.error` holds. See [oidc.md](oidc.md).

## 13. Write your own detection

Add a rule that alerts when someone reads `secret/data/admin/break-glass` successfully, test it with `wazuh-logtest`, restart the manager and trigger it with the root token.
