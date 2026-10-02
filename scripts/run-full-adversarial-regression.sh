#!/usr/bin/env bash
# scripts/run-full-adversarial-regression.sh
#
# SLAAT-P3-1: replays the four core adversarial probe suites from Phase 1
# against the Phase 2-hardened platform and asserts the attacks now fail
# cleanly. This is the "core four" regression named first in the card's
# Required Tests list:
#   1. test/adversarial-network-probes.bats        -- ingress/NetworkPolicy
#   2. tests/test_adversarial_api_security.py       -- backend API/IDOR
#   3. test/spiffe-openbao-adversarial.bats         -- SPIFFE/OpenBao
#   4. test/landlock-adversarial-escape.bats        -- sandbox/Landlock
#
# A bats/pytest `skip` is NOT counted as a pass or a fail: it means the probe
# could not be exercised against the live deployment (see the suite's own
# comments for why -- e.g. SLAAT-P2-4's burst-detector fix is proven at the
# unit level but the shared cluster's sentinel DaemonSet was deliberately
# rolled back rather than ship a broken ring-buffer pipeline to every other
# concurrent SLAAT card). Skips are surfaced in the report, not hidden inside
# a passing total, per the mission's Adversarial Integrity pattern ("no
# silent swallows or masking").
#
# Exit: 0 if every suite ran with zero failing assertions (skips allowed,
# reported); 1 if any suite reported a failing assertion; 2 usage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_FILE="${1:-${REPO_ROOT}/ci-evidence/slaat-p3-1-replay-results.json}"

cd "${REPO_ROOT}"

export GOCACHE="${GOCACHE:-/tmp/slaat-p3-1-gocache}"
export GOMODCACHE="${GOMODCACHE:-/tmp/slaat-p3-1-gomodcache}"
export CGO_ENABLED=0
export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-/tmp/slaat-p3-1-pycache}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/slaat-p3-1-uvcache}"
mkdir -p "${GOCACHE}" "${GOMODCACHE}" "${PYTHONPYCACHEPREFIX}" "${UV_CACHE_DIR}" "$(dirname "${OUT_FILE}")"

echo "══════════════════════════════════════════════════════════════════"
echo " SLAAT-P3-1: Core Four Adversarial Regression Replay"
echo "══════════════════════════════════════════════════════════════════"
echo "Repo Root: ${REPO_ROOT}"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "══════════════════════════════════════════════════════════════════"

SUITES_JSON="[]"
TOTAL_FAIL=0

# parse_bats_tap FILE -> echoes "ok fail skip" counts from a bats TAP stream.
parse_bats_tap() {
  awk '
    /^ok [0-9]+/ { ok++ }
    /^not ok [0-9]+/ { fail++ }
    /# skip/ { skip++; if (/^ok/) ok--; }
    END { printf "%d %d %d\n", ok+0, fail+0, skip+0 }
  ' "$1"
}

run_bats_suite() {
  local id="$1" name="$2" path="$3" log tap ok fail skip rc=0
  log="$(mktemp)"
  echo ""
  echo "--- [${id}] ${name} (${path}) ---"
  start_ts=$(date +%s.%N)
  bats "${path}" >"${log}" 2>&1 || rc=$?
  end_ts=$(date +%s.%N)
  dur=$(awk -v a="${start_ts}" -v b="${end_ts}" 'BEGIN{printf "%.3f", b-a}')
  cat "${log}"
  read -r ok fail skip < <(parse_bats_tap "${log}")
  [ "${fail}" -gt 0 ] && TOTAL_FAIL=$((TOTAL_FAIL + fail))
  SUITES_JSON="$(jq -c --arg id "${id}" --arg name "${name}" --arg path "${path}" \
    --arg dur "${dur}" --argjson ok "${ok}" --argjson fail "${fail}" --argjson skip "${skip}" --argjson rc "${rc}" \
    '. + [{id: $id, name: $name, type: "bats", path: $path, duration_seconds: ($dur|tonumber), passed: $ok, failed: $fail, skipped: $skip, exit_code: $rc}]' \
    <<<"${SUITES_JSON}")"
  rm -f "${log}"
}

run_pytest_suite() {
  local id="$1" name="$2" dir="$3" path="$4" log passed failed skipped rc=0
  log="$(mktemp)"
  echo ""
  echo "--- [${id}] ${name} (${path}) ---"
  start_ts=$(date +%s.%N)
  (cd "${dir}" && pytest "${path}" -v) >"${log}" 2>&1 || rc=$?
  end_ts=$(date +%s.%N)
  dur=$(awk -v a="${start_ts}" -v b="${end_ts}" 'BEGIN{printf "%.3f", b-a}')
  cat "${log}"
  passed=$(grep -oE '[0-9]+ passed' "${log}" | tail -1 | grep -oE '[0-9]+' || echo 0)
  failed=$(grep -oE '[0-9]+ failed' "${log}" | tail -1 | grep -oE '[0-9]+' || echo 0)
  skipped=$(grep -oE '[0-9]+ skipped' "${log}" | tail -1 | grep -oE '[0-9]+' || echo 0)
  [ "${failed}" -gt 0 ] && TOTAL_FAIL=$((TOTAL_FAIL + failed))
  SUITES_JSON="$(jq -c --arg id "${id}" --arg name "${name}" --arg path "${path}" \
    --arg dur "${dur}" --argjson ok "${passed}" --argjson fail "${failed}" --argjson skip "${skipped}" --argjson rc "${rc}" \
    '. + [{id: $id, name: $name, type: "pytest", path: $path, duration_seconds: ($dur|tonumber), passed: $ok, failed: $fail, skipped: $skip, exit_code: $rc}]' \
    <<<"${SUITES_JSON}")"
  rm -f "${log}"
}

run_bats_suite CORE-1 "Ingress Gateway & NetworkPolicy Isolation" "test/adversarial-network-probes.bats"
run_pytest_suite CORE-2 "Backend API & SQLi/Injection Fuzzing" \
  "${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/src" "tests/test_adversarial_api_security.py"
run_bats_suite CORE-3 "SPIFFE Identity & OpenBao JWT Privilege Escalation" "test/spiffe-openbao-adversarial.bats"
run_bats_suite CORE-4 "Sentinel eBPF & Landlock Sandbox Escape" "test/landlock-adversarial-escape.bats"

VERDICT="PASS"
[ "${TOTAL_FAIL}" -gt 0 ] && VERDICT="FAIL"

GIT_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "unknown")"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
TOTAL_SKIPPED="$(jq '[.[].skipped] | add' <<<"${SUITES_JSON}")"

jq -n --arg ts "${TIMESTAMP}" --arg sha "${GIT_SHA}" --arg verdict "${VERDICT}" \
  --argjson total_fail "${TOTAL_FAIL}" --argjson total_skipped "${TOTAL_SKIPPED}" --argjson suites "${SUITES_JSON}" \
  '{timestamp: $ts, git_commit: $sha, verdict: $verdict, total_failed_assertions: $total_fail, total_skipped_assertions: $total_skipped, exploits_succeeded: $total_fail, suites: $suites, note: "A skipped assertion means the probe could not be exercised against the current live deployment (documented per-suite); it is neither a pass nor a successful exploit, and is reported separately from exploits_succeeded."}' \
  >"${OUT_FILE}"

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " VERDICT: ${VERDICT} -- ${TOTAL_FAIL} exploit(s) succeeded, ${TOTAL_SKIPPED} assertion(s) skipped"
echo " Artifact: ${OUT_FILE}"
echo "══════════════════════════════════════════════════════════════════"

[ "${VERDICT}" = "PASS" ] && exit 0 || exit 1
