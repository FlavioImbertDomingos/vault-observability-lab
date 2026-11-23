# Each team gets: a KV v2 mount team-<name>/, a read policy and a write policy, and
# an AppRole role for its application. To add a team, add one entry and open a pull
# request. Removing an entry deletes the team's mount and everything stored in it,
# which is why every change waits for approval.

locals {
  teams = {
    payments = {
      description = "Payments service secrets"
      token_ttl   = 3600
    }
    orders = {
      description = "Order management secrets"
      token_ttl   = 1800
    }
  }
}

resource "vault_auth_backend" "approle_teams" {
  type        = "approle"
  path        = "approle-teams"
  description = "Application logins for team mounts (managed by terraform/lab)"
}

module "team" {
  source   = "./modules/team"
  for_each = local.teams

  name          = each.key
  description   = each.value.description
  token_ttl     = each.value.token_ttl
  approle_mount = vault_auth_backend.approle_teams.path
}

output "teams" {
  description = "Mount and AppRole role of each team"
  value = { for k, m in module.team : k => {
    mount        = m.mount
    approle_role = m.approle_role
  } }
}
