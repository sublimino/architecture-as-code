#!/usr/bin/env bash
# scripts/test-phase1-governor.sh
# Phase 1 governance gate for the in-sentinel probe integration.
#
# Usage: scripts/test-phase1-governor.sh [--log SENTINEL_LOG]
#
#   --log FILE  stun-sentinel log to audit for reconcile_failed events, e.g.
#               `kubectl logs -n fe-signalloom-agents ds/stun-sentinel > FILE`.
#               Without it the zero-reconcile-failed check is not run and the
#               gate cannot certify.
#
# Steps run in order and stop at the first failure. The certification JSON
# (P1_GOV_OUT, default ci-evidence/) records what actually ran.
#
# Exit: 0 certified | 1 a check failed | 2 usage error | 3 incomplete (no --log)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${P1_GOV_OUT:-${REPO_ROOT}/ci-evidence}"
CERT_FILE="${OUT_DIR}/phase1-governance-certification.json"

usage() { echo "usage: $0 [--log SENTINEL_LOG]" >&2; exit 2; }

LOG_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --log) [[ $# -ge 2 ]] || usage; LOG_FILE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
if [[ -n "${LOG_FILE}" && ! -r "${LOG_FILE}" ]]; then
  echo "FATAL: sentinel log not found or unreadable: ${LOG_FILE}" >&2
  exit 2
fi

declare -A RESULT=([clean_tree]=not-run [go_suites]=not-run [bats_suites]=not-run [zero_reconcile_failed]=not-run)

write_cert() {
  local status="$1"
  mkdir -p "${OUT_DIR}"
  cat <<EOF >"${CERT_FILE}"
{
  "phase": 1,
  "governor": "SLDC-P1-GOV",
  "status": "${status}",
  "certified_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "git_commit": "$(git -C "${REPO_ROOT}" rev-parse HEAD)",
  "sentinel_log": "${LOG_FILE}",
  "verifications": {
    "clean_tree": "${RESULT[clean_tree]}",
    "go_suites": "${RESULT[go_suites]}",
    "bats_suites": "${RESULT[bats_suites]}",
    "zero_reconcile_failed": "${RESULT[zero_reconcile_failed]}"
  }
}
EOF
}

fail() {
  RESULT[$1]=fail
  echo "FATAL: $2" >&2
  write_cert failed
  exit 1
}

echo "--- 1. whitespace and conflict markers ---"
git -C "${REPO_ROOT}" diff --check || fail clean_tree "conflict markers or whitespace errors in the working tree"
RESULT[clean_tree]=pass

echo "--- 2. Go suites ---"
for app in stun-sentinel signalloom-stun-sentinel; do
  (cd "${REPO_ROOT}/d2-signalloom/apps/${app}" && CGO_ENABLED=0 go test ./...) ||
    fail go_suites "go test failed in d2-signalloom/apps/${app}"
done
RESULT[go_suites]=pass

echo "--- 3. BATS suites ---"
bats "${REPO_ROOT}/test/p1-sentinel-preflight.bats" "${REPO_ROOT}/test/sentinel-capabilities.bats" ||
  fail bats_suites "Phase 1 BATS suites failed"
RESULT[bats_suites]=pass

echo "--- 4. reconcile_failed audit ---"
if [[ -z "${LOG_FILE}" ]]; then
  echo "INCOMPLETE: no --log given; the zero-reconcile-failed check did not run" >&2
  write_cert incomplete
  exit 3
fi
COUNT="$(grep -cE '"event"[[:space:]]*:[[:space:]]*"reconcile_failed"' "${LOG_FILE}" || true)"
[[ "${COUNT}" -eq 0 ]] || fail zero_reconcile_failed "${COUNT} reconcile_failed events in ${LOG_FILE}"
RESULT[zero_reconcile_failed]=pass

write_cert certified
echo "Phase 1 Governance Gate verification COMPLETE: PASS"
