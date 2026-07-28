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
APP_SRC="${SCRIPT_DIR}/../apps/fe-signalloom/src"
TIER="${1:-contract}"

cd "${APP_SRC}"

PYTEST_ARGS=(-v --tb=short --no-header)

case "${TIER}" in
  contract)
    echo "=== Tier 1: Contract tests (hermetic) ==="
    python3 -m pytest "${PYTEST_ARGS[@]}" tests/test_contract_tier1.py
    ;;

  integration)
    echo "=== Tier 1: Contract tests (hermetic) ==="
    python3 -m pytest "${PYTEST_ARGS[@]}" tests/test_contract_tier1.py

    echo ""
    echo "=== Tier 2: Integration tests (live Postgres) ==="
    if [ -z "${DATABASE_URL:-}" ]; then
      echo "SKIP: DATABASE_URL not set — skipping Tier 2"
    else
      python3 -m pytest "${PYTEST_ARGS[@]}" tests/test_contract_tier2.py
    fi
    ;;

  e2e)
    echo "=== Tier 1: Contract tests (hermetic) ==="
    python3 -m pytest "${PYTEST_ARGS[@]}" tests/test_contract_tier1.py

    echo ""
    echo "=== Tier 2: Integration tests (live Postgres) ==="
    if [ -z "${DATABASE_URL:-}" ]; then
      echo "SKIP: DATABASE_URL not set — skipping Tier 2"
    else
      python3 -m pytest "${PYTEST_ARGS[@]}" tests/test_contract_tier2.py
    fi

    echo ""
    echo "=== Tier 3: End-to-end tests (full cluster) ==="
    if [ -z "${SIGNALLOOM_API_BASE:-}" ]; then
      echo "SKIP: SIGNALLOOM_API_BASE not set — skipping Tier 3"
    else
      python3 -m pytest "${PYTEST_ARGS[@]}" tests/test_e2e_tier3.py
    fi
    ;;

  *)
    echo "Unknown tier: ${TIER}" >&2
    echo "Usage: $0 {contract|integration|e2e}" >&2
    exit 1
    ;;
esac
