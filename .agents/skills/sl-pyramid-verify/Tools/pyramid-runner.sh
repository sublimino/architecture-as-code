#!/usr/bin/env bash
# pyramid-runner.sh — Execute offline test pyramid battery for Signal Loom
set -eo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
cd "${REPO_ROOT}"

echo "=== Signal Loom Offline Test Pyramid Runner ==="
DATE_STR=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Run Timestamp: ${DATE_STR}"
FAIL_COUNT=0

START_TIME=$(date +%s)

# 1. Living Docs & Index Lint
echo "--> [Tier 1/6] Running Signal Loom documentation lint..."
if ./scripts/docs-lint.sh docs/README.md docs/signalloom/scheduled-skills.md; then
  echo "  [PASS] Signal Loom documentation clean and indexed"
else
  echo "  [FAIL] Signal Loom documentation lint failed."
  echo "  [REMEDIATION] Run 'make docs-lint' to inspect link, anchor, or path errors."
  echo "  Ensure docs/signalloom/scheduled-skills.md is correctly indexed in docs/README.md."
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 2. Database Schema & Dependency Drift (discovery-portal-bootstrap.sql)
echo "--> [Tier 2/6] Auditing database schema and bootstrap SQL alignment..."
if bash d2-signalloom/test/validate-dependencies.sh; then
  echo "  [PASS] Zero schema drift between initdb migrations and bootstrap SQL"
else
  echo "  [FAIL] Schema drift detected between migrations and bootstrap SQL."
  echo "  [REMEDIATION] Run 'bash d2-signalloom/test/validate-dependencies.sh' to inspect diffs."
  echo "  Update d2-signalloom/apps/fe-signalloom/sql/discovery-portal-bootstrap.sql to match"
  echo "  schema changes in d2-signalloom/apps/fe-signalloom/migrations/."
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 3. Go Controller Unit Tests
echo "--> [Tier 3/6] Running Go unit tests for Fleet Manager..."
if (cd d2-signalloom/apps/fleet-manager && GOPATH=/tmp/gopath GOTOOLCHAIN=auto GONOSUMDB=* GOCACHE=/tmp/gocache CGO_ENABLED=0 go test ./...); then
  echo "  [PASS] Fleet Manager controller tests pass"
else
  echo "  [FAIL] Fleet Manager controller tests failed."
  echo "  [REMEDIATION] Inspect Go test failures: '(cd d2-signalloom/apps/fleet-manager && go test -v ./...)'."
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 4. FastAPI Python Contract & Invariant Tests
echo "--> [Tier 4/6] Running FastAPI Python contract tests..."
if (cd d2-signalloom/apps/fe-signalloom/src && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with respx --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -q --disable-warnings); then
  echo "  [PASS] FastAPI contract suites pass"
else
  echo "  [FAIL] FastAPI contract suites failed."
  echo "  [REMEDIATION] Inspect Python contract test failures:"
  echo "  '(cd d2-signalloom/apps/fe-signalloom/src && uv run --with pytest -m pytest tests/test_api_compat.py -vv)'."
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 5. Host Sensor & Confinement Unit Tests
echo "--> [Tier 5/6] Running AgentMaxxing Host Sensor unit tests..."
if (cd d2-signalloom/apps/agentmaxxing-host-sensor && python3 -m unittest test_transcript_parser.py -q); then
  echo "  [PASS] Host Sensor transcript and invariant tests pass"
else
  echo "  [FAIL] Host Sensor transcript and invariant tests failed."
  echo "  [REMEDIATION] Inspect Host Sensor test failures:"
  echo "  '(cd d2-signalloom/apps/agentmaxxing-host-sensor && python3 -m unittest test_transcript_parser.py -v)'."
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 6. Frontend Vitest Suites
echo "--> [Tier 6/6] Running Dashboard Vitest suites..."
if (cd d2-signalloom/apps/dashboard-signalloom && bun run test -- --run src/auth/superadmin.test.ts src/api/fleetApi.stun.test.ts src/components/trust/trustTopology.test.ts); then
  echo "  [PASS] Frontend Vitest suites pass"
else
  echo "  [FAIL] Frontend Vitest suites failed."
  echo "  [REMEDIATION] Inspect Vitest failures:"
  echo "  '(cd d2-signalloom/apps/dashboard-signalloom && bun run test -- --run)'."
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "=== Offline Test Pyramid Summary ==="
echo "Total Duration: ${DURATION}s"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "Status: ${FAIL_COUNT} TIER(S) FAILED"
  exit 1
else
  echo "Status: 100% PASS (Zero regressions, zero schema drift)"
  exit 0
fi
