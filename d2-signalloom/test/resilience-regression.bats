#!/usr/bin/env bats

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  tenant_file="$repo_root/d2-osramp-fleet/tenants/local/signalloom.yaml"
  makefile="$repo_root/Makefile"
  push_local="$repo_root/scripts/push-local.sh"
}

@test "RBAC regression guard: signalloom apps tenant keeps Gateway API route grant for flux" {
  # The built-in admin ClusterRole does not cover Gateway API; without this
  # grant the apps Kustomization dies during HTTPRoute dry-run.
  run grep -F 'gateway.networking.k8s.io' "$tenant_file"
  [ "$status" -eq 0 ]

  run grep -F 'httproutes' "$tenant_file"
  [ "$status" -eq 0 ]

  run grep -F 'flux-gateway-routes' "$tenant_file"
  [ "$status" -eq 0 ]
}

@test "Kind-load regression guard F2: signalloom-images loads fe-signalloom into kind" {
  # A prior regression only pushed this image to zot, which left kind unable to
  # resolve the in-cluster registry DNS and caused ErrImagePull.
  run grep -F 'kind load docker-image --name $(CLUSTER_NAME) zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest' "$makefile"
  [ "$status" -eq 0 ]
}

@test "Sign-verify regression guard F4: local push flow verifies cosign signatures" {
  # This catches an unsigned latest-tag race that Flux later refuses to verify.
  run grep -F 'cosign verify' "$push_local"
  [ "$status" -eq 0 ]
}
