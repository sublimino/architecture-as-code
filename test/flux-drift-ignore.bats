#!/usr/bin/env bats
# test/flux-drift-ignore.bats — Verify Flux selective drift ignore capabilities (CRKC-P1-1).
#
# Tests RFC 6901 JSON pointer escaping, declared-and-ignored invariants, field manager
# contracts, and out-of-band stun label survival under forced Flux reconciliations.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
}

@test "RFC 6901 JSON pointer linter passes on all fleet manifests" {
  run "${REPO_ROOT}/scripts/lint-flux-ignore-rfc6901.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"valid RFC 6901"* ]]
}

@test "Dynamic labels and annotations checker passes on all managed paths" {
  run "${REPO_ROOT}/scripts/check-flux-dynamic-labels.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"declared AND covered"* ]]
}

@test "All Kustomization spec.ignore rules use RFC 6901 ~1 escaping for domain-prefixed keys" {
  # Raw unescaped slashes in label/annotation keys under paths: cause silent ignore failures
  run grep -rnE "paths:" -A 10 "${REPO_ROOT}/d2-osramp-fleet"
  [ "$status" -eq 0 ]
  ! grep -rnE "/metadata/(labels|annotations)/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+" "${REPO_ROOT}/d2-osramp-fleet"
}

@test "Fake integration proxy stun handler specifies fieldManager=flux-client-side-apply" {
  local proxy_server="${REPO_ROOT}/d2-signalloom/apps/fake-integration-proxy/server.py"
  [ -f "$proxy_server" ]
  run grep -F 'field_manager: str = "flux-client-side-apply"' "$proxy_server"
  [ "$status" -eq 0 ]
  run grep -F 'fieldManager=' "$proxy_server"
  [ "$status" -eq 0 ]
  run grep -F 'signalloom.io/stunned' "$proxy_server"
  [ "$status" -eq 0 ]
  run grep -F 'signalloom.io/containment-mode' "$proxy_server"
  [ "$status" -eq 0 ]
}

@test "Sentinel stun detector recognizes signalloom.io and signalloom.ai stun markers" {
  local sentinel_main="${REPO_ROOT}/d2-signalloom/apps/signalloom-stun-sentinel/main.go"
  [ -f "$sentinel_main" ]
  run grep -F 'signalloom.io/stunned' "$sentinel_main"
  [ "$status" -eq 0 ]
  run grep -F 'signalloom.io/containment-mode' "$sentinel_main"
  [ "$status" -eq 0 ]
  run grep -F 'signalloom.ai/state' "$sentinel_main"
  [ "$status" -eq 0 ]
}

@test "Lifecycle scripts specify --field-manager=flux-client-side-apply for label and annotation mutations" {
  local scripts=(
    "${REPO_ROOT}/scripts/supercred-demo.sh"
    "${REPO_ROOT}/scripts/supercred-fleet-demo.sh"
    "${REPO_ROOT}/scripts/swarm-fleet-demo.sh"
  )
  for s in "${scripts[@]}"; do
    [ -f "$s" ]
    run grep -F -- "--field-manager=flux-client-side-apply" "$s"
    [ "$status" -eq 0 ]
  done
}

@test "Live Flux reconciliation preserves stun labels and annotations without drift reverts" {
  # Check if live cluster and flux kustomization fe-signalloom/apps are reachable
  if ! kubectl get kustomization apps -n fe-signalloom >/dev/null 2>&1; then
    skip "Flux Kustomization apps in fe-signalloom not found on cluster"
  fi

  local target_deploy="dashboard-signalloom"
  local target_ns="fe-signalloom"

  # Apply stun labels using client-side apply field manager
  kubectl -n "$target_ns" label deployment "$target_deploy" \
    --field-manager=flux-client-side-apply \
    signalloom.io/stunned=true \
    signalloom.io/containment-mode=frozen \
    signalloom.ai/state=stunned --overwrite

  kubectl -n "$target_ns" annotate deployment "$target_deploy" \
    --field-manager=flux-client-side-apply \
    signalloom.io/stun-reason=bats-drift-verification \
    signalloom.ai/stun-reason=bats-drift-verification --overwrite

  # Force Flux reconciliation
  flux reconcile kustomization apps -n "$target_ns" --with-source

  # Assert labels and annotations survived
  local stunned containment state reason
  stunned=$(kubectl -n "$target_ns" get deployment "$target_deploy" -o jsonpath='{.metadata.labels.signalloom\.io/stunned}')
  containment=$(kubectl -n "$target_ns" get deployment "$target_deploy" -o jsonpath='{.metadata.labels.signalloom\.io/containment-mode}')
  state=$(kubectl -n "$target_ns" get deployment "$target_deploy" -o jsonpath='{.metadata.labels.signalloom\.ai/state}')
  reason=$(kubectl -n "$target_ns" get deployment "$target_deploy" -o jsonpath='{.metadata.annotations.signalloom\.io/stun-reason}')

  # Clean up / restore active state before asserting to prevent leaving dirty state on failure
  kubectl -n "$target_ns" label deployment "$target_deploy" \
    --field-manager=flux-client-side-apply \
    signalloom.io/stunned=false \
    signalloom.io/containment-mode=none \
    signalloom.ai/state=active --overwrite

  kubectl -n "$target_ns" annotate deployment "$target_deploy" \
    --field-manager=flux-client-side-apply \
    signalloom.io/stun-reason="" \
    signalloom.ai/stun-reason="" --overwrite

  [ "$stunned" = "true" ]
  [ "$containment" = "frozen" ]
  [ "$state" = "stunned" ]
  [ "$reason" = "bats-drift-verification" ]
}
