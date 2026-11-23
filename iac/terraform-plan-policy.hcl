# Policy for terraform plan (pull requests, the plan before an apply, the nightly
# drift check, and people running ./lab.sh tf lab plan). Read and list only:
# a plan can see the configuration but cannot change it. Only the pipeline's apply
# job, after approval, gets the "terraform" policy.

path "auth/token/lookup-self" { capabilities = ["read"] }

path "sys/mounts"         { capabilities = ["read"] }
path "sys/mounts/team-*"  { capabilities = ["read"] }
path "sys/auth"           { capabilities = ["read"] }
path "sys/mounts/auth/*"  { capabilities = ["read"] }

path "sys/policy"         { capabilities = ["read", "list"] }
path "sys/policy/*"       { capabilities = ["read"] }
path "sys/policies/acl"   { capabilities = ["list"] }
path "sys/policies/acl/*" { capabilities = ["read"] }

path "auth/approle-teams/role"   { capabilities = ["list"] }
path "auth/approle-teams/role/*" { capabilities = ["read"] }
