#!/usr/bin/env bash
# scripts/test-phase3-governor.sh
# Phase 3 Governor Unified Verification Runner
# Validates Rule SP-1 (Worktree Landlock Confinement), Rule SP-2 (Node Capability Guard),
# and Rule SP-4 (Declarative CEL Compiler) across unit, integration, and red-team suites.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export GOPATH="${GOPATH:-/tmp/gopath}"
export GOCACHE="${GOCACHE:-/tmp/gocache}"
export GOMODCACHE="${GOMODCACHE:-/tmp/gopath/pkg/mod}"
export CGO_ENABLED=0
mkdir -p "$GOPATH" "$GOCACHE" "$GOMODCACHE"

echo "=========================================================="
echo "  CRKC Phase 3 Governor Unified Verification Suite"
echo "  Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "=========================================================="

echo ""
echo "--- 1. Building Policy Compiler & Node Capability Guard Binaries ---"
mkdir -p "$REPO_ROOT/bin"
(cd "$REPO_ROOT/d2-signalloom/cmd/policy-compiler" && go build -o "$REPO_ROOT/bin/policy-compiler" .)
(cd "$REPO_ROOT/d2-signalloom/apps/node-capability-guard/cmd" && go build -o "$REPO_ROOT/bin/node-capability-guard" .)

echo ""
echo "--- 2. Executing Go Security & Policy Engine Test Suites ---"
(cd "$REPO_ROOT/d2-signalloom/pkg/policy" && go test -v ./...)
(cd "$REPO_ROOT/d2-signalloom/apps/node-capability-guard" && go test -v ./...)

echo ""
echo "--- 3. Executing Declarative Policy Compiler BATS Suite ---"
bats "$REPO_ROOT/test/policy-compiler.bats"

echo ""
echo "--- 4. Executing Worktree Landlock Confinement BATS Suite ---"
bats "$REPO_ROOT/test/worktree-landlock-confinement.bats"

echo ""
echo "--- 5. Executing Node Capability Admission Guard BATS Suite ---"
bats "$REPO_ROOT/test/admission-node-guard.bats"

echo ""
echo "--- 6. Executing Phase 3 Adversarial Red-Team BATS Suite ---"
bats "$REPO_ROOT/test/crkc-phase3-confinement-redteam.bats"

echo ""
echo "=========================================================="
echo "  Phase 3 Governor Verification PASSED (100% Green)"
echo "=========================================================="
