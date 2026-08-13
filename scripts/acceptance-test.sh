#!/usr/bin/env bash
# acceptance-test.sh — Run browser-driven acceptance tests against the cluster.
# Sets up port-forwards, runs Playwright tests, cleans up.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="${REPO_ROOT}/test/acceptance"
# shellcheck source=scripts/lib/wait.sh
source "${SCRIPT_DIR}/lib/wait.sh"
PF_PIDS=()
# "namespace/service" for every forward that is actually listening — whether we
# started it or reused an existing listener. Preflight asserts against THIS,
# not against a spec name: we check the health of what we established, so a
# check can neither be skipped for a spec that needs it nor fire for a slice
# that was never deployed.
PF_ENDPOINTS=()
PREFLIGHT_FAILED=0

pf_established() {
  local needle="$1" endpoint
  for endpoint in ${PF_ENDPOINTS[@]+"${PF_ENDPOINTS[@]}"}; do
    [[ "${endpoint}" == "${needle}" ]] && return 0
  done
  return 1
}

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
  if nc -z 127.0.0.1 "${local_port}" 2>/dev/null; then
    echo "    ${ns}/${svc} → reusing existing listener on localhost:${local_port}"
    PF_ENDPOINTS+=("${ns}/${svc}")
    return
  fi
  kubectl port-forward -n "${ns}" "svc/${svc}" "${local_port}:${remote_port}" &>/dev/null &
  PF_PIDS+=($!)
  PF_ENDPOINTS+=("${ns}/${svc}")
  echo "    ${ns}/${svc} → localhost:${local_port}"
}

# Pre-flight
echo "==> Running cluster doctor..."
"${SCRIPT_DIR}/doctor.sh" 2>&1 | grep -E '━━━|✓|⚠|✗|SUMMARY' | sed 's/\x1b\[[0-9;]*m//g' || true
echo ""

# The Envoy Gateway forward is required by EVERY spec that authenticates through
# Dex — auth.setup.ts navigates to DASHBOARD_URL regardless of which specs were
# selected. Keeping this inside the TEST-1 branch meant a bare `make
# acceptance-test` got ERR_CONNECTION_REFUSED on the auth setup project and
# cascaded into every dependent spec, so it is hoisted into a shared function.
setup_gateway_forward() {
  gateway_local_port=18443
  read -r gateway_namespace gateway_service < <(kubectl get service -A \
    -l gateway.envoyproxy.io/owning-gateway-name=cluster \
    -o jsonpath='{.items[0].metadata.namespace} {.items[0].metadata.name}' 2>/dev/null || true)
  gateway_forwarded=0
  if [[ -n "$gateway_service" && -n "$gateway_namespace" ]]; then
    gateway_forwarded=1
    # Dex pins its local issuer and callback client to this stable port. Forward
    # the dynamic NodePort here rather than exposing that ephemeral port to the
    # browser, otherwise Dex rejects the OIDC redirect URI.
    gateway_local_port=30754
    gateway_node_port="$(kubectl -n "$gateway_namespace" get service "$gateway_service" \
      -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || true)"
    gatewayAddress="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
    start_port_forward "$gateway_namespace" "$gateway_service" "${gateway_local_port}" 443
    echo "    gateway: ${gateway_namespace}/${gateway_service} nodePort=${gateway_node_port} localPort=${gateway_local_port} address=${gatewayAddress}"
  else
    echo "    SKIP: ingress/cluster Envoy service (service not found)"
    gateway_node_port=""
    gatewayAddress=""
  fi
  # The Gateway requires SNI hostname *.osramp.acme.local — Chrome's
  # --host-resolver-rules (in playwright.config.ts) resolves it to 127.0.0.1.
  export DASHBOARD_URL="${DASHBOARD_URL:-https://dashboard.osramp.acme.local:${gateway_local_port}}"
  # start_port_forward backgrounds kubectl and returns immediately, so without
  # this the readiness probe below raced a port-forward that had had zero time to
  # bind, and `|| echo not-ready` swallowed the race into a warning. The generic
  # `sleep 4` further down fires ~20 lines too late to help here. TCP-level, so
  # no --resolve is needed: the SNI name only matters once TLS starts.
  wait_tcp 127.0.0.1 "${gateway_local_port}" 60 || \
    echo "    WARNING: gateway port-forward never accepted on ${gateway_local_port}"
  dashboard_ready="$(curl -kfsS --max-time 5 --resolve "dashboard.osramp.acme.local:${gateway_local_port}:127.0.0.1" "${DASHBOARD_URL}/readyz" 2>/dev/null || echo not-ready)"
  if [[ "$dashboard_ready" != "ready" ]]; then
    echo "    WARNING: dashboard readiness check returned: ${dashboard_ready}"
  fi
  export GATEWAY_ADDRESS="127.0.0.1"
}

