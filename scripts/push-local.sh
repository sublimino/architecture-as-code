#!/usr/bin/env bash
# Push the fleet, infra, and apps manifest artifacts to the in-cluster zot
# registry and sign each digest with the local cosign key. Flux inside the
# cluster pulls the same repositories at zot.registry.svc.cluster.local:5000.
set -euo pipefail

cd "$(dirname "$0")/.."

REGISTRY="${REGISTRY:-localhost:5001/acme}"
COSIGN_KEY="${COSIGN_KEY:-.keys/cosign.key}"
REVISION="local@sha1:$(git rev-parse HEAD 2>/dev/null || echo 0000000000000000000000000000000000000000)"

test -f "${COSIGN_KEY}" || { echo "${COSIGN_KEY} not found; run 'make signing-keys' first"; exit 1; }

kubectl -n registry port-forward svc/zot 5001:5000 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
trap 'kill ${PORT_FORWARD_PID} 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  curl -fsS "http://localhost:5001/v2/" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "http://localhost:5001/v2/" >/dev/null

push_and_sign() {
  local repo="$1" path="$2"
  echo "pushing oci://${REGISTRY}/${repo}:latest from ${path}"
  local digest
  digest=$(flux push artifact "oci://${REGISTRY}/${repo}:latest" \
    --path="${path}" \
    --source="local" \
    --revision="${REVISION}" \
    --insecure-registry \
    --output json | jq -r '.digest')
  COSIGN_PASSWORD="" cosign sign --yes \
    --key "${COSIGN_KEY}" \
    --tlog-upload=false \
    --allow-insecure-registry \
    "${REGISTRY}/${repo}@${digest}"
}

push_and_sign fleet d2-osramp-fleet
for component in cert-manager ingress monitoring trivy-system; do
  push_and_sign "infra/${component}" "d2-infra/components/${component}"
done
for component in frontend backend; do
  push_and_sign "apps/${component}" "d2-osramp-apps/components/${component}"
done
push_and_sign "olly/olly-replica" "olly-replica/components"

echo "all artifacts pushed and signed"
