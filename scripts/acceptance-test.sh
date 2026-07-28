#!/usr/bin/env bash
# acceptance-test.sh — Run browser-driven acceptance tests against the cluster.
# Sets up port-forwards, runs Playwright tests, cleans up.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="${REPO_ROOT}/test/acceptance"
PF_PIDS=()
PREFLIGHT_FAILED=0

cleanup() {
  echo "==> Cleaning up port-forwards..."
  for pid in "${PF_PIDS[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT

start_port_forward() {
  local ns="$1" svc="$2" local_port="$3" remote_port="$4"
  if ! kubectl get svc "${svc}" -n "${ns}" &>/dev/null; then
    echo "    SKIP: ${ns}/${svc} (service not found)"
    return
  fi
  kubectl port-forward -n "${ns}" "svc/${svc}" "${local_port}:${remote_port}" &>/dev/null &
  PF_PIDS+=($!)
  echo "    ${ns}/${svc} → localhost:${local_port}"
}

# Pre-flight
echo "==> Running cluster doctor..."
"${SCRIPT_DIR}/doctor.sh" 2>&1 | grep -E '━━━|✓|⚠|✗|SUMMARY' | sed 's/\x1b\[[0-9;]*m//g' || true
echo ""

echo "==> Setting up port-forwards..."
if [[ " $* " == *" signalloom-test-1.spec.ts "* ]]; then
  start_port_forward fe-signalloom fe-signalloom 18000 8000
  start_port_forward inf-signalloom dex 15556 5556
  read -r gateway_namespace gateway_service < <(kubectl get service -A \
    -l gateway.envoyproxy.io/owning-gateway-name=cluster \
    -o jsonpath='{.items[0].metadata.namespace} {.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$gateway_service" && -n "$gateway_namespace" ]]; then
    gateway_node_port="$(kubectl -n "$gateway_namespace" get service "$gateway_service" \
      -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || true)"
    gatewayAddress="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
    start_port_forward "$gateway_namespace" "$gateway_service" "${gateway_node_port}" 443
    echo "    gateway: ${gateway_namespace}/${gateway_service} nodePort=${gateway_node_port} address=${gatewayAddress}"
  else
    echo "    SKIP: ingress/cluster Envoy service (service not found)"
    gateway_node_port=""
    gatewayAddress=""
  fi
  dashboard_ready="not-ready"
  if [[ -n "$gateway_node_port" ]]; then
    export DASHBOARD_URL="${DASHBOARD_URL:-https://dashboard.osramp.acme.local:${gateway_node_port}}"
    dashboard_ready="$(curl -kfsS --max-time 5 "${DASHBOARD_URL}/readyz" 2>/dev/null || echo not-ready)"
  else
    export DASHBOARD_URL="${DASHBOARD_URL:-https://dashboard.osramp.acme.local:18443}"
  fi
  if [[ "$dashboard_ready" != "ready" ]]; then
    echo "    WARNING: dashboard readiness check returned: ${dashboard_ready}"
  fi
  export GATEWAY_ADDRESS="${gatewayAddress:-127.0.0.1}"
  export SIGNALLOOM_API_URL="${SIGNALLOOM_API_URL:-$DASHBOARD_URL}"
  export SIGNALLOOM_DEX_URL="${SIGNALLOOM_DEX_URL:-http://127.0.0.1:15556}"
else
  start_port_forward monitoring kube-prometheus-stack-grafana 13000 80
  start_port_forward backend osramp-archivista 18082 8082
  start_port_forward fe-signalloom fe-signalloom 18000 8000
  start_port_forward olly-replica customer-portal 18080 8080
fi

echo "==> Waiting for port-forwards to establish..."
sleep 4

if [[ " $* " == *" signalloom-test-1.spec.ts "* ]]; then
  for pid in "${PF_PIDS[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "    ERROR: TEST-1 port-forward process ${pid} exited" >&2
      PREFLIGHT_FAILED=1
    fi
  done
  if ! curl -kfsS --max-time 3 "${DASHBOARD_URL}/livez" >/dev/null; then
    echo "    ERROR: TEST-1 shared Gateway is not reachable" >&2
    PREFLIGHT_FAILED=1
  fi
  if ! curl -fsS --max-time 3 \
    "${SIGNALLOOM_DEX_URL}/dex/.well-known/openid-configuration" >/dev/null; then
    echo "    ERROR: TEST-1 Dex issuer is not reachable" >&2
    PREFLIGHT_FAILED=1
  fi
fi

# Verify at least one is reachable
if ! curl -s -o /dev/null -w "" http://127.0.0.1:13000/ 2>/dev/null; then
  echo "    WARNING: Grafana port-forward may not be ready yet, continuing..."
fi

echo "==> Running Playwright tests..."
cd "${TEST_DIR}"
set +e
bunx playwright test --config=playwright.config.ts "$@"
EXIT=$?
set -e

if [[ "$PREFLIGHT_FAILED" -ne 0 && "$EXIT" -eq 0 ]]; then
  EXIT=1
fi

if [ "${EXIT}" -eq 0 ]; then
  echo "==> All acceptance tests passed."
else
  echo "==> Some tests failed (exit ${EXIT})."
  echo "    Report: ${TEST_DIR}/playwright-report/index.html"
  echo "    Artifacts: ${TEST_DIR}/test-results/"
  echo "    Inspect a trace: cd ${TEST_DIR} && bunx playwright show-trace test-results/<failed-test>/trace.zip"
fi

exit "${EXIT}"
