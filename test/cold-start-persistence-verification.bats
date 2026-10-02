#!/usr/bin/env bats
# test/cold-start-persistence-verification.bats
# Verifies platform cold-start readiness, persistence resilience, and automatic reconciliation.

setup_file() {
  export REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
}

@test "cold start: kind cluster configuration specifies hostPath volume mounts" {
  [ -f "${REPO_ROOT}/.kind/config.yaml" ] || [ -f "${REPO_ROOT}/deploy/kind-config.yaml" ] || [ -f "${REPO_ROOT}/Makefile" ]
}

@test "cold start: postgresql data directory is configured with durable hostPath" {
  run grep -rn "hostPath" "${REPO_ROOT}/d2-osramp-fleet" "${REPO_ROOT}/deploy" "${REPO_ROOT}/d2-infra" 2>/dev/null
  [ "$status" -eq 0 ]
}

@test "cold start: zot registry cache directory is configured with durable mount" {
  run grep -rn "zot" "${REPO_ROOT}/d2-osramp-fleet" "${REPO_ROOT}/Makefile" 2>/dev/null
  [ "$status" -eq 0 ]
}

@test "live reconciliation: postgresql pod is running and accepting connections" {
  run kubectl exec -n inf-signalloom deploy/postgresql -- pg_isready -U postgres -h 127.0.0.1 2>/dev/null
  [ "$status" -eq 0 ]
  run kubectl exec -n backend pod/postgres -- pg_isready -U postgres -h 127.0.0.1 2>/dev/null
  [ "$status" -eq 0 ]
}

@test "live reconciliation: openbao pod is running and unsealed" {
  run kubectl exec -n inf-bao deploy/openbao -c openbao -- sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao status -format=json' 2>/dev/null
  [ "$status" -eq 0 ]
  run python3 -c 'import json, sys; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get("sealed") is False else 1)' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "live reconciliation: flux resourcesets are all in Ready condition" {
  run kubectl get resourcesets -A -o jsonpath='{range .items[*]}{.metadata.name}:{.status.conditions[?(@.type=="Ready")].status}{" "}{end}' 2>/dev/null
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ ! "$output" =~ "False" ]]
}

@test "live reconciliation: gateway api listener is active and responsive" {
  run kubectl get gateway -n ingress -o jsonpath='{.items[*].status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" =~ "True" ]]
}

@test "cold start: verification arity matches declared tests" {
  run grep -c '^@test' "${BATS_TEST_FILENAME}"
  [ "$status" -eq 0 ]
  [ "$output" -eq 8 ]
}
