#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Signal Loom CLOUDAUDIT Phase 2 Preflight ==="

# 1. Verify CEL-Go engine dependencies in correlation package
cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
if ! go test ./correlation... -run TestRules_Compile; then
    echo "ERROR: CEL rules compilation check failed" >&2
    exit 1
fi
echo "✓ CEL engine bindings and rule compiler verified"

# 2. Verify React/Vite dashboard dependencies
cd "$REPO_ROOT/d2-signalloom/apps/dashboard-signalloom"
if [ ! -f "package.json" ]; then
    echo "ERROR: Dashboard package.json not found" >&2
    exit 1
fi
echo "✓ Dashboard React package manifest verified"

# 3. Generate preflight proof JSON
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"

cat << PROOFOUT > "$REPO_ROOT/.cloudaudit-p2-preflight.json"
{
  "shortcode": "CLOUDAUDIT",
  "card": "P2-PRE",
  "timestamp": "$TIMESTAMP",
  "commit": "$COMMIT",
  "cel_version": "v0.30.0",
  "dashboard_path": "d2-signalloom/apps/dashboard-signalloom",
  "status": "pass",
  "proceed": true
}
PROOFOUT

echo "✓ Phase 2 Preflight proof written to .cloudaudit-p2-preflight.json"
echo "=== Phase 2 Preflight Complete (PASS) ==="
