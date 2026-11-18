# Stage 4: the users. Their passwords are write-only: Vault never returns them,
# so Terraform adopts each user (policies, TTLs) without ever knowing the password,
# and the password never reaches state. Leave password_wo unset to keep the
# current password; set it with password_wo_version to rotate it.

import {
  to = vault_userpass_auth_backend_user.alice
  id = "auth/userpass/users/alice"
}

import {
  to = vault_userpass_auth_backend_user.bob
  id = "auth/userpass/users/bob"
}

import {
  to = vault_userpass_auth_backend_user.carol
  id = "auth/userpass/users/carol"
}

# The provider requires a password for every user, and Vault never returns the
# current one. So adopting a user means supplying its password: the first apply
# writes it again. In the lab the passwords are known (they are in the README);
# in production this is a planned password reset, done with the users told first.
# The variable is ephemeral, so the passwords stay out of the plan file and state.
variable "userpass_passwords" {
  type      = map(string)
  sensitive = true
  ephemeral = true
  default = {
    alice = "alice-pass"
    bob   = "bob-pass"
    carol = "carol-pass"
  }
}
