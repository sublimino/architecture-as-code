#!/usr/bin/env bash
# Trust revocation walkthrough: push an unsigned update of the frontend
# component, watch Flux refuse to reconcile it (verification fails closed,
# the running workload stays on the last good state), then restore trust by
# signing a fixed artifact and watch it promote.
set -euo pipefail

cd "$(dirname "$0")/.."

REGISTRY="${REGISTRY:-localhost:5001/acme}"
COSIGN_KEY="${COSIGN_KEY:-.keys/cosign.key}"

kubectl -n registry port-forward svc/zot 5001:5000 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
trap 'kill ${PORT_FORWARD_PID} 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do
  curl -fsS "http://localhost:5001/v2/" >/dev/null 2>&1 && break
  sleep 0.5
done

reconcile_frontend() {
  kubectl annotate --overwrite -n frontend ocirepository/apps \
    reconcile.fluxcd.io/requestedAt="$(date +%s)" >/dev/null
  sleep 10
  kubectl -n frontend get ocirepository apps \
    -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{" "}{.message}{end}'
  echo
}

echo "=== step 1: revoke trust (push an UNSIGNED frontend artifact)"
flux push artifact "oci://${REGISTRY}/apps/frontend:latest" \
  --path=d2-osramp-apps/components/frontend \
  --source=local --revision="revoked@sha1:0000000000000000000000000000000000000000" \
  --insecure-registry >/dev/null
echo "unsigned artifact pushed; asking Flux to reconcile"
reconcile_frontend
if kubectl -n frontend get ocirepository apps \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q False; then
  echo "BLOCKED: Flux rejected the unsigned artifact; the workload stays on the last verified state"
else
  echo "unexpected: unsigned artifact was accepted"
  exit 1
fi

echo
echo "=== step 2: restore trust (push and SIGN a fixed artifact)"
digest=$(flux push artifact "oci://${REGISTRY}/apps/frontend:latest" \
  --path=d2-osramp-apps/components/frontend \
  --source=local --revision="restored@sha1:$(git rev-parse HEAD 2>/dev/null || echo 1111111111111111111111111111111111111111)" \
  --insecure-registry --output json | jq -r '.digest')
SIGNING_CONFIG="${SIGNING_CONFIG:-${COSIGN_KEY%/*}/signing-config.json}"
[ -f "${SIGNING_CONFIG}" ] || cosign signing-config create \
  --no-default-rekor --no-default-fulcio --no-default-oidc --no-default-tsa \
  --out "${SIGNING_CONFIG}" >/dev/null 2>&1
COSIGN_PASSWORD="" cosign sign --yes --key "${COSIGN_KEY}" \
  --signing-config "${SIGNING_CONFIG}" --allow-insecure-registry \
  "${REGISTRY}/apps/frontend@${digest}"
echo "signed artifact pushed; asking Flux to reconcile"
reconcile_frontend
if kubectl -n frontend get ocirepository apps \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True; then
  echo "RESTORED: signed artifact verified and reconciled to the cluster"
else
  echo "artifact still not verified; inspect: kubectl -n frontend describe ocirepository apps"
  exit 1
fi

echo
echo "revocation walkthrough complete: unsigned blocked, signed promoted"
