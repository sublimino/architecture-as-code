#!/usr/bin/env bats

# Focused clean-cluster assertions only: Flux reconciliation and the frontend
# deployment's presence.  Portal workflows, identity flows, and policy
# acceptance intentionally remain outside Phase 1.
load '../../d2-osramp-apps/test/lib/detik'

DETIK_CLIENT_NAME="kubectl"
DETIK_CLIENT_NAMESPACE="fe-signalloom"

@test "Phase 1 Flux tenants are reconciled in a running local cluster" {
  for pair in inf-bao:infra-configs inf-signalloom:infra-configs fe-signalloom:apps; do
    IFS=: read -r namespace name <<<"$pair"
    run kubectl -n "$namespace" wait "kustomization/$name" --for=condition=ready --timeout="${DEMO_WAIT_TIMEOUT:-10m}"
    [ "$status" -eq 0 ]
  done
}

@test "DETIK observes the reconciled frontend deployment" {
  run verify "there is 1 deployment named 'fe-signalloom'"
  [ "$status" -eq 0 ]
}
