#!/usr/bin/env bash
# Run the cluster audit suite under Witness and verify fresh local evidence.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "${REPO_ROOT}"
# shellcheck source=scripts/lib/witness-local.sh
source "${REPO_ROOT}/scripts/lib/witness-local.sh"
witness_local_validate_environment

SOURCE="${ATTESTED_TEST_SOURCE:-audit}"
case "${SOURCE}" in
  segments) exec ./scripts/segment-attestation-proof.sh ;;
  audit) ;;
  *) echo "ATTESTED_TEST_SOURCE must be audit or segments, got: ${SOURCE}" >&2; exit 1 ;;
esac

KEYS_DIR=$(cd "${KEYS_DIR:-.keys}" && pwd)
OUT_DIR="${ATTESTED_TEST_OUT_DIR:-docs/records/ci-evidence/local-witness/attested-test}"
mkdir -p "${OUT_DIR}"
OUT_DIR=$(cd "${OUT_DIR}" && pwd)
RUN_DIR="${OUT_DIR}/test-evidence"
TEMP_DIR=$(mktemp -d)
# Witness isolates HOME; keep kubectl's existing client configuration explicit.
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
export WITNESS_LOCAL_HOME="${TEMP_DIR}/home"
trap 'rm -rf "${TEMP_DIR}"' EXIT
mkdir -p "${WITNESS_LOCAL_HOME}"

test -f "${KEYS_DIR}/witness.pem" || { echo "witness key not found; run 'make signing-keys'" >&2; exit 1; }
command -v witness >/dev/null || { echo "witness not installed" >&2; exit 1; }
witness_local_trust_bundle "${KEYS_DIR}" "${OUT_DIR}/trust"
rm -rf "${RUN_DIR}"
witness_local_prepare "${RUN_DIR}"
# Positional parameters expand in the child shell.
# shellcheck disable=SC2016
witness_local_run "${RUN_DIR}" --step test-evidence \
  -o "${OUT_DIR}/test-evidence.attestation.json" -k "${KEYS_DIR}/witness.pem" \
  -- bash -c 'set -o pipefail; bats "$1" | tee runtime-bats.result' _ \
  "${REPO_ROOT}/d2-signalloom/test/runtime.bats"

ARTIFACT="${RUN_DIR}/runtime-bats.result"
ATTESTATION="${OUT_DIR}/test-evidence.attestation.json"
test -s "${ARTIFACT}"
test -s "${ATTESTATION}"
POLICY_KEY="${KEYS_DIR}/policy.pem" POLICY_PUB="${KEYS_DIR}/policy-pub.pem" \
  ./scripts/gen-witness-policy.sh test-evidence "${OUT_DIR}/intended-policy" \
  "${KEYS_DIR}/witness.pem" "${KEYS_DIR}/witness-pub.pem"
verify_intended() {
  witness_local_verify "${RUN_DIR}" -f "$1" -a "$2" \
    -p "${OUT_DIR}/intended-policy/promotion-policy.signed.json" \
    -k "${KEYS_DIR}/policy-pub.pem"
}
verify_intended "${ARTIFACT}" "${ATTESTATION}"

cp "${ARTIFACT}" "${RUN_DIR}/tampered-runtime-bats.result"
printf '\ntampered\n' >> "${RUN_DIR}/tampered-runtime-bats.result"
test -s "${RUN_DIR}/tampered-runtime-bats.result"
test -s "${ATTESTATION}"
if verify_intended "${RUN_DIR}/tampered-runtime-bats.result" "${ATTESTATION}" \
    >"${OUT_DIR}/tampered-evidence.rejection.txt" 2>&1; then
  echo "tampered test evidence was accepted" >&2
  exit 1
fi
witness_local_expect_policy_rejection \
  "${OUT_DIR}/tampered-evidence.rejection.txt" test-evidence

WRONG_DIR="${OUT_DIR}/wrong-key-evidence"
rm -rf "${WRONG_DIR}"
witness_local_prepare "${WRONG_DIR}"
openssl genpkey -algorithm ed25519 -out "${TEMP_DIR}/wrong.pem" >/dev/null 2>&1
openssl pkey -in "${TEMP_DIR}/wrong.pem" -pubout -out "${TEMP_DIR}/wrong-pub.pem"
# Positional parameters expand in the child shell.
# shellcheck disable=SC2016
witness_local_run "${WRONG_DIR}" --step test-evidence \
  -o "${OUT_DIR}/wrong-key.attestation.json" -k "${TEMP_DIR}/wrong.pem" \
  -- bash -c 'printf "fresh wrong signer product %s\n" "$1" > wrong-key.result' _ \
  "$(date -u +%Y%m%dT%H%M%SZ)-$$"
test -s "${WRONG_DIR}/wrong-key.result"
test -s "${OUT_DIR}/wrong-key.attestation.json"
POLICY_KEY="${KEYS_DIR}/policy.pem" POLICY_PUB="${KEYS_DIR}/policy-pub.pem" \
  ./scripts/gen-witness-policy.sh test-evidence "${OUT_DIR}/wrong-signer-policy" \
  "${TEMP_DIR}/wrong.pem" "${TEMP_DIR}/wrong-pub.pem"
witness_local_verify "${WRONG_DIR}" -f "${WRONG_DIR}/wrong-key.result" \
  -a "${OUT_DIR}/wrong-key.attestation.json" \
  -p "${OUT_DIR}/wrong-signer-policy/promotion-policy.signed.json" \
  -k "${KEYS_DIR}/policy-pub.pem"
test -s "${WRONG_DIR}/wrong-key.result"
test -s "${OUT_DIR}/wrong-key.attestation.json"
if verify_intended "${WRONG_DIR}/wrong-key.result" "${OUT_DIR}/wrong-key.attestation.json" \
    >"${OUT_DIR}/wrong-key-intended-policy.rejection.txt" 2>&1; then
  echo "wrong-key test evidence was accepted by intended policy" >&2
  exit 1
fi
witness_local_expect_policy_rejection \
  "${OUT_DIR}/wrong-key-intended-policy.rejection.txt" test-evidence wrong-signer

echo "local test evidence verified: ${ATTESTATION}"
