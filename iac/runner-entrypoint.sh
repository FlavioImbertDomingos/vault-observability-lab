#!/bin/bash
# Self-hosted GitHub Actions runner for the lab. It runs on the lab's Docker network,
# so jobs reach vault-1 and the Terraform state database by name. It connects out to
# GitHub; nothing on this machine is exposed. Registration happens once, with a
# one-hour token from GitHub; the result is kept in the gh-runner volume.
set -euo pipefail
cd /home/runner

# Environment for every job (the runner reads .env next to run.sh)
cat > .env <<ENV
VAULT_ADDR=${VAULT_ADDR}
PG_CONN_STR=${PG_CONN_STR}
ENV

if [ ! -f .runner ]; then
  if [ -z "${RUNNER_TOKEN:-}" ]; then
    echo "Runner not registered yet. Run: ./lab.sh iac runner <registration-token>" >&2
    exit 1
  fi
  ./config.sh --url "https://github.com/${GITHUB_REPO}" --token "${RUNNER_TOKEN}" \
    --name "${RUNNER_NAME:-vault-lab}" --labels vault-lab --work _work \
    --unattended --replace
fi
exec ./run.sh
