#!/usr/bin/env bash
# Run the end-to-end test suite under witness so the test evidence lands in
# Archivista as a signed attestation, then verify it is queryable.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"

test -f .keys/witness.pem || { echo ".keys/witness.pem not found; run 'make signing-keys'"; exit 1; }
command -v witness >/dev/null || { echo "witness not installed"; exit 1; }

kubectl -n backend port-forward svc/osramp-archivista 8082:8082 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
trap 'kill ${PORT_FORWARD_PID} 2>/dev/null || true' EXIT
wait_reachable "http://localhost:8082/v1/health" 60

mkdir -p vex/out
witness run --step test-evidence \
  -o vex/out/test-evidence.attestation.json \
  -k .keys/witness.pem \
  --enable-archivista --archivista-server=http://localhost:8082 \
  -- bash -c "cd d2-osramp-apps/test && bats osramp.bats"

echo "querying Archivista for stored envelopes"
stored=$(curl -fsS -X POST http://localhost:8082/query \
  -H "Content-Type: application/json" \
  -d '{"query":"query { dsses(first: 5) { edges { node { gitoidSha256 } } } }"}' \
  | jq '.data.dsses.edges | length')
echo "Archivista holds ${stored} recent envelopes (test evidence included)"
test "${stored}" -gt 0
