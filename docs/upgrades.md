# Rolling upgrades without Enterprise

[Back to README](../README.md) · [Multi-cloud](multicloud.md) · [Access](access.md) · [Architecture](architecture.md) · [Exercises](exercises.md) · [Ansible playbook](../ansible/vault-rolling-upgrade/README.md)

Vault Enterprise can upgrade a cluster by itself (autopilot automated upgrades) and can lean on a DR or performance replica while the primary is being worked on. Vault Community Edition has neither, but a Raft cluster of three or more nodes can still be upgraded with no data loss and only seconds of interruption, by hand or with a script. This page covers why it works, the procedure, what we measured in the lab, rollback, and what Enterprise adds.

## Why it works

- Raft needs a majority of voters (2 of 3) to accept writes. Restarting one node at a time never breaks that majority.
- Standbys in Community Edition forward every request to the active node, so restarting a standby only affects clients that talk to that node directly.
- Leadership can be moved on purpose with `vault operator step-down`, so the active node is never killed while it holds the lock.
- A Raft snapshot taken first is a complete copy of the data, which is the only rollback path: Vault does not support downgrading once a newer version has written to storage.

## The procedure

1. Read the upgrade notes for every version you cross. Go one minor version at a time (1.19 to 1.20 to 1.21), not straight across several.
2. Check the cluster: all nodes unsealed, `vault operator raft autopilot state` healthy, failure tolerance 1.
3. Take a snapshot and copy it off the cluster: `vault operator raft snapshot save pre-upgrade.snap`.
4. Upgrade one standby: install the new binary or image, restart, unseal, and wait until autopilot reports the node healthy on the new version (its last index has caught up with the leader).
5. Repeat for the other standby.
6. Step down the active node: `vault operator step-down`. An upgraded node becomes active within seconds.
7. Upgrade the former active node the same way.
8. Verify: every node reports the new version (`vault status`), `vault operator raft list-peers` shows three voters, autopilot is healthy.

Mixed versions are expected during steps 4 to 7 and are supported for the duration of an upgrade. Do not leave a cluster mixed.

## In the lab: `./lab.sh upgrade`

```bash
./lab.sh versions             # version and role of each node
./lab.sh upgrade 1.20.4       # rolling upgrade to 1.20.4
./lab.sh snapshot             # snapshot on its own
```

`./lab.sh upgrade` follows the procedure above:

- pulls the image first, so no node is down while Docker downloads
- refuses to start unless autopilot is healthy with failure tolerance of at least 1
- saves a snapshot to `backups/`
- upgrades standbys one at a time; each node gets its own image through `VAULT1_VERSION`, `VAULT2_VERSION`, `VAULT3_VERSION` in `.env`
- unseals each restarted node and waits until autopilot reports it healthy on the new version
- steps down the active node when it is the only one left, then upgrades it
- records `VAULT_VERSION` in `.env` so later `./lab.sh up` runs keep the new version
- can be run again after a failure: nodes already on the target version are skipped

Example run (1.20.4 to 1.21.4, 66 seconds):

```
Before:
  vault-1  1.20.4   active
  vault-2  1.20.4   standby
  vault-3  1.20.4   standby
1. Pre-checks and snapshot
  snapshot: backups/pre-upgrade-20261114-211338.snap (750987 bytes)
2. Upgrade standbys one at a time, the active node last
- vault-2: 1.20.4 -> 1.21.4
  vault-2 is 1.21.4, unsealed, healthy in autopilot
- vault-3: 1.20.4 -> 1.21.4
  vault-3 is 1.21.4, unsealed, healthy in autopilot
- vault-1 is active and still on 1.20.4: stepping it down
  new active node: vault-2 (1.21.4)
- vault-1: 1.20.4 -> 1.21.4
  vault-1 is 1.21.4, unsealed, healthy in autopilot
Done. After:
  vault-1  1.21.4   standby
  vault-2  1.21.4   active
  vault-3  1.21.4   standby
```

Watch it in Grafana (active node, Raft applied index, leader last contact) and in Wazuh (100204 node became active, 100208 node stepped down, 100203 node sealed during each restart).

## What we measured

During that upgrade a probe container read a KV secret from each node in turn, twice a second, with client retries turned off (`VAULT_MAX_RETRIES=0`, 3 second timeout):

| Node | Failed reads | Window | Why |
|---|---|---|---|
| vault-2 (standby, restarted first) | 5 | 3 s | Process restarting, then sealed until unsealed |
| vault-3 (standby) | 6 | 3 s | Same |
| vault-1 (former active, restarted last) | 19 | 13 s | Restart after step-down, then sealed until unsealed |
| Any other node while one was restarting | 0 | | Requests to healthy nodes kept working |
| Any node during the step-down | 0 | | Leadership moved without a failed read |

