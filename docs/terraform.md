# Terraform and Vault: identity, secrets in state, adopting existing config

[Back to README](../README.md) · [Multi-cloud](multicloud.md) · [OIDC](oidc.md) · [Access](access.md) · [Exercises](exercises.md) · [Troubleshooting](troubleshooting.md)

Three things go wrong often when Terraform manages Vault: Terraform runs with the root token, secrets end up in the state file in plain text, and teams with an existing cluster cannot see how to bring it under code without breaking it. The lab has one piece for each.

| Piece | Where | Command |
|---|---|---|
| A least-privilege identity for Terraform | `terraform/terraform-policy.hcl` | used by every `./lab.sh tf` run |
| Secrets in state, side by side with the fix | `terraform/state-secrets/` | `./lab.sh tf state-secrets apply`, `./lab.sh secrets-check` |
| Adopting hand-made config in stages | `terraform/adopt/` | `./lab.sh tf adopt plan -generate-config-out=...` |

Terraform 1.11 or newer and the Vault provider 5.x are needed for the second and third pieces. `./lab.sh tf` uses a local `terraform` if there is one, otherwise the `hashicorp/terraform:1.17` image.

## 1. Terraform does not run as root

Each `./lab.sh tf` run uses the root token once, as a bootstrap credential, to write the `terraform` policy and create a token with it:

```bash
vault policy write terraform terraform/terraform-policy.hcl
vault token create -policy=terraform -ttl=30m -display-name=terraform
```

Terraform gets that 30-minute token and nothing else. The policy allows what the lab's Terraform code manages and no more:

- the mounts and auth methods Terraform owns (`platform/`, `tfdemo/`, `approle-platform/`, `approle-tfdemo/`, plus `noisy/` and `userpass/` for the adopt exercise), not `sys/mounts/*`, so it cannot unmount `secret/` by mistake
- ACL policies, quotas, AppRole roles, userpass users
- `platform/` and `tfdemo/` secrets through the KV v2 API paths (`platform/data/*`, `platform/metadata/*`); a policy written for the CLI path `platform/*` would return 403

Checked in the lab with the Terraform token: reading `secret/app/config`, `vault secrets disable secret`, `vault audit list` and `vault operator raft list-peers` all return 403. Destroying and re-creating the whole baseline on cloud-b works.

The provider block keeps `skip_child_token = true`. By default the provider asks Vault for a child token at the start of every run, which needs `auth/token/create`; with this setting it uses the supplied token as it is, so the token's own 30-minute TTL is the limit.

A side effect worth knowing: the SIEM used to show every Terraform run as root token use (rule 100130). Now Terraform's requests appear under the `terraform` display name, and root use stands out again.

In production the bootstrap step happens once, and Terraform logs in with its own auth method instead of receiving a token: JWT from the CI system (GitHub Actions OIDC, GitLab, Jenkins with a plugin) or AppRole with a wrapped SecretID. The policy stays the same; only the way Terraform gets its token changes.

## 2. Secrets in state

Everything a Terraform resource or data source knows ends up in `terraform.tfstate`. Marking a variable or output `sensitive` hides it from the screen and nothing else. Two Terraform features fix this:

- ephemeral resources (Terraform 1.10): read a value during plan and apply, never save it
- write-only arguments (Terraform 1.11): send a value to the provider, never save it; a companion `*_wo_version` argument tells Terraform when to send it again

`terraform/state-secrets/` does three jobs twice, once the classic way and once with these features:

| Job | Classic | Without state |
|---|---|---|
| Write a secret into Vault | `vault_kv_secret_v2` with `data_json` | `data_json_wo` + `data_json_wo_version` |
| Read a secret and pass it to another resource | `data "vault_kv_secret_v2"` | `ephemeral "vault_kv_secret_v2"` into a write-only argument |
| Issue a machine credential | `vault_approle_auth_backend_role_secret_id` resource | `ephemeral "vault_approle_auth_backend_role_secret_id"` |

Run it and check the state:

```bash
./lab.sh tf state-secrets apply
./lab.sh secrets-check
```

