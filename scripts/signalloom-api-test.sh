#!/usr/bin/env bash
# signalloom-api-test.sh — Run Signal Loom API contract tests at the chosen tier.
#
# Usage:
#   signalloom-api-test.sh contract      # Tier 1 only (hermetic, fast)
#   signalloom-api-test.sh integration   # Tier 1 + Tier 2 (needs DATABASE_URL)
#   signalloom-api-test.sh e2e           # All three tiers (needs full cluster)
#   signalloom-api-test.sh               # Defaults to 'contract'
#
# Environment variables:
#   DATABASE_URL              — required for Tier 2
#   SIGNALLOOM_API_BASE       — required for Tier 3 (e.g. http://localhost:5173)
#   SIGNALLOOM_DEX_EMAIL      — required for Tier 3
#   SIGNALLOOM_DEX_PASSWORD   — required for Tier 3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SRC="${SCRIPT_DIR}/../d2-signalloom/apps/fe-signalloom/src"
TIER="${1:-contract}"

cd "${APP_SRC}"

PYTEST_ARGS=(-v --tb=short --no-header)

# Pin the interpreter and test dependencies exactly as the TEST-1 gate does
# (scripts/signalloom-test-1.sh stage 2, "API contracts and persistence").
#
# A bare `python3 -m pytest` resolves to whatever is on PATH. On a host whose
# system Python is 3.14 with a current pytest, this suite dies at collection
# with "Marks cannot be applied to fixtures" -- while the same tests pass under
# the pinned 3.12 environment. Two entrypoints running the same tests must not
# disagree about which interpreter they mean.
#
# Override SIGNALLOOM_PYTEST_CMD to run against a preexisting venv instead.
run_pytest() {
  if [ -n "${SIGNALLOOM_PYTEST_CMD:-}" ]; then
    ${SIGNALLOOM_PYTEST_CMD} "$@"
    return
  fi
  if ! command -v uv >/dev/null 2>&1; then
    echo "uv is required to pin the test environment; install uv or set SIGNALLOOM_PYTEST_CMD" >&2
    exit 1
  fi
  uv run --python 3.12 --with pytest --with pytest-asyncio \
    --with-requirements requirements.txt python -m pytest "$@"
}

case "${TIER}" in
  contract)
    echo "=== Tier 1: Contract tests (hermetic) ==="
    run_pytest "${PYTEST_ARGS[@]}" tests/test_contract_tier1.py
    ;;

  integration)
    echo "=== Tier 1: Contract tests (hermetic) ==="
    run_pytest "${PYTEST_ARGS[@]}" tests/test_contract_tier1.py

    echo ""
    echo "=== Tier 2: Integration tests (live Postgres) ==="
    if [ -z "${DATABASE_URL:-}" ]; then
      echo "SKIP: DATABASE_URL not set — skipping Tier 2"
    else
      run_pytest "${PYTEST_ARGS[@]}" tests/test_contract_tier2.py
    fi
    ;;

  e2e)
    echo "=== Tier 1: Contract tests (hermetic) ==="
    run_pytest "${PYTEST_ARGS[@]}" tests/test_contract_tier1.py

    echo ""
    echo "=== Tier 2: Integration tests (live Postgres) ==="
    if [ -z "${DATABASE_URL:-}" ]; then
      echo "SKIP: DATABASE_URL not set — skipping Tier 2"
    else
      run_pytest "${PYTEST_ARGS[@]}" tests/test_contract_tier2.py
    fi

    echo ""
    echo "=== Tier 3: End-to-end tests (full cluster) ==="
    if [ -z "${SIGNALLOOM_API_BASE:-}" ]; then
      echo "SKIP: SIGNALLOOM_API_BASE not set — skipping Tier 3"
    else
      run_pytest "${PYTEST_ARGS[@]}" tests/test_e2e_tier3.py
    fi
    ;;

  *)
    echo "Unknown tier: ${TIER}" >&2
    echo "Usage: $0 {contract|integration|e2e}" >&2
    exit 1
    ;;
esac
