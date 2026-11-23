# terraform/lab is changed only through pull requests. The GitHub Actions pipeline
# (.github/workflows/vault-iac.yml) plans every pull request, waits for approval,
# then applies on main. See docs/iac.md.
terraform {
  required_version = ">= 1.11"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.13"
    }
  }

  # State in the lab's Postgres container, with locking. The connection string comes
  # from PG_CONN_STR (set on the runner, and by ./lab.sh tf lab on this machine).
  backend "pg" {}
}

# Address and token come from VAULT_ADDR and VAULT_TOKEN. In the pipeline the token
# is a 15-minute token from the job's GitHub OIDC login, never a stored secret.
provider "vault" {
  skip_child_token = true
}
