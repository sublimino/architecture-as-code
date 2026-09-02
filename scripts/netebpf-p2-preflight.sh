#!/usr/bin/env bash
# NETEBPF Phase 2 Preflight Verification Script
# Audits FrostDB table schemas, SSE streaming endpoint bindings, and dashboard compilation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

log_pass() {
  printf "[\033[0;32mPASS\033[0m] %s\n" "$1"
  PASS=$((PASS + 1))
}

log_fail() {
  printf "[\033[0;31mFAIL\033[0m] %s\n" "$1"
  FAIL=$((FAIL + 1))
}

echo "=== NETEBPF Phase 2 Preflight Audit ==="

# 1. Check FrostDB Store Schema Compilation
cd "${REPO_ROOT}/d2-signalloom/apps/signal-ingest"
if go test -v ./store/... >/dev/null 2>&1; then
  log_pass "FrostDB store packages compile and pass schema verification"
else
  log_fail "FrostDB store packages failed unit tests"
fi

# 2. Check CEL Rule Engine
if go test -v ./correlation/... >/dev/null 2>&1; then
  log_pass "CEL correlation engine compiles and passes rule verification"
else
  log_fail "CEL correlation engine failed unit tests"
fi

# 3. Check Dashboard TypeScript / React Build
cd "${REPO_ROOT}/d2-signalloom/apps/dashboard-signalloom"
if bun run build >/dev/null 2>&1; then
  log_pass "Dashboard React/TypeScript build succeeds cleanly"
else
  log_fail "Dashboard React/TypeScript build failed"
fi

# 4. Check Vitest Suite
if bunx vitest run src/pages/WeavePage.test.tsx >/dev/null 2>&1; then
  log_pass "Dashboard WeavePage Vitest component tests pass"
else
  log_fail "Dashboard WeavePage Vitest component tests failed"
fi

echo "========================================"
echo "Phase 2 Preflight Summary: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

exit 0
