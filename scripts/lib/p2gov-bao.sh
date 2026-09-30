#!/usr/bin/env bash
# @id scripts/lib/p2gov-bao.sh
# @target scripts/test-phase2-governor.sh (BAO_BIN for scripts/bootstrap-spire-federation.sh)
#
# SLDC-P2-GOV: run the OpenBao CLI inside the hub fixture's own OpenBao pod
# (2.1.1, the version SLDC-P2-2 was proven against) instead of whatever `bao`
# is on the host PATH. The root token is read from the container's
# BAO_DEV_ROOT_TOKEN_ID (mounted from a Secret) inside the pod, so it is never
# placed on any argv. stdin is forwarded, so `bao write PATH -` works.
set -eo pipefail
exec "${KUBECTL_BIN:-kubectl}" --context "${HUB_CONTEXT:-kind-signalloom-hub}" -n "${P2GOV_HUB_NS:-sldc-p2-gov}" \
  exec -i deploy/openbao -c openbao -- \
  sh -c 'BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$BAO_DEV_ROOT_TOKEN_ID" exec bao "$@"' bao "$@"
