#!/usr/bin/env bash
# demo-signalloom-smoke.sh — Rapid (<90s) demo smoke test runner for Signal Loom.
#
# Runs exclusively:
# 1. Fast cluster foundation & ingress health probe.
# 2. User onboarding wizard flow verification.
# 3. Dual-agent discovery, claim & telemetry verification.
#
# Enforces strict wall-clock SLA (< 90 seconds).

set -euo pipefail

export PATH="$HOME/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/snap/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="${REPO_ROOT}/test/acceptance"

START_TIME=$(date +%s)
MAX_RUNTIME_SECONDS=90

PF_PIDS=()

cleanup() {
  if ((${#PF_PIDS[@]} > 0)); then
    echo "==> Cleaning up background port-forwards..."
    for pid in "${PF_PIDS[@]}"; do
      kill "${pid}" 2>/dev/null || true
    done
    wait 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "════════════════════════════════════════════════════════════════════"
echo "  Signal Loom Demo Smoke Test Suite (SLON-P2-4)"
echo "  Target: User Onboarding & Dual-Agent Claim Verification"
echo "  SLA: < 90 seconds"
echo "════════════════════════════════════════════════════════════════════"
echo ""

# ─── 1. Fast Cluster Foundation & Ingress Health Probe ───────────────────────
echo "==> [1/3] Probing cluster foundation & ingress readiness..."

if ! kubectl get nodes &>/dev/null; then
  echo "    ERROR: Kubernetes cluster API is unreachable." >&2
  exit 1
fi
echo "    ✓ Kubernetes API server reachable"

# Discover Envoy Gateway Service
GATEWAY_PORT=30754
GATEWAY_SVC="$(kubectl -n ingress get service -l gateway.envoyproxy.io/owning-gateway-name=cluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "${GATEWAY_SVC}" ]]; then
  echo "    ERROR: Envoy Gateway data-plane service not found in ingress namespace." >&2
  exit 1
fi
echo "    ✓ Ingress Gateway service discovered (${GATEWAY_SVC})"

# Check fe-signalloom backend deployment
if kubectl -n fe-signalloom get deploy/fe-signalloom &>/dev/null; then
  echo "    ✓ fe-signalloom backend deployment present"
else
  echo "    WARNING: fe-signalloom deployment not found in fe-signalloom namespace."
fi

# Check Dex deployment
if kubectl -n inf-signalloom get deploy/dex &>/dev/null; then
  echo "    ✓ Dex OIDC provider deployment present"
fi

# ─── 2. Port-Forward Management & Pre-Flight ────────────────────────────────
echo "==> [2/3] Verifying / establishing gateway & auth endpoints..."

# Check Gateway endpoint (30754)
GATEWAY_READY=0
if curl -kfsS --max-time 2 --resolve "dashboard.osramp.acme.local:${GATEWAY_PORT}:127.0.0.1" \
  "https://dashboard.osramp.acme.local:${GATEWAY_PORT}/livez" &>/dev/null; then
  echo "    ✓ Reusing existing responsive Gateway listener on localhost:${GATEWAY_PORT}"
  GATEWAY_READY=1
else
  # Spawn port-forward if not already listening or unresponsive
  if ! nc -z 127.0.0.1 "${GATEWAY_PORT}" 2>/dev/null; then
    kubectl -n ingress port-forward "svc/${GATEWAY_SVC}" "${GATEWAY_PORT}:443" &>/dev/null &
    PF_PIDS+=($!)
    sleep 2
    if curl -kfsS --max-time 3 --resolve "dashboard.osramp.acme.local:${GATEWAY_PORT}:127.0.0.1" \
      "https://dashboard.osramp.acme.local:${GATEWAY_PORT}/livez" &>/dev/null; then
      echo "    ✓ Established Gateway port-forward on localhost:${GATEWAY_PORT}"
      GATEWAY_READY=1
    fi
  else
    echo "    ✓ Gateway port localhost:${GATEWAY_PORT} bound"
    GATEWAY_READY=1
  fi
fi

# Check Dex endpoint (15556)
if nc -z 127.0.0.1 15556 2>/dev/null; then
  echo "    ✓ Dex listener active on localhost:15556"
else
  if kubectl -n inf-signalloom get svc dex &>/dev/null; then
    kubectl -n inf-signalloom port-forward svc/dex 15556:5556 &>/dev/null &
    PF_PIDS+=($!)
    echo "    ✓ Started Dex port-forward on localhost:15556"
  fi
fi

# Check Backend API endpoint (18000)
if nc -z 127.0.0.1 18000 2>/dev/null; then
  echo "    ✓ Backend API listener active on localhost:18000"
else
  if kubectl -n fe-signalloom get svc fe-signalloom &>/dev/null; then
    kubectl -n fe-signalloom port-forward svc/fe-signalloom 18000:8000 &>/dev/null &
    PF_PIDS+=($!)
    echo "    ✓ Started fe-signalloom port-forward on localhost:18000"
  fi
fi

export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-${REPO_ROOT}/.cache/ms-playwright}"
export PW_CHANNEL="${PW_CHANNEL:-chrome}"
export DASHBOARD_URL="https://dashboard.osramp.acme.local:${GATEWAY_PORT}"
export GATEWAY_ADDRESS="127.0.0.1"
export SIGNALLOOM_API_URL="http://127.0.0.1:18000"
export SIGNALLOOM_DEX_URL="http://127.0.0.1:15556"

# ─── 3. Execute Smoke Test Suite ────────────────────────────────────────────
echo "==> [3/3] Executing Playwright smoke suite (smoke-onboarding-agents.spec.ts)..."
cd "${TEST_DIR}"

if [[ ! -d node_modules/@playwright ]]; then
  echo "    Installing Playwright dependencies..."
  bun install --frozen-lockfile 2>/dev/null || bun install
fi

set +e
bunx playwright test --config=playwright.config.ts smoke-onboarding-agents.spec.ts "$@"
TEST_EXIT=$?
set -e

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Smoke Suite Execution Summary"
echo "  Duration: ${ELAPSED}s (SLA: <${MAX_RUNTIME_SECONDS}s)"
echo "  Exit Code: ${TEST_EXIT}"
echo "════════════════════════════════════════════════════════════════════"

if (( ELAPSED >= MAX_RUNTIME_SECONDS )); then
  echo "❌ SLA VIOLATION: Execution took ${ELAPSED}s, exceeding ${MAX_RUNTIME_SECONDS}s limit." >&2
  exit 1
fi

if [[ "${TEST_EXIT}" -ne 0 ]]; then
  echo "❌ SMOKE SUITE FAILED (exit ${TEST_EXIT})." >&2
  exit "${TEST_EXIT}"
fi

echo "✅ DEMO SMOKE SUITE PASSED in ${ELAPSED}s (strictly under ${MAX_RUNTIME_SECONDS}s SLA)."
exit 0
