# Mutation: make the "a deploy identity is configured for this checkout" half of
# the impersonation guard always false, so the refusal can never fire.
# Expected effect: a mutating target runs as the user identity even though
# deploy/gcp/deploy-sa names a service account and GCP_TF_IMPERSONATE is blank —
# which is the half-applied estate this guard exists to prevent.
s#-n '$(strip $(TF_DEPLOY_SA))'#-n ''#
