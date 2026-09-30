#!/usr/bin/env bash
# scripts/test-crkc-phase2-governor.sh (CRKC P2 suite; also reachable as scripts/test-phase2-governor.sh --crkc)
# Phase 2 Governor Unified Verification Runner
# Validates OpenFAIR calculation accuracy, zero divergence, demo toggle parity,
# systemd port-forward stability, currency formatting, and Prometheus metrics.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export GOPATH="${GOPATH:-/tmp/gopath}"
export GOCACHE="${GOCACHE:-/tmp/gocache}"
export GOMODCACHE="${GOMODCACHE:-/tmp/gopath/pkg/mod}"
mkdir -p "$GOPATH" "$GOCACHE" "$GOMODCACHE"

echo "=========================================================="
echo "  CRKC Phase 2 Governor Unified Verification Suite"
echo "  Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "=========================================================="

echo ""
echo "--- 1. Building tools/riskctl CLI Binary ---"
make -C "$REPO_ROOT" riskctl

echo ""
echo "--- 2. Executing Go OpenFAIR Mathematical Test Suites ---"
(cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest" && go test -v ./pkg/fair/...)
(cd "$REPO_ROOT/d2-signalloom/apps/policy-engine" && go test -v ./fair/...)
(cd "$REPO_ROOT/d2-signalloom/cmd/riskctl" && go test -v ./...)
(cd "$REPO_ROOT/tools/riskctl" && go test ./...)

echo ""
echo "--- 3. Executing Durable Systemd Port-Forward Test Suite ---"
bats "$REPO_ROOT/test/signalloom-portforward.bats"

echo ""
echo "--- 4. Executing Dashboard React / Vitest Suite ---"
(cd "$REPO_ROOT/d2-signalloom/apps/dashboard-signalloom" && bun run test --run)

echo ""
echo "--- 5. Executing Phase 2 FAIR API Parity BATS Suite ---"
bats "$REPO_ROOT/test/fair-api-parity.bats"

echo ""
echo "=========================================================="
echo "  Phase 2 Governor Verification PASSED (100% Green)"
echo "=========================================================="