246 reads succeeded and 30 failed, and every failure was a request sent directly to the node being restarted. With a load balancer that health-checks `/v1/sys/health` and stops sending traffic to a restarting node, clients would not have seen those failures. With the default client retries (2), most of them would also have succeeded on retry. No data was lost: the secrets and the Raft index were intact after each upgrade.

The same procedure took the lab from 1.19.5 to 1.20.4, to 1.21.4, and (with the Ansible playbook) to 2.0.4.

## Making it smooth in production

- Auto-unseal. With Shamir keys, someone has to unseal every restarted node, three times per upgrade, while the cluster runs with reduced fault tolerance. Auto-unseal with a cloud KMS or the transit engine is available in Community Edition and removes this step.
- Load balancer health checks. Send traffic only to nodes that return 200 or 429 from `/v1/sys/health` (or to the active node only, 200), with a check interval of a few seconds. Remove a node from the pool before restarting it if your load balancer supports draining.
- Client retries. Keep `VAULT_MAX_RETRIES` at its default or higher; Vault Agent and the SDKs retry too.
- Five nodes if you need margin. With three voters, an unrelated failure during an upgrade leaves you without quorum. Five voters tolerate one failure while a node is being upgraded.
- Scripted snapshots. Automated snapshots are an Enterprise feature; in Community Edition, schedule `vault operator raft snapshot save`, ship the files to object storage and test a restore regularly.
- A staging cluster on the same version, upgraded first.
- Ansible for real servers. [`ansible/vault-rolling-upgrade`](../ansible/vault-rolling-upgrade/README.md) runs the same steps with `serial: 1` and the same health gates.

## Rollback

There is no downgrade. If the new version misbehaves:

1. Stop all nodes.
2. Reinstall the previous version on every node and clear the Raft data directories.
3. Start the nodes, initialize a new cluster on one of them, and restore the pre-upgrade snapshot with `vault operator raft snapshot restore -force pre-upgrade.snap`.
4. Unseal with the original cluster's unseal keys (or let auto-unseal do it), since the snapshot carries the original keyring.
5. Join the other nodes.

Anything written after the snapshot is lost, which is why the snapshot is taken immediately before the upgrade. This procedure follows the Vault documentation; it was not exercised in the lab.

## Do we need Ansible?

Not for the lab: `./lab.sh upgrade` covers it. For servers or VMs, yes, it is worth it. The procedure has ordering rules and health gates that are easy to get wrong at 2 a.m., and an Ansible playbook with `serial: 1` encodes them once. The playbook in this repository:

- discovers the active node instead of trusting the inventory order
- refuses to start on a sealed node or an unhealthy cluster
- takes the snapshot through the API to the control machine
- installs a pinned version (apt/yum package or checksum-verified binary)
- unseals with Shamir keys only if you pass them, without logging them
- waits for autopilot after each node, steps down the active node, and verifies at the end

It can be practised against this lab (`inventory.lab.ini`) before it touches real servers.

## Community vs. Enterprise for upgrades and resilience

| Capability | Community | Enterprise |
|---|---|---|
| Rolling upgrade of a Raft cluster | Manual or scripted (this page) | Autopilot automated upgrades: new-version nodes join as non-voters and leadership moves when enough are ready |
| Spare nodes per availability zone | No | Redundancy zones with automatic promotion |
| Standbys serving reads | No, they forward to the active node | Performance standbys |
| Second cluster for disaster recovery | Restore a snapshot on a new cluster | DR replication, promote a secondary |
| Active clusters in several regions | No | Performance replication |
| Automated snapshots | Script them | Built in |
| HSM auto-unseal, seal wrap, FIPS builds | No | Yes |
| Namespaces, Sentinel, control groups | No | Yes |
| Support and SLA | Community | HashiCorp support |

For one region with auto-unseal, scripted snapshots and a tested restore, Community Edition upgrades well. A second region, a warm DR site, read scaling, multi-tenancy or an HSM requirement are the points where Enterprise (or HCP Vault Dedicated) becomes necessary.

## Sources

- [Vault upgrade guides](https://developer.hashicorp.com/vault/docs/upgrading)
- [Integrated Storage autopilot](https://developer.hashicorp.com/vault/docs/concepts/integrated-storage/autopilot)
- [`vault operator step-down`](https://developer.hashicorp.com/vault/docs/commands/operator/step-down)
- [`vault operator raft snapshot`](https://developer.hashicorp.com/vault/docs/commands/operator/raft)
