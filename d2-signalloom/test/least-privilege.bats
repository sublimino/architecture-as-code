#!/usr/bin/env bats

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  canonical="$repo_root/d2-signalloom/fleet/local/signalloom.yaml"
  active="$repo_root/d2-osramp-fleet/tenants/local/signalloom.yaml"
}

@test "all Signalloom Flux tenants are namespace-bound and source-policy tenants" {
  run cmp --silent "$canonical" "$active"
  [ "$status" -eq 0 ]

  run grep -E 'kind: (ClusterRoleBinding)|name: cluster-admin' "$canonical"
  [ "$status" -ne 0 ]

  run grep -c 'toolkit.fluxcd.io/role: tenant' "$canonical"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]

  run grep -c 'automountServiceAccountToken: false' "$canonical"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "default-deny policies retain only the declared Signalloom paths" {
  run kubectl kustomize "$repo_root/d2-signalloom/apps/fe-signalloom/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: default-deny"* ]]
  [[ "$output" == *"name: allow-portal-dependencies"* ]]
  [[ "$output" == *"port: 5432"* ]]
  [[ "$output" == *"port: 6379"* ]]
  [[ "$output" == *"port: 9000"* ]]
  [[ "$output" == *"port: 8200"* ]]

  run kubectl kustomize "$repo_root/d2-signalloom/infra/inf-bao/configs/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: allow-bao-spire-and-portal"* ]]

  run kubectl kustomize "$repo_root/d2-signalloom/infra/inf-signalloom/configs/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: allow-dependency-traffic"* ]]
}

@test "positive and negative Bao proofs are distinct service-account outcomes" {
  proof="$repo_root/d2-signalloom/apps/fe-signalloom/base/bao-spire-proof.yaml"
  runner="$repo_root/scripts/bao-spire-proof.sh"

  run grep -F 'serviceAccountName: fe-signalloom' "$proof"
  [ "$status" -eq 0 ]
  run grep -F 'serviceAccountName: fe-signalloom-negative' "$proof"
  [ "$status" -eq 0 ]
  run grep -F 'bounded Bao/SPIRE proof passed' "$proof"
  [ "$status" -eq 0 ]
  run grep -F 'denied as expected' "$proof"
  [ "$status" -eq 0 ]
  run grep -F 'condition=failed' "$runner"
  [ "$status" -eq 0 ]
}
