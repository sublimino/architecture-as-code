#!/usr/bin/env bash
# Policy-gated promotion demo: one artifact approved, one rejected, both
# decisions evidenced in Archivista.
#
# The approved path verifies the merged VEX document produced under the
# attested vex-analysis step against the signed witness policy. The rejected
# path verifies a tampered copy of the same artifact, which no attestation
# covers, so the policy fails closed.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"

ARTIFACT="vex/out/osramp.attested.openvex.json"
POLICY="policy/out/promotion-policy.signed.json"

test -f "${ARTIFACT}" || { echo "${ARTIFACT} missing; run 'make vex-demo' with the cluster up first"; exit 1; }
test -f "${POLICY}" || ./scripts/gen-witness-policy.sh

kubectl -n backend port-forward svc/osramp-archivista 8082:8082 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
trap 'kill ${PORT_FORWARD_PID} 2>/dev/null || true' EXIT
wait_reachable "http://localhost:8082/v1/health" 60

gate() {
  local candidate="$1" label="$2"
  echo
  echo "=== promotion gate: ${label}"
  if witness verify \
      -f "${candidate}" \
      -p "${POLICY}" \
      -k .keys/policy-pub.pem \
      --enable-archivista --archivista-server=http://localhost:8082; then
    echo "DECISION: promotion approved for ${label}"
    return 0
  else
    echo "DECISION: promotion rejected for ${label}"
    return 1
  fi
}

# The genuine artifact: produced by the attested pipeline, expected to pass.
approved=0
gate "${ARTIFACT}" "attested artifact" || approved=1

# The tampered artifact: same content plus one byte, no attestation covers it.
TAMPERED="vex/out/tampered.openvex.json"
cp "${ARTIFACT}" "${TAMPERED}"
printf '\n' >> "${TAMPERED}"
rejected=0
gate "${TAMPERED}" "tampered artifact" && rejected=1

# Record the gate outcomes themselves as signed evidence.
witness run --step promotion-decision \
  -o vex/out/promotion-decision.attestation.json \
  -k .keys/witness.pem \
  --enable-archivista --archivista-server=http://localhost:8082 \
  -- bash -c "echo approved=$((approved == 0)) rejected-tamper=$((rejected == 0)) > vex/out/promotion-decision.txt"

echo
if [ "${approved}" -eq 0 ] && [ "${rejected}" -eq 0 ]; then
  echo "promotion demo passed: genuine artifact approved, tampered artifact rejected, decisions in Archivista"
else
  echo "promotion demo FAILED: approved=${approved} tamper-rejected=${rejected}"
  exit 1
fi
