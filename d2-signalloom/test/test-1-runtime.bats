#!/usr/bin/env bats

setup() {
  command -v kubectl >/dev/null
  TEST_POD_PREFIX="signalloom-test-1-${BATS_TEST_NUMBER:-0}"
}

teardown() {
  kubectl -n fe-signalloom delete pod "${TEST_POD_PREFIX}-unauthorised" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

service_proxy() {
  local namespace="$1" service="$2" port="$3" path="$4"
  kubectl get --raw \
    "/api/v1/namespaces/${namespace}/services/http:${service}:${port}/proxy${path}"
}

@test "TEST-1 workloads and their declared probes are Ready" {
  run kubectl -n inf-signalloom wait deployment/dex deployment/fake-integration-proxy \
    --for=condition=available --timeout="${DEMO_WAIT_TIMEOUT:-10m}"
  [ "$status" -eq 0 ]
  run kubectl -n fe-signalloom wait deployment/fe-signalloom \
    --for=condition=available --timeout="${DEMO_WAIT_TIMEOUT:-10m}"
  [ "$status" -eq 0 ]
}

@test "TEST-1 Gateway HTTPRoutes are accepted with resolved references" {
  for route in signalloom-dashboard signalloom-api; do
    run kubectl -n fe-signalloom wait "httproute/${route}" \
      --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
      --timeout="${DEMO_WAIT_TIMEOUT:-10m}"
    [ "$status" -eq 0 ]
    run kubectl -n fe-signalloom wait "httproute/${route}" \
      --for=jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}'=True \
      --timeout="${DEMO_WAIT_TIMEOUT:-10m}"
    [ "$status" -eq 0 ]
  done
}

@test "TEST-1 liveness and readiness probes answer through both Services" {
  for service in fe-signalloom fe-signalloom-api; do
    run service_proxy fe-signalloom "$service" 8000 /livez
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"live"'* ]]
    run service_proxy fe-signalloom "$service" 8000 /readyz
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"ready"'* ]]
  done
}

@test "TEST-1 Dex discovery and JWKS endpoints answer live" {
  run service_proxy inf-signalloom dex 5556 /dex/.well-known/openid-configuration
  [ "$status" -eq 0 ]
  [[ "$output" == *'"issuer"'* ]]
  run service_proxy inf-signalloom dex 5556 /dex/keys
  [ "$status" -eq 0 ]
  [[ "$output" == *'"keys"'* ]]
}

@test "TEST-1 NetworkPolicy blocks API external egress" {
  run kubectl -n fe-signalloom get deployment fe-signalloom
  [ "$status" -eq 0 ]
  run kubectl -n fe-signalloom exec deployment/fe-signalloom -- \
    python -c 'import socket; print(socket.__name__)'
  [ "$status" -eq 0 ]
  [[ "$output" == *"socket"* ]]
  run kubectl -n fe-signalloom exec deployment/fe-signalloom -- \
    python -c 'import socket,sys
try:
    socket.create_connection(("example.com", 443), 3)
except OSError as error:
    print(f"EGRESS_DENIED:{type(error).__name__}")
    sys.exit(0)
print("EGRESS_REACHABLE")
sys.exit(1)'
  [ "$status" -eq 0 ]
  [[ "$output" == *"EGRESS_DENIED:"* ]]
}

@test "TEST-1 NetworkPolicy blocks unauthorised persistence access" {
  image="$(kubectl -n fe-signalloom get deployment fe-signalloom \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"
  run kubectl -n fe-signalloom run "${TEST_POD_PREFIX}-unauthorised" \
    --restart=Never --image="$image" --image-pull-policy=IfNotPresent --command -- \
    python -c 'import socket,sys
try:
    socket.create_connection(("postgresql.inf-signalloom.svc.cluster.local", 5432), 3)
except OSError as error:
    print(f"POLICY_DENIED:{type(error).__name__}")
    sys.exit(0)
print("PERSISTENCE_REACHABLE")
sys.exit(1)'
  [ "$status" -eq 0 ]
  run kubectl -n fe-signalloom wait "pod/${TEST_POD_PREFIX}-unauthorised" \
    --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s
  [ "$status" -eq 0 ]
  run kubectl -n fe-signalloom logs "${TEST_POD_PREFIX}-unauthorised"
  [ "$status" -eq 0 ]
  [[ "$output" == *"POLICY_DENIED:"* ]]
}

@test "TEST-1 exposes no persistence Service outside its cluster boundary" {
  for service in postgresql redis minio fake-integration-proxy dex; do
    run kubectl -n inf-signalloom get service "$service" \
      -o jsonpath='{.spec.type}:{.spec.externalName}:{.spec.externalIPs}'
    [ "$status" -eq 0 ]
    [[ "$output" == "ClusterIP::"* ]]
  done
  run kubectl -n fe-signalloom get httproutes.gateway.networking.k8s.io -o yaml
  [ "$status" -eq 0 ]
  [[ "$output" != *"name: postgresql"* ]]
  [[ "$output" != *"name: redis"* ]]
  [[ "$output" != *"name: minio"* ]]
  [[ "$output" != *"name: fake-integration-proxy"* ]]
}
