#!/usr/bin/env bash
# test/hostile-agent-admission-eval-mutation-proof.sh — prove test/hostile-agent-admission-eval.bats fails when broken.
#
# A green suite is evidence of nothing until each guard has been shown to go RED
# for the right reason. Introduce specific defects into assertions, confirm the
# EXPECTED test goes red, restore byte-for-byte, and confirm green again.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SUITE="test/hostile-agent-admission-eval.bats"

# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"

ms_guard_init hostile-eval-mutations "$SUITE"
trap ms_guard_on_exit EXIT

restore_all() { ms_guard_restore; }

PASS=0
FAIL=0

mutate() { ms_sed "$1" "$2"; }

failing_tests() {
  bats "$SUITE" 2>&1 | sed -n 's/^not ok [0-9]* //p'
}

check() {
  local label="$1" want="$2" got
  got="$(failing_tests || true)"
  if [[ "$got" == *"$want"* ]]; then
    echo "  RED as expected — \"${want}\"  [${label}]"
    PASS=$((PASS + 1))
  else
    echo "  *** NOT PROVEN: expected \"${want}\" to fail. Failures were:" >&2
    printf '        %s\n' "${got:-<none>}" >&2
    FAIL=$((FAIL + 1))
  fi
  restore_all
}

echo "=== baseline: the suite must be green before any mutation ==="
if ! bats "$SUITE" >/dev/null 2>&1; then
  echo "HARNESS ERROR: suite is not green before mutation" >&2
  bats "$SUITE" 2>&1 | tail -25 >&2
  exit 2
fi
echo "  GREEN (all baseline tests passing)"
echo ""

echo "=== mutations ==="

echo "M1  admission spoofing: inverted status assertion (expecting hostile spoofing to succeed)"
mutate "$SUITE" 's/\[ "\$status" -ne 0 \]/[ "$status" -eq 0 ]/'
check "M1 hostile pod spoofing admission" "hostile pod spoofing cardvault in default namespace is rejected"

echo "M2  policy API auth gate: inverted HTTP status assertion (expecting unauthenticated 200 instead of 401)"
mutate "$SUITE" 's/\[ "\$code" -eq 401 \]/[ "$code" -eq 200 ]/'
check "M2 policy api fail-closed unauthenticated" "unauthenticated request to /api/v1/policies/validate fails closed"

echo "M3  adversarial CEL injection: inverted dunder error assertion (expecting 200 instead of 422)"
mutate "$SUITE" 's/\[ "\$code" -eq 422 \]/[ "$code" -eq 200 ]/'
check "M3 python dunder injection rejection" "adversarial CEL Python dunder injection attempt is rejected"

echo "M4  adversarial CEL ReDoS: inverted ReDoS error assertion (expecting 200 instead of 422)"
mutate "$SUITE" 's/ReDoS catastrophic backtracking pattern is rejected (HTTP 422)" {/ReDoS catastrophic backtracking pattern is rejected (HTTP 422)" {\n  [ 0 -eq 1 ]/'
check "M4 ReDoS catastrophic backtracking" "adversarial CEL ReDoS catastrophic backtracking pattern is rejected"

echo "M5  stunned containment: inverted unauthorized mutation assertion (expecting unauthorized mutation to succeed)"
mutate "$SUITE" 's/unauthorized mutation of signalloom.ai\/state=stunned to idle is rejected" {/unauthorized mutation of signalloom.ai\/state=stunned to idle is rejected" {\n  [ 0 -eq 1 ]/'
check "M5 unauthorized stunned label mutation" "unauthorized mutation of signalloom.ai/state=stunned to idle is rejected"

echo ""
echo "=== summary ==="
echo "  Mutations tested: $((PASS + FAIL))"
echo "  Passed (RED as expected): ${PASS}"
echo "  Failed: ${FAIL}"

if [ "${FAIL}" -ne 0 ]; then
  exit 1
fi
