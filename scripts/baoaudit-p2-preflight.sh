#!/usr/bin/env bash
# scripts/baoaudit-p2-preflight.sh — Phase 2 Preflight verification for BAOAUDIT
set -euo pipefail

echo "=========================================================="
echo " Signal Loom BAOAUDIT Phase 2 Preflight Check"
echo "=========================================================="

FAILURES=0
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 1. Bun & Vitest test runner check
echo -n "[1/4] Checking Bun & Vitest runtime in dashboard-signalloom... "
if (cd "$REPO_ROOT/d2-signalloom/apps/dashboard-signalloom" && bun --version >/dev/null 2>&1); then
    echo "OK (Bun installed)"
else
    echo "FAILED (Bun not found)"
    FAILURES=$((FAILURES + 1))
fi

# 2. Vitest baseline execution
echo -n "[2/4] Running Vitest suite in dashboard-signalloom... "
if (cd "$REPO_ROOT/d2-signalloom/apps/dashboard-signalloom" && bunx vitest run >/dev/null 2>&1); then
    echo "OK (All Vitest tests passing)"
else
    echo "FAILED (Vitest tests failed)"
    FAILURES=$((FAILURES + 1))
fi

# 3. CEL rules package compilation in signal-ingest
echo -n "[3/4] Verifying CEL correlation engine in signal-ingest... "
if (cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest" && go test -v ./correlation/... >/dev/null 2>&1); then
    echo "OK (CEL correlation engine clean)"
else
    echo "FAILED (CEL correlation engine test failed)"
    FAILURES=$((FAILURES + 1))
fi

# 4. Playwright configuration check
echo -n "[4/4] Verifying Playwright config and spec coverage... "
if (cd "$REPO_ROOT" && bats test/acceptance-spec-coverage.bats >/dev/null 2>&1); then
    echo "OK (Acceptance spec coverage 100%)"
else
    echo "FAILED (Acceptance spec coverage failed)"
    FAILURES=$((FAILURES + 1))
fi

echo "----------------------------------------------------------"
if [ "$FAILURES" -eq 0 ]; then
    echo "✅ BAOAUDIT PHASE 2 PREFLIGHT PASSED (All 4 gates satisfied)"
    exit 0
else
    echo "❌ BAOAUDIT PHASE 2 PREFLIGHT FAILED ($FAILURES check(s) failed)"
    exit 1
fi
