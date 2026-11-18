# Stage 1: policies. Lowest risk: importing changes nothing in Vault, and a
# policy only matters once a role, user or token references it.
# Rollback: terraform state rm vault_policy.app (Vault keeps the policy).

import {
  to = vault_policy.app
  id = "app"
}

import {
  to = vault_policy.loadgen
  id = "loadgen"
}
