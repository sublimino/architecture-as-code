#!/usr/bin/env bash
# audit-invariants.sh — Automated audit runner for Signal Loom silent failure invariants
set -eo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
cd "${REPO_ROOT}"

echo "=== Signal Loom Silent Failure & Invariant Sentinel ==="
DATE_STR=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Audit Timestamp: ${DATE_STR}"
FAIL_COUNT=0

# 1. Route collisions
echo "Checking Route Collisions..."
if [ -f "d2-signalloom/test/dashboard-route-collisions.bats" ]; then
  if bats d2-signalloom/test/dashboard-route-collisions.bats >/dev/null 2>&1; then
    echo "  [PASS] Route collisions: Zero collisions found"
  else
    echo "  [FAIL] Route collisions: Nginx proxy prefix collides with React route"
    echo "  [REMEDIATION] Route collision detected between Nginx proxy routes and React Router:"
    echo "  1. Run 'bats d2-signalloom/test/dashboard-route-collisions.bats' to identify colliding paths."
    echo "  2. Compare proxy location prefixes in d2-signalloom/apps/fe-signalloom/docker/nginx.conf"
    echo "     with client routes in d2-signalloom/apps/dashboard-signalloom/src/App.tsx."
    echo "  3. Fix: Disambiguate prefixes or use exact matching ('location = /exact-path')."
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
else
  echo "  [SKIP] dashboard-route-collisions.bats not found"
fi

# 2. Pool importers direct binding in application source (excluding test files and comments)
echo "Checking Database Pool Import Bindings..."
DIRECT_IMPORTS=$(grep -rn --exclude-dir=tests --exclude-dir=__pycache__ --exclude-dir=node_modules "from api_compat import _get_pool" d2-signalloom/apps/fe-signalloom/src/ 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' || true)
if [ -n "$DIRECT_IMPORTS" ]; then
  echo "  [FAIL] Disallowed direct pool binding detected in application source:"
  echo "$DIRECT_IMPORTS"
  echo "  [REMEDIATION] Direct pool binding detected in application source:"
  echo "  Importing '_get_pool' binds the database pool at module import time, preventing mock injection."
  echo "  Fix: Resolve the pool dynamically via request state ('request.app.state.pool')"
  echo "  or invoke 'api_compat.get_db_pool()' inside handler functions."
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "  [PASS] Pool import bindings: Clean (zero unmockable import-time bindings in app code)"
fi

# 3. Deployment wait condition syntax in executable scripts (case-insensitive, excluding comments)
echo "Checking Deployment wait condition syntax in executable scripts..."
BAD_WAITS=$(grep -rni --exclude-dir=node_modules --exclude-dir=.git "wait.*--for=condition=ready.*deploy" scripts/ d2-signalloom/ 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' || true)
if [ -n "$BAD_WAITS" ]; then
  echo "  [FAIL] Invalid wait condition on deployment in executable code:"
  echo "$BAD_WAITS"
  echo "  [REMEDIATION] Invalid wait condition on deployment detected:"
  echo "  Kubernetes Deployments do NOT have a 'Ready' status condition; '--for=condition=ready' times out indefinitely."
  echo "  Fix: Use 'kubectl rollout status deployment/<name>' or the repository helper"
  echo "  'wait_rollout <namespace> <deployment>' from scripts/lib/wait.sh."
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "  [PASS] Deployment wait commands: Clean (no invalid condition=ready on deployments)"
fi

# 4. CRI Image Layer check if cluster running
echo "Checking CRI Container Image Layers..."
if kubectl cluster-info --request-timeout=2s >/dev/null 2>&1; then
  KIND_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$KIND_NODE" ]; then
    DASHBOARD_CRI=$(docker exec "$KIND_NODE" crictl images 2>/dev/null | grep "dashboard-signalloom" || true)
    if [ -n "$DASHBOARD_CRI" ]; then
      echo "  [PASS] CRI Layers: dashboard-signalloom verified in crictl image store"
    else
      echo "  [INFO] CRI Layers: dashboard-signalloom not yet pulled or loaded into node"
      echo "  [ADVISORY] Load images into Kind node CRI store: 'kind load docker-image localhost:5001/dashboard-signalloom:latest --name osramp'"
    fi
  fi
else
  echo "  [INFO] Cluster offline, skipping CRI check"
fi

echo "=== Invariant Audit Summary ==="
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "RESULT: ALL INVARIANTS PASS"
  exit 0
else
  echo "RESULT: ${FAIL_COUNT} INVARIANT FAILURES DETECTED"
  exit 1
fi
