#!/usr/bin/env bash
# scripts/kagent-test.sh — Run the Kagent D5 test suites.
#
# WHAT CHANGED AND WHY
# --------------------
# This script used to be:
#
#     if bats "$suite" 2>/dev/null; then return 0; fi
#     /usr/bin/python3 -c '<a hand-written .bats parser>'
#
# Three defects, all of which manufactured green:
#
#   1. `2>/dev/null` discarded bats' diagnostics, so a suite that failed to
#      *load* looked the same as one that failed an assertion.
#   2. ANY bats failure silently fell through to the embedded parser. That
#      parser terminates a test body at the first line whose stripped content
#      is "}" — which is how every `|| { echo ...; return 1; }` block in
#      d2-signalloom/test/kagent-contract.bats ends. It therefore executed a
#      TRUNCATED test, with the assertions removed, and reported it as passing.
#      A red suite could come back green by falling into the fallback.
#   3. PATH was hardcoded to /home/andy/src/cp/osramp-demo/scripts/bin, so a
#      run from any git worktree silently used another checkout's helpers.
#
# bats is now required, its output is not filtered, and the run reports a real
# per-suite tally that scripts/kagent-harness-exec.sh records verbatim.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${REPO_ROOT}/scripts/bin:${PATH}"

KUBECONFIG_PATH="${KUBECONFIG:-}"
if [ -z "${KUBECONFIG_PATH}" ]; then
  if [ -f "${REPO_ROOT}/.kind/kubeconfig" ]; then
    KUBECONFIG_PATH="${REPO_ROOT}/.kind/kubeconfig"
  else
    COMMON_ROOT="$(cd "$REPO_ROOT" && dirname "$(git rev-parse --git-common-dir 2>/dev/null || echo ".")")"
    if [ -f "${COMMON_ROOT}/.kind/kubeconfig" ]; then
      KUBECONFIG_PATH="${COMMON_ROOT}/.kind/kubeconfig"
    fi
  fi
fi
if [ -n "${KUBECONFIG_PATH}" ] && [ -f "${KUBECONFIG_PATH}" ]; then
  export KUBECONFIG="${KUBECONFIG_PATH}"
fi

if ! command -v bats >/dev/null 2>&1; then
  echo "FATAL: bats is not installed." >&2
  echo "This script used to fall back to an embedded parser that silently" >&2
  echo "truncated test bodies and reported the remains as passing. Refusing" >&2
  echo "to report a result rather than reporting a fabricated one." >&2
  exit 127
fi

SUITES=(
  "${REPO_ROOT}/d2-signalloom/test/kagent-contract.bats"
  "${REPO_ROOT}/test/kagent-install.bats"
  "${REPO_ROOT}/test/kagent-agents.bats"
  "${REPO_ROOT}/test/kagent-credentials.bats"
  "${REPO_ROOT}/test/kagent-demo-harness.bats"
  "${REPO_ROOT}/test/kagent-adversarial.bats"
  "${REPO_ROOT}/test/kagent-anti-stub.bats"
  "${REPO_ROOT}/test/kagent-infra.bats"
  "${REPO_ROOT}/d2-signalloom/test/kagent-agent-reachability.bats"
)

echo "=== Running Kagent Test Suite ==="

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_SUITES=()

for suite in "${SUITES[@]}"; do
  if [ ! -f "$suite" ]; then
    echo "FATAL: suite not found: $suite" >&2
    echo "A missing suite is a failure, not a skip: a run that quietly omits" >&2
    echo "a file reports the same green as one that passed it." >&2
    exit 1
  fi

  echo ""
  echo "--> Suite: ${suite#"${REPO_ROOT}/"}"
  tap="$(mktemp)"
  bats --tap "$suite" 2>&1 | tee "$tap"
  rc="${PIPESTATUS[0]}"

  pass="$(grep -c '^ok ' "$tap" || true)"
  fail="$(grep -c '^not ok ' "$tap" || true)"
  TOTAL_PASS=$((TOTAL_PASS + pass))
  TOTAL_FAIL=$((TOTAL_FAIL + fail))
  rm -f "$tap"

  if [ "$rc" -ne 0 ] || [ "$fail" -gt 0 ]; then
    FAILED_SUITES+=("${suite#"${REPO_ROOT}/"}")
  fi
done

echo ""
echo "=== Kagent D5 summary: ${TOTAL_PASS} passed, ${TOTAL_FAIL} failed ==="
# Machine-readable line consumed by scripts/kagent-harness-exec.sh so the proof
# artefact records a measured number instead of a literal.
echo "KAGENT_TALLY passed=${TOTAL_PASS} failed=${TOTAL_FAIL}"

if [ "${#FAILED_SUITES[@]}" -gt 0 ]; then
  echo ""
  echo "Failing suites:"
  printf '  %s\n' "${FAILED_SUITES[@]}"
  exit 1
fi

echo "=== All Kagent D5 tests passed. ==="
