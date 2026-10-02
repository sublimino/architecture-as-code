#!/usr/bin/env bash
# scripts/verify-openbao-hardening.sh
#
# SLAAT-P3-1 replay wrapper. The card's literal Required Test names this
# script; it did not exist anywhere in the repo prior to this card (SLAAT-P2-3's
# errata already documented the same gap for the same filename and substituted
# the live probe scripts + bats suites directly -- this script wraps that same
# substitute into the single named entry point the card expects).
#
# Re-runs the live OpenBao/SPIFFE credential-boundary probes
# (probe-openbao-acls.sh, probe-spiffe-privilege-escalation.sh) plus the two
# bats suites that assert on their output (openbao-security-probes.bats,
# spiffe-openbao-policy-hardening.bats), and reports a single PASS/FAIL
# verdict plus a machine-readable record.
#
# Exit: 0 all four held; 1 any failed; 2 usage/missing prerequisite.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_FILE="${1:-${REPO_ROOT}/ci-evidence/slaat-p3-1-openbao-hardening-verification.json}"

cd "${REPO_ROOT}"

export GOCACHE="${GOCACHE:-/tmp/slaat-p3-1-gocache}"
export GOMODCACHE="${GOMODCACHE:-/tmp/slaat-p3-1-gomodcache}"
export CGO_ENABLED=0
mkdir -p "${GOCACHE}" "${GOMODCACHE}" "$(dirname "${OUT_FILE}")"

echo "════ SLAAT-P3-1: OpenBao Hardening Verification ════"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

TOTAL=0
FAILED=0
RESULTS_JSON="[]"

run_check() {
  local id="$1" name="$2" cmd="$3" out rc=0 status
  TOTAL=$((TOTAL + 1))
  start_ts=$(date +%s.%N)
  out="$(bash -c "${cmd}" 2>&1)" || rc=$?
  end_ts=$(date +%s.%N)
  dur=$(awk -v a="${start_ts}" -v b="${end_ts}" 'BEGIN{printf "%.3f", b-a}')
  if [ "${rc}" -eq 0 ]; then
    status="PASS"
    echo "PASS [${id}] ${name} (${dur}s)"
  else
    status="FAIL"
    FAILED=$((FAILED + 1))
    echo "FAIL [${id}] ${name} (${dur}s)" >&2
    echo "${out}" | tail -n 20 >&2
  fi
  RESULTS_JSON="$(jq -c --arg id "${id}" --arg name "${name}" --arg st "${status}" \
    --arg dur "${dur}" --arg tail "$(printf '%s' "${out}" | tail -n 5)" \
    '. + [{id: $id, name: $name, status: $st, duration_seconds: ($dur|tonumber), tail: $tail}]' \
    <<<"${RESULTS_JSON}")"
}

run_check "OBH-1" "OpenBao ACL audit (probe-openbao-acls.sh)" \
  "./scripts/probe-openbao-acls.sh"
run_check "OBH-2" "SPIFFE privilege-escalation probe (probe-spiffe-privilege-escalation.sh)" \
  "./scripts/probe-spiffe-privilege-escalation.sh"
run_check "OBH-3" "OpenBao security probes bats suite (test/openbao-security-probes.bats)" \
  "bats test/openbao-security-probes.bats"
run_check "OBH-4" "SPIFFE/OpenBao policy hardening bats suite (test/spiffe-openbao-policy-hardening.bats)" \
  "bats test/spiffe-openbao-policy-hardening.bats"

VERDICT="PASS"
[ "${FAILED}" -gt 0 ] && VERDICT="FAIL"

GIT_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "unknown")"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

jq -n --arg ts "${TIMESTAMP}" --arg sha "${GIT_SHA}" --arg verdict "${VERDICT}" \
  --argjson total "${TOTAL}" --argjson failed "${FAILED}" --argjson results "${RESULTS_JSON}" \
  '{timestamp: $ts, git_commit: $sha, verdict: $verdict, total_checks: $total, failed_checks: $failed, checks: $results}' \
  >"${OUT_FILE}"

echo "───────────────────────────────────────────────────"
echo "VERDICT: ${VERDICT} ($((TOTAL - FAILED))/${TOTAL} checks held)"
echo "Artifact: ${OUT_FILE}"

[ "${VERDICT}" = "PASS" ] && exit 0 || exit 1