echo "==> Setting up port-forwards..."
# The ONE thing that is legitimately specific to signalloom-test-1.spec.ts: the
# narrowed forward SET. TEST-1 is the slice-isolation harness — it exists to
# prove the signalloom slice stands up without the rest of the estate, so
# forwarding olly-replica / archivista / grafana for it would let a cross-slice
# dependency pass unnoticed. test/signalloom-test-1-harness.bats enforces that
# exclusion. Nothing else below may branch on a spec name.
if [[ " $* " == *" signalloom-test-1.spec.ts "* ]]; then
  start_port_forward fe-signalloom fe-signalloom 18000 8000
  start_port_forward inf-signalloom dex 15556 5556
else
  start_port_forward monitoring kube-prometheus-stack-grafana 13000 80
  start_port_forward backend osramp-archivista 18082 8082
  start_port_forward fe-signalloom fe-signalloom 18000 8000
  start_port_forward olly-replica customer-portal 18080 8080
  start_port_forward inf-signalloom dex 15556 5556
fi

# Everything from here to the end of preflight is a requirement of the SUITE,
# not of one spec, so it runs for every invocation.
#
# The Gateway forward was already hoisted into setup_gateway_forward for exactly
# this reason (see its comment above), but the two exports below were left
# behind inside the TEST-1 branch even though BOTH branches create the forwards
# that back them — every other spec got fe-signalloom:18000 and dex:15556 stood
# up and then was told nothing about them. Deriving these from the forwards we
# just made, rather than from argv, keeps them true by construction.
setup_gateway_forward
export SIGNALLOOM_API_URL="${SIGNALLOOM_API_URL:-http://127.0.0.1:18000}"
export SIGNALLOOM_DEX_URL="${SIGNALLOOM_DEX_URL:-http://127.0.0.1:15556}"

echo "==> Waiting for port-forwards to establish..."
sleep 4

echo "==> Preflight..."
# These preconditions were gated on the TEST-1 spec name, which meant every
# other spec ran with NO preflight at all: a Gateway that never came up surfaced
# 30s later as net::ERR_* inside a browser assertion, naming the wrong component.
# They are suite-wide preconditions — auth.setup.ts and helpers.ts login() both
# navigate to DASHBOARD_URL — so they are asserted for every invocation, and
# each is guarded by whether its own forward was actually established rather
# than by which spec asked.
for pid in ${PF_PIDS[@]+"${PF_PIDS[@]}"}; do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "    ERROR: port-forward process ${pid} exited" >&2
    PREFLIGHT_FAILED=1
  fi
done

# Same --resolve as the readiness probe above: dashboard.osramp.acme.local is an
# SNI-only name with no DNS record and no /etc/hosts entry (by design — the
# browser side resolves it via Chrome's --host-resolver-rules). Without it this
# curl fails with "(6) Could not resolve host" and wrongly reports the Gateway
# as unreachable, setting PREFLIGHT_FAILED on an otherwise healthy cluster.
if (( gateway_forwarded )); then
  if ! curl -kfsS --max-time 3 \
    --resolve "dashboard.osramp.acme.local:${gateway_local_port}:127.0.0.1" \
    "${DASHBOARD_URL}/livez" >/dev/null; then
    echo "    ERROR: shared Gateway is not reachable at ${DASHBOARD_URL}" >&2
    PREFLIGHT_FAILED=1
  fi
else
  echo "    SKIP: Gateway preflight (no Envoy data-plane Service in cluster)"
fi

if pf_established inf-signalloom/dex; then
  if ! curl -fsS --max-time 3 \
    "${SIGNALLOOM_DEX_URL}/dex/.well-known/openid-configuration" >/dev/null; then
    echo "    ERROR: Dex issuer is not reachable at ${SIGNALLOOM_DEX_URL}" >&2
    PREFLIGHT_FAILED=1
  fi
else
  echo "    SKIP: Dex issuer preflight (inf-signalloom/dex not deployed)"
fi

# Advisory only — Grafana backs no assertion in any spec. Gated on the forward
# existing so a run that never asked for it stops emitting a warning about a
# port-forward it deliberately did not make.
if pf_established monitoring/kube-prometheus-stack-grafana; then
  if ! curl -s -o /dev/null -w "" http://127.0.0.1:13000/ 2>/dev/null; then
    echo "    WARNING: Grafana port-forward may not be ready yet, continuing..."
  fi
fi

echo "==> Running Playwright tests..."
cd "${TEST_DIR}"
# Ensure node_modules are installed (bunx playwright requires @playwright/test)
if [[ ! -d node_modules/@playwright ]]; then
  echo "    Installing Playwright dependencies..."
  bun install --frozen-lockfile 2>/dev/null || bun install
fi
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
