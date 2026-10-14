#!/usr/bin/env bash
# Gate a fresh generic artifact using hermetic local Witness evidence.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "${REPO_ROOT}"
# shellcheck source=scripts/lib/witness-local.sh
source "${REPO_ROOT}/scripts/lib/witness-local.sh"
witness_local_validate_environment

KEYS_DIR=$(cd "${KEYS_DIR:-.keys}" && pwd)
OUT_DIR="${PROMOTION_OUT_DIR:-docs/records/ci-evidence/local-witness/promotion-demo}"
mkdir -p "${OUT_DIR}"
OUT_DIR=$(cd "${OUT_DIR}" && pwd)
ARTIFACT_DIR="${OUT_DIR}/artifact-build"
DECISION_DIR="${OUT_DIR}/promotion-decision"
TRUST_DIR="${OUT_DIR}/trust"
TEMP_DIR=$(mktemp -d)
export WITNESS_LOCAL_HOME="${TEMP_DIR}/home"
trap 'rm -rf "${TEMP_DIR}"' EXIT
mkdir -p "${WITNESS_LOCAL_HOME}" "${TRUST_DIR}"

test -f "${KEYS_DIR}/witness.pem" || { echo "witness key not found; run 'make signing-keys'" >&2; exit 1; }
command -v witness >/dev/null || { echo "witness not installed" >&2; exit 1; }
witness_local_trust_bundle "${KEYS_DIR}" "${TRUST_DIR}"

rm -rf "${ARTIFACT_DIR}" "${DECISION_DIR}"
witness_local_prepare "${ARTIFACT_DIR}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
# Positional parameters expand in the child shell.
# shellcheck disable=SC2016
witness_local_run "${ARTIFACT_DIR}" --step artifact-build \
  -o "${OUT_DIR}/artifact-build.attestation.json" -k "${KEYS_DIR}/witness.pem" \
  -- bash -c 'printf "generic signed artifact %s\n" "$1" > generic-artifact.txt' _ "${RUN_ID}"

ARTIFACT="${ARTIFACT_DIR}/generic-artifact.txt"
ATTESTATION="${OUT_DIR}/artifact-build.attestation.json"
test -s "${ARTIFACT}"
test -s "${ATTESTATION}"
POLICY_KEY="${KEYS_DIR}/policy.pem" POLICY_PUB="${KEYS_DIR}/policy-pub.pem" \
  ./scripts/gen-witness-policy.sh artifact-build "${OUT_DIR}/artifact-policy" \
  "${KEYS_DIR}/witness.pem" "${KEYS_DIR}/witness-pub.pem"

gate_artifact() {
  witness_local_verify "${ARTIFACT_DIR}" -f "$1" -a "${ATTESTATION}" \
    -p "${OUT_DIR}/artifact-policy/promotion-policy.signed.json" \
    -k "${KEYS_DIR}/policy-pub.pem"
}
gate_artifact "${ARTIFACT}"

cp "${ARTIFACT}" "${ARTIFACT_DIR}/modified-artifact.txt"
printf 'modified\n' >> "${ARTIFACT_DIR}/modified-artifact.txt"
test -s "${ARTIFACT_DIR}/modified-artifact.txt"
test -s "${ATTESTATION}"
if gate_artifact "${ARTIFACT_DIR}/modified-artifact.txt" \
    >"${OUT_DIR}/modified-artifact.rejection.txt" 2>&1; then
  echo "modified artifact was approved" >&2
  exit 1
fi
witness_local_expect_policy_rejection \
  "${OUT_DIR}/modified-artifact.rejection.txt" artifact-build

witness_local_prepare "${DECISION_DIR}"
# Positional parameters expand in the child shell.
# shellcheck disable=SC2016
witness_local_run "${DECISION_DIR}" --step promotion-decision \
  -o "${OUT_DIR}/promotion-decision.attestation.json" -k "${KEYS_DIR}/witness.pem" \
  -- bash -c 'printf "run_id=%s\napproved_original=true\nrejected_modified=true\n" "$1" > promotion-decision.txt' _ "${RUN_ID}"
test -s "${DECISION_DIR}/promotion-decision.txt"
test -s "${OUT_DIR}/promotion-decision.attestation.json"
POLICY_KEY="${KEYS_DIR}/policy.pem" POLICY_PUB="${KEYS_DIR}/policy-pub.pem" \
  ./scripts/gen-witness-policy.sh promotion-decision "${OUT_DIR}/decision-policy" \
  "${KEYS_DIR}/witness.pem" "${KEYS_DIR}/witness-pub.pem"
witness_local_verify "${DECISION_DIR}" -f "${DECISION_DIR}/promotion-decision.txt" \
  -a "${OUT_DIR}/promotion-decision.attestation.json" \
  -p "${OUT_DIR}/decision-policy/promotion-policy.signed.json" \
  -k "${KEYS_DIR}/policy-pub.pem"

if find "${OUT_DIR}" -type f \( -name '*.key' -o -name '*.pem' \) \
    ! -name '*-pub.pem' | grep -q .; then
  echo "private key found in retained evidence" >&2
  exit 1
fi

echo "promotion demo passed: original approved, modified rejected, fresh decision verified"
