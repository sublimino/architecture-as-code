#!/usr/bin/env bats

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
}

@test "Signalloom artifacts are published and signed by local and GitHub matrices" {
  run grep -F 'signalloom/infra/${component}' "$repo_root/scripts/push-local.sh"
  [ "$status" -eq 0 ]
  run grep -F 'signalloom/apps/fe-signalloom' "$repo_root/scripts/push-local.sh"
  [ "$status" -eq 0 ]
  run grep -F 'repository: signalloom/infra/inf-bao' "$repo_root/.github/workflows/push-artifacts.yaml"
  [ "$status" -eq 0 ]
  run grep -F 'repository: signalloom/infra/inf-signalloom' "$repo_root/.github/workflows/push-artifacts.yaml"
  [ "$status" -eq 0 ]
  run grep -F 'repository: signalloom/apps/fe-signalloom' "$repo_root/.github/workflows/push-artifacts.yaml"
  [ "$status" -eq 0 ]
  run grep -F 'image: signalloom/apps/fe-signalloom' "$repo_root/.github/workflows/push-images.yaml"
  [ "$status" -eq 0 ]
  run grep -F 'image: signalloom/infra/fake-integration-proxy' "$repo_root/.github/workflows/push-images.yaml"
  [ "$status" -eq 0 ]
}

@test "local fleet verifies Signalloom OCI artifacts with the local Cosign key" {
  run kubectl kustomize "$repo_root/d2-osramp-fleet/tenants/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: signalloom-infra"* ]]
  [[ "$output" == *"name: signalloom-apps"* ]]
  [ "$(grep -c 'name: cosign-pub' <<<"$output")" -ge 2 ]
}

@test "global waits follow Bao then Signalloom infrastructure then portal" {
  waits="$repo_root/scripts/wait-reconciled.sh"
  bao=$(grep -n 'Kustomization/inf-bao/infra-configs' "$waits" | cut -d: -f1)
  infra=$(grep -n 'Kustomization/inf-signalloom/infra-configs' "$waits" | cut -d: -f1)
  portal=$(grep -n 'Kustomization/fe-signalloom/apps' "$waits" | cut -d: -f1)
  [ -n "$bao" ]
  [ -n "$infra" ]
  [ -n "$portal" ]
  [ "$bao" -lt "$infra" ]
  [ "$infra" -lt "$portal" ]
}