```
  IN STATE  data.vault_kv_secret_v2.read_classic
  clean     vault_approle_auth_backend_role.ci
  clean     vault_auth_backend.approle
  clean     vault_kv_secret_v2.ci_credentials
  clean     vault_kv_secret_v2.consumer
  IN STATE  vault_kv_secret_v2.consumer_classic
  IN STATE  vault_kv_secret_v2.write_classic
  clean     vault_kv_secret_v2.write_only
  clean     vault_mount.tfdemo
Plain-text copies in the file: 4
```

All six secrets are in Vault, with the same values either way (`vault kv get tfdemo/app/db`, `tfdemo/downstream/ephemeral`, `tfdemo/ci/approle`). Only the classic resources left a copy in the state file. The generated AppRole SecretID is not in the state at all.

The core of the pattern:

```hcl
ephemeral "vault_kv_secret_v2" "read" {
  mount    = vault_mount.tfdemo.path
  name     = vault_kv_secret_v2.write_only.name
  mount_id = vault_mount.tfdemo.id   # see "first apply" below
}

resource "vault_kv_secret_v2" "consumer" {   # stands in for aws_db_instance.password_wo and similar
  mount                = vault_mount.tfdemo.path
  name                 = "downstream/ephemeral"
  data_json_wo         = jsonencode({ db_password = ephemeral.vault_kv_secret_v2.read.data["password"] })
  data_json_wo_version = var.secret_version
}
```

What we learned running it:

- Terraform refuses an ephemeral value in a normal argument. Putting `ephemeral.vault_kv_secret_v2.read.data["password"]` into `data_json` fails `terraform validate` with "Invalid use of ephemeral value". That is the safety net.
- Variables can be ephemeral too (`ephemeral = true`). The token and the demo password in this folder are, so they stay out of the plan file as well as the state.
- First apply: ephemeral resources are opened during plan. On the first run the secret and the AppRole role do not exist yet, so the read fails with 404. `depends_on` does not help. The provider's `mount_id` argument does: set it to the mount's id, which is unknown until the mount exists, and the provider waits for apply.
- Rotation: Terraform cannot see a write-only value, so it cannot tell when it changed. `./lab.sh tf state-secrets apply -var secret_version=2` sends the values again, with an in-place update.
- The provider marks `data "vault_kv_secret_v2"` deprecated in favour of the ephemeral resource. The warnings on plan are expected in this demo.
- Every plan and apply opens the ephemeral SecretID again, which issues a new SecretID. Keep `secret_id_ttl` short so the old ones expire.

When the target resource has no write-only argument yet, the secret will be in state. Then treat the state backend as a secret store (encrypted remote backend, access limited to people who may read the secret, versioning and access logs on the bucket) and prefer dynamic secrets, which expire even if a copy leaks.

## 3. Adopting configuration that already exists

Most teams do not start with Terraform. They have a cluster configured by hand and want it under code without recreating anything. In the lab, `vault/scripts/init.sh` plays the hand-made part: it created the `app` and `loadgen` policies, the `noisy/` mount, userpass with three users, and a rate limit quota. `terraform/adopt/` brings them under Terraform in five stages, lowest risk first:

| Stage | File | What | Risk |
|---|---|---|---|
| 1 | `stages/1-policies.tf` | policies `app`, `loadgen` | none: a policy does nothing until something references it |
| 2 | `stages/2-mounts.tf` | `noisy/` mount settings, not its secrets | low |
| 3 | `stages/3-auth.tf` | userpass auth method | highest: a wrong setting breaks every login through it |
| 4 | `stages/4-users.tf` | users alice, bob, carol | low, but see the passwords below |
| 5 | `stages/5-quotas.tf` | `noisy` rate limit quota, global quota settings | low |

Each stage file holds only `import` blocks. The loop for every stage:

```bash
cp terraform/adopt/stages/1-policies.tf terraform/adopt/
./lab.sh tf adopt plan -generate-config-out=generated-1.tf   # Terraform writes the resource blocks
# review and tidy terraform/adopt/generated-1.tf
./lab.sh tf adopt plan      # expect: N to import, 0 to add, 0 to change, 0 to destroy
./lab.sh tf adopt apply
./lab.sh tf adopt plan -detailed-exitcode   # exit 0: code and Vault agree
```

