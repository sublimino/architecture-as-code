#!/usr/bin/env bash
# Exercise the Go FrostDB flush path, then independently verify, tamper, and
# restore the exact Parquet bytes it retained. This never substitutes fixtures.
set -euo pipefail

cd "$(dirname "$0")/.."

PYTHON="${PYTHON:-python3}"
KEYS_DIR="${KEYS_DIR:-.keys}"
PROOF_DIR="${SIGNAL_SEGMENT_PROOF_DIR:-$(mktemp -d)}"
STORE_DIR="${PROOF_DIR}/store"
EVIDENCE_DIR="${PROOF_DIR}/evidence"
HIGH_WATER="${PROOF_DIR}/protected/highwater.json"
JOURNAL="${EVIDENCE_DIR}/segments.jsonl"
ANCHOR_DIR="${EVIDENCE_DIR}/checkpoints"
SRC="d2-signalloom/apps/fe-signalloom/src"
GO_DIR="d2-signalloom/apps/signal-ingest"
GO_PACKAGE="./store"
GO_TEST="TestGoEvidenceAcceptedThenMutationRejectedByPythonVerifier"
GO_CACHE_ROOT="${SFDP_GO_CACHE_ROOT:-/tmp/opencode/sfdp-p3-3-go}"

mkdir -p "${PROOF_DIR}"
mkdir -p "${GO_CACHE_ROOT}/build" "${GO_CACHE_ROOT}/mod"
PROOF_DIR="$(cd "${PROOF_DIR}" && pwd)"
STORE_DIR="${PROOF_DIR}/store"
EVIDENCE_DIR="${PROOF_DIR}/evidence"
HIGH_WATER="${PROOF_DIR}/protected/highwater.json"
JOURNAL="${EVIDENCE_DIR}/segments.jsonl"
ANCHOR_DIR="${EVIDENCE_DIR}/checkpoints"
KEYS_DIR="$(cd "${KEYS_DIR}" && pwd)"
SIGNING_POLICY="${KEYS_DIR}/segment-signing-policy.json"
for key in "${KEYS_DIR}/witness.pem" "${KEYS_DIR}/witness-pub.pem"; do
  [ -f "${key}" ] || { echo "signing key not found: ${key}; run 'make signing-keys'" >&2; exit 1; }
done
[ -f "${SIGNING_POLICY}" ] || { echo "protected signing policy not found: ${SIGNING_POLICY}; run 'make signing-keys'" >&2; exit 1; }
EXPECTED_KEY_ID="$(jq -er '.expected_key_ids | if length == 1 then .[0] else error("expected exactly one signer") end' "${SIGNING_POLICY}")"
[[ "${EXPECTED_KEY_ID}" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid expected key id in ${SIGNING_POLICY}" >&2; exit 1; }

if [ -n "${ARCHIVISTA_URL:-}" ]; then
  export AUDIT_ANCHOR_REQUIRE_LOG=1
fi

echo "segment proof directory: ${PROOF_DIR}"
echo "running Go FrostDB integration test: ${GO_TEST}"
SIGNAL_SEGMENT_PROOF_DIR="${PROOF_DIR}" \
SIGNAL_SEGMENT_STORE_DIR="${STORE_DIR}" \
SIGNAL_SEGMENT_EVIDENCE_DIR="${EVIDENCE_DIR}" \
SIGNAL_SEGMENT_HIGHWATER="${HIGH_WATER}" \
SIGNAL_SEGMENT_SIGNING_KEY="${KEYS_DIR}/witness.pem" \
SIGNAL_SEGMENT_PUBLIC_KEY="${KEYS_DIR}/witness-pub.pem" \
SIGNAL_SEGMENT_EXPECTED_KEY_ID="${EXPECTED_KEY_ID}" \
GOCACHE="${GO_CACHE_ROOT}/build" \
GOMODCACHE="${GO_CACHE_ROOT}/mod" \
CGO_ENABLED=0 \
  go -C "${GO_DIR}" test -tags=frostdb "${GO_PACKAGE}" -run "^${GO_TEST}$" -count=1 -v

for retained in "${JOURNAL}" "${HIGH_WATER}"; do
  [ -s "${retained}" ] || {
    echo "Go integration test did not retain required evidence: ${retained}" >&2
    echo "The Go-owned test must honour SIGNAL_SEGMENT_PROOF_DIR; fixtures are forbidden." >&2
    exit 1
  }
done

verify() {
  local output=$1
  local -a strict=()
  if [ -n "${ARCHIVISTA_URL:-}" ]; then
    strict+=(--require-archivista)
  fi
  (
    cd "${SRC}"
    AUDIT_ANCHOR_DIR="${ANCHOR_DIR}" "${PYTHON}" -m audit_anchor \
      --public-key "${KEYS_DIR}/witness-pub.pem" \
      --expected-key-id "${EXPECTED_KEY_ID}" \
      --source segments \
      --segment-journal "${JOURNAL}" \
      --segment-root "${STORE_DIR}" \
      --protected-high-water "${HIGH_WATER}" \
      "${strict[@]}" verify --json
  ) >"${output}"
}

assert_intact() {
  jq -e '.status == "intact" and .proves_anything == true and .checkpoints_checked > 0 and .unanchored_row_count == 0' "$1" >/dev/null
}

assert_diverged() {
  jq -e '.status == "diverged"' "$1" >/dev/null
}

INTACT_JSON="${PROOF_DIR}/verify-intact.json"
DIVERGED_JSON="${PROOF_DIR}/verify-diverged.json"
RESTORED_JSON="${PROOF_DIR}/verify-restored.json"

verify "${INTACT_JSON}"
assert_intact "${INTACT_JSON}"
cat "${INTACT_JSON}"

IFS= read -r FIRST_RECORD <"${JOURNAL}"
SEGMENT_ID="$(jq -er '.segment_id' <<<"${FIRST_RECORD}")"
SEGMENT_FILE="${STORE_DIR}/${SEGMENT_ID}"
[ -s "${SEGMENT_FILE}" ] || { echo "retained Parquet segment not found: ${SEGMENT_FILE}" >&2; exit 1; }
ORIGINAL="${PROOF_DIR}/original.parquet"
cp "${SEGMENT_FILE}" "${ORIGINAL}"
printf '\000' | dd of="${SEGMENT_FILE}" bs=1 seek=0 count=1 conv=notrunc status=none

set +e
verify "${DIVERGED_JSON}"
verify_status=$?
set -e
[ "${verify_status}" -eq 2 ] || { echo "expected tampered verification exit 2, got ${verify_status}" >&2; exit 1; }
assert_diverged "${DIVERGED_JSON}"
cat "${DIVERGED_JSON}"

cp "${ORIGINAL}" "${SEGMENT_FILE}"
verify "${RESTORED_JSON}"
assert_intact "${RESTORED_JSON}"
cat "${RESTORED_JSON}"

echo "PASS: real FrostDB Parquet evidence was intact, diverged after mutation, and intact after restore"
