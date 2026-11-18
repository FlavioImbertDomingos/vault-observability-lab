# Stage 3: the userpass auth method. The riskiest stage: a wrong setting here
# breaks every login that uses it. If the plan shows any change besides the
# import, stop and find out why before applying.

import {
  to = vault_auth_backend.userpass
  id = "userpass"
}