If a plan shows anything other than imports, stop and find out why before applying. Rollback for any resource is `./lab.sh tf adopt state rm <address>`: Terraform forgets it and Vault keeps it.

What happened when we ran all five stages:

- Stage 1. The generated policies are one-line strings full of `\n`. Export the text instead and point the resources at files, so policy changes are readable in code review:

  ```bash
  mkdir -p terraform/adopt/policies
  for p in app loadgen; do vault policy read $p > terraform/adopt/policies/$p.hcl; done
  ```

  ```hcl
  resource "vault_policy" "app" {
    name   = "app"
    policy = file("${path.module}/policies/app.hcl")
  }
  ```

  The plan still showed only imports, which proves the files match Vault exactly.
- Stage 2 imported cleanly as generated.
- Stage 3. Terraform writes `generated-3.tf`, but it does not pass validation: the `tune` block has `listing_visibility = ""`, which the provider rejects (it accepts only `unauth` or `hidden`). Deleting the whole `tune` block fixed it and the plan showed only the import. Generated config is a first draft, not something to apply blind.
- Stage 4. Terraform writes `generated-4.tf`, then the plan fails with "Invalid Attribute Combination": the provider requires a password for every userpass user, and Vault never returns the current one. `stages/4-users.tf` declares an ephemeral variable with the lab passwords (they are in the README). In each user block of `generated-4.tf`, delete the two `password_hash_wo` lines and set:

  ```hcl
  password_wo         = var.userpass_passwords["alice"]   # bob, carol likewise
  password_wo_version = 1
  ```

  The plan is then 3 imports and 3 in-place changes, because the first apply writes the passwords again. In the lab that changes nothing (logins still work, and `grep alice-pass terraform.tfstate` finds nothing). On a real cluster it is a planned password reset, with the users told first. It is the one expected exception to "only imports".
- Stage 5 imported cleanly, including `enable_rate_limit_audit_logging = true`, which the SIEM rules depend on. Now a change to it shows up in `plan`.
- Drift test: `vault write auth/userpass/users/bob token_policies=app,default` by hand, then `plan` showed exactly that difference on `vault_userpass_auth_backend_user.bob`, and `apply` put it back.

After stage 5, `./lab.sh tf adopt plan -detailed-exitcode` returns 0: everything init.sh created by hand is now in code, and nothing in Vault was recreated. Do not run `./lab.sh tf adopt destroy`: it would delete the userpass users and policies the lab depends on.

Stage copies, generated files and exported policies are git-ignored, and `./lab.sh reset` removes them, so the exercise can be repeated.

## Rules worth keeping

- Terraform state describes access rules, not credentials. Losing it should mean re-importing config, not rotating secrets.
- The identity that runs Terraform needs to manage configuration, not read application secrets.
- `sensitive` is a display setting. Ephemeral resources and write-only arguments are what keep values out of state.
- Adopt in stages, lowest risk first, and apply only when the plan says import.
- A scheduled `terraform plan -detailed-exitcode` is the drift alarm: exit code 2 means someone changed Vault by hand.

## Sources

- [Ephemeral values in Terraform](https://developer.hashicorp.com/terraform/language/manage-sensitive-data/ephemeral) and [write-only arguments](https://developer.hashicorp.com/terraform/language/manage-sensitive-data/write-only)
- [Vault provider: ephemeral `vault_kv_secret_v2`](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/ephemeral-resources/kv_secret_v2)
- [Import blocks and `-generate-config-out`](https://developer.hashicorp.com/terraform/language/import/generating-configuration)
- Kuryzhev, [Terraform Vault secrets: keep them out of state and git](https://kuryzhev.cloud/2026/10/17/terraform-vault-secrets-keep-them-out-of-state-and-git)
- Woitzik, [Vault config to Terraform: a staged migration](https://woitzik.dev/blog/vault-terraform-config-staged-migration/)
