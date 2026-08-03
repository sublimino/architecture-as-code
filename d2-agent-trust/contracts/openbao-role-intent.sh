#!/usr/bin/env sh
# Canonical lifecycle intent. The local demo applies an equivalent policy and
# roles through its existing authenticated inf-bao administration path.
set -eu
bao policy write agent-trust-acme-payments - <<'EOF'
path "kv/data/signalloom/agent-trust/acme/payments/*" { capabilities = ["read"] }
EOF
for agent in planner triage; do
  bao write "auth/jwt/role/agent-trust-${agent}" role_type=jwt \
    bound_audiences=openbao-supercredential \
    bound_subject="spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/${agent}" \
    user_claim=sub policies=agent-trust-acme-payments token_ttl=5m token_max_ttl=5m \
    token_period=0 token_type=batch
done
