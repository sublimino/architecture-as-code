#!/usr/bin/env bats

# Focused clean-cluster assertions only: Flux reconciliation and the frontend
# deployment's presence.  Portal workflows, identity flows, and policy
# acceptance intentionally remain outside Phase 1.
load '../../d2-osramp-apps/test/lib/detik'

# Shared polling/wait primitives — deadline-bounded exponential backoff with
# jitter, instead of hand-rolled sleep loops.
# shellcheck source=../../scripts/lib/wait.sh
source "${BATS_TEST_DIRNAME}/../../scripts/lib/wait.sh"

DETIK_CLIENT_NAME="kubectl"
DETIK_CLIENT_NAMESPACE="fe-signalloom"

teardown() {
  kubectl -n default delete pod "signalloom-network-denial-${BATS_TEST_NUMBER:-0}" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if [ -n "${GATEWAY_FORWARD_PID:-}" ]; then
    kill "$GATEWAY_FORWARD_PID" >/dev/null 2>&1 || true
  fi
}

@test "Phase 1 Flux tenants are reconciled in a running local cluster" {
  for pair in inf-bao:infra-configs inf-signalloom:infra-configs fe-signalloom:apps; do
    IFS=: read -r namespace name <<<"$pair"
    run kubectl -n "$namespace" wait "kustomization/$name" --for=condition=ready --timeout="${DEMO_WAIT_TIMEOUT:-10m}"
    [ "$status" -eq 0 ]
  done
}

@test "DETIK observes reconciled dashboard and API deployments" {
  run verify "there is 1 deployment named 'fe-signalloom'"
  [ "$status" -eq 0 ]
  run verify "there is 1 deployment named 'dashboard-signalloom'"
  [ "$status" -eq 0 ]
}

@test "DETIK observes dashboard and API Gateway routes" {
  run verify "there is 1 httproute named 'signalloom-dashboard'"
  [ "$status" -eq 0 ]
  run verify "there is 1 httproute named 'signalloom-api'"
  [ "$status" -eq 0 ]
}

@test "Gateway serves dashboard root and reaches authenticated API path" {
  gateway_service="$(kubectl -n ingress get service \
    -l gateway.envoyproxy.io/owning-gateway-name=cluster \
    -o jsonpath='{.items[0].metadata.name}')"
  [ -n "$gateway_service" ]
  kubectl -n ingress port-forward "service/$gateway_service" 18443:443 \
    >"$BATS_TEST_TMPDIR/gateway-port-forward.log" 2>&1 &
  GATEWAY_FORWARD_PID=$!
  # --resolve/--insecure host-override flags aren't expressible via
  # wait_reachable's fixed curl invocation, so this uses the generic
  # backoff primitive directly.
  _wait_retry 10 "gateway https readiness" \
    "curl --noproxy '*' --resolve dashboard.osramp.acme.local:18443:127.0.0.1 --insecure --silent --output /dev/null https://dashboard.osramp.acme.local:18443/" \
    || cat "$BATS_TEST_TMPDIR/gateway-port-forward.log" >&3
  run curl --noproxy '*' --resolve dashboard.osramp.acme.local:18443:127.0.0.1 \
    --insecure --silent --show-error --output /dev/null --write-out '%{http_code}' \
    https://dashboard.osramp.acme.local:18443/
  if [ "$status" -ne 0 ]; then
    cat "$BATS_TEST_TMPDIR/gateway-port-forward.log" >&3
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
  # Probe a real protected API path. /api/agents has Dex auth middleware
  # active; /api/settings is a 404 that fires before auth (not a valid
  # auth-challenge test target).
  run curl --noproxy '*' --resolve dashboard.osramp.acme.local:18443:127.0.0.1 \
    --insecure --silent --show-error --output /dev/null --write-out '%{http_code}' \
    https://dashboard.osramp.acme.local:18443/api/agents
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^(401|403)$ ]]
}

@test "Gateway-only policies deny direct dashboard and API connections" {
  image="$(kubectl -n fe-signalloom get deployment fe-signalloom \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"
  pod="signalloom-network-denial-${BATS_TEST_NUMBER:-0}"
  run kubectl -n default run "$pod" --restart=Never --image="$image" \
    --image-pull-policy=IfNotPresent --command -- \
    python -c 'import socket,sys
targets = (("dashboard-signalloom.fe-signalloom.svc.cluster.local", 8080), ("fe-signalloom-api.fe-signalloom.svc.cluster.local", 8000))
for host, port in targets:
    try:
        socket.create_connection((host, port), 3)
    except OSError as error:
        print(f"DIRECT_DENIED:{host}:{type(error).__name__}")
        continue
    print(f"DIRECT_REACHABLE:{host}")
    sys.exit(1)'
  [ "$status" -eq 0 ]
  run kubectl -n default wait "pod/$pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s
  [ "$status" -eq 0 ]
  run kubectl -n default logs "$pod"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DIRECT_DENIED:dashboard-signalloom.fe-signalloom.svc.cluster.local:"* ]]
  [[ "$output" == *"DIRECT_DENIED:fe-signalloom-api.fe-signalloom.svc.cluster.local:"* ]]
}
