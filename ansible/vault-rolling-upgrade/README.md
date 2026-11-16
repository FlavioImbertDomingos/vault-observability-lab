# Vault rolling upgrade with Ansible (Community Edition, Raft)

Upgrades a 3-node (or larger) Vault cluster on Integrated Storage one node at a time, standbys first and the active node last, without losing quorum. It is the manual procedure in [docs/upgrades.md](../../docs/upgrades.md), automated.

## What it does

1. Reads `/v1/sys/health` on every node: refuses to start if any node is sealed or uninitialized, finds the active node, and skips nodes already on the target version (so a failed run can simply be run again).
2. Checks autopilot on the active node: cluster healthy and failure tolerance of at least 1.
3. Saves a Raft snapshot to `backups/` on the control machine.
4. Upgrades each standby with `serial: 1`: install the pinned version, restart, unseal if Shamir keys are supplied, wait until the node is unsealed on the new version, then wait until autopilot reports it healthy.
5. Steps down the active node, waits until it reports standby, and upgrades it the same way.
6. Verifies every node reports the target version.

## Requirements

- Ansible 2.15 or later on the control machine, with network access to each node's API.
- Vault installed from the HashiCorp apt/yum repository (`vault_install_method: package`) or as a binary in `/usr/local/bin` (`binary`), managed by a systemd unit named `vault`.
- A token with the policy in `upgrade-policy.hcl`, exported as `VAULT_TOKEN`.
- Auto-unseal is strongly recommended. With Shamir, pass the keys at run time (`-e @keys.yml`, encrypted with ansible-vault); they are never logged.

## Run it

```bash
vault policy write vault-upgrade upgrade-policy.hcl
export VAULT_TOKEN=$(vault token create -policy=vault-upgrade -ttl=1h -field=token)

cp inventory.example.ini inventory.ini        # list your three servers
ansible-playbook -i inventory.ini upgrade.yml -e vault_version=1.21.4
```

Settings are in `group_vars/all.yml`: install method, architecture, TLS (`vault_validate_certs`, `vault_ca_path`), port, service name, wait times.

## Practise against the lab

The Docker Compose lab in this repository can stand in for three servers (`vault_install_method: lab`):

```bash
cd ansible/vault-rolling-upgrade
export VAULT_TOKEN=$(../../lab.sh token)
ansible-playbook -i inventory.lab.ini upgrade.yml -e @lab-vars.yml -e vault_version=1.20.4
```

This run was tested end to end: 1.21.4 to 2.0.4 across the three lab nodes in 42 seconds, Shamir unseal included, data intact afterwards.

## Rules the playbook follows

- One node at a time (`serial: 1`), so at most one voter is ever down.
- Standbys before the active node; the active node is stepped down, not killed.
- Never continue while autopilot is unhealthy or failure tolerance is 0.
- Talk to each node directly, not through the load balancer.
- One minor version per run. Read the upgrade notes for every version you cross.
- No downgrades. Rollback means restoring the pre-upgrade snapshot on the old version.

## Fitting it into your own Ansible

If you already have a role that installs and configures Vault (for example a `vault_3_nodes` playbook), keep it for installation and use this playbook only for the ordering and the health gates. The install tasks in `tasks/upgrade_node.yml` are the only part you may want to replace with a call to your role.
