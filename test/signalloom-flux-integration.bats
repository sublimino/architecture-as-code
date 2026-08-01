#!/usr/bin/env bats

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
}

@test "Signalloom artifacts are published and signed by local and GitHub matrices" {
  run grep -F 'signalloom/infra/inf-bao' "$repo_root/scripts/push-local.sh"
  [ "$status" -eq 0 ]
  run grep -F 'signalloom/infra/inf-signalloom' "$repo_root/scripts/push-local.sh"
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
  # The tenants/local kustomization references ../base which kustomize rejects
  # outside the OCI artifact context. Assert the cosign-pub verification patch
  # is present in the local overlay directly.
  local kustomization="$repo_root/d2-osramp-fleet/tenants/local/kustomization.yaml"
  run grep -F 'cosign-pub' "$kustomization"
  [ "$status" -eq 0 ]
  count="$(grep -c 'cosign-pub' "$kustomization")"
  [ "$count" -ge 6 ]
  # The signalloom ResourceSets reference their infra/apps components
  run grep -F 'signalloom-infra' "$kustomization"
  [ "$status" -eq 0 ]
  run grep -F 'signalloom-apps' "$kustomization"
  [ "$status" -eq 0 ]
}

@test "global wait excludes every opt-in Signalloom resource" {
  waits="$repo_root/scripts/wait-reconciled.sh"
  grep -Fq 'ResourceSet/flux-system/infra' "$waits"
  ! grep -Fq 'ResourceSet/flux-system/signalloom-infra' "$waits"
  ! grep -Fq 'ResourceSet/flux-system/signalloom-apps' "$waits"
  ! grep -Fq 'Kustomization/inf-bao/infra-configs' "$waits"
  ! grep -Fq 'Kustomization/inf-signalloom/infra-configs' "$waits"
  ! grep -Fq 'Kustomization/fe-signalloom/apps' "$waits"
}

@test "local foundation keeps observability sources for the optional profile" {
  infra="$repo_root/d2-osramp-fleet/tenants/base/infra.yaml"
  waits="$repo_root/scripts/wait-reconciled.sh"

  grep -Fq 'tenant: "monitoring"' "$infra"
  grep -Fq 'tenant: "trivy-system"' "$infra"
  grep -Fq 'ENABLE_OBSERVABILITY' "$waits"
  [ -d "$repo_root/d2-infra/components/monitoring" ]
  [ -d "$repo_root/d2-infra/components/trivy-system" ]
}

@test "optional observability profile changes only the generated fleet artifact" {
  push="$repo_root/scripts/push-local.sh"

  grep -Fq 'ENABLE_OBSERVABILITY="${ENABLE_OBSERVABILITY:-true}"' "$push"
  grep -Fq 'TEMP_FLEET_DIR="$(mktemp -d)"' "$push"
  grep -Fq 'infra/monitoring|d2-infra/components/monitoring' "$push"
  grep -Fq 'infra/trivy-system|d2-infra/components/trivy-system' "$push"
}

@test "observability flag controls reconciliation waits" {
  waits="$repo_root/scripts/wait-reconciled.sh"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat >"$bin/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
SCRIPT
  chmod +x "$bin/kubectl"

  run env PATH="$bin:$PATH" ENABLE_OBSERVABILITY=true "$waits"
  [ "$status" -eq 0 ]
  [[ "$output" == *'waiting for Kustomization/infra-controllers in monitoring'* ]]
  [[ "$output" == *'waiting for Kustomization/infra-configs in trivy-system'* ]]

  run env PATH="$bin:$PATH" ENABLE_OBSERVABILITY=false "$waits"
  [ "$status" -eq 0 ]
  [[ "$output" != *'in monitoring'* ]]
  [[ "$output" != *'in trivy-system'* ]]
}

@test "Signalloom apps recreates immutable proof Jobs during Flux reconciliation" {
  manifest="$repo_root/d2-osramp-fleet/tenants/local/signalloom.yaml"
  run yq -e 'select(.kind == "ResourceSet" and .metadata.name == "signalloom-apps") | .spec.resources[] | select(.kind == "Kustomization" and .metadata.name == "apps") | .spec.force == true' "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}
