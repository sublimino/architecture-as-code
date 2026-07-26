#!/usr/bin/env bash
# acceptance-test.sh — Run browser-driven acceptance tests against the cluster.
# Sets up port-forwards, runs Playwright tests, cleans up.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="${REPO_ROOT}/test/acceptance"
PF_PIDS=()

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
start_port_forward monitoring kube-prometheus-stack-grafana 13000 80
start_port_forward backend osramp-archivista 18082 8082
start_port_forward fe-signalloom fe-signalloom 18000 8000
start_port_forward olly-replica customer-portal 18080 8080

echo "==> Waiting for port-forwards to establish..."
sleep 4

# Verify at least one is reachable
if ! curl -s -o /dev/null -w "" http://127.0.0.1:13000/ 2>/dev/null; then
  echo "    WARNING: Grafana port-forward may not be ready yet, continuing..."
fi

echo "==> Running Playwright tests..."
cd "${TEST_DIR}"
bunx playwright test --config=playwright.config.ts "$@"
EXIT=$?

if [ "${EXIT}" -eq 0 ]; then
  echo "==> All acceptance tests passed."
else
  echo "==> Some tests failed (exit ${EXIT})."
  echo "    Report: ${TEST_DIR}/playwright-report/index.html"
fi

exit "${EXIT}"
