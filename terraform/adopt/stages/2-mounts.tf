# Stage 2: the noisy/ KV mount. Only the mount settings (type, version, description)
# come under Terraform. The secrets stored in it stay out of Terraform and out of state.

import {
  to = vault_mount.noisy
  id = "noisy"
}
