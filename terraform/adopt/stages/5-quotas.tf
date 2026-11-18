# Stage 5: the rate limit quota on noisy/ and the global quota settings
# (rate-limit audit logging, which the SIEM rules depend on).

import {
  to = vault_quota_rate_limit.noisy
  id = "noisy"
}

import {
  to = vault_quota_config.global
  id = "sys/quotas/config"
}
