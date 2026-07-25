#!/usr/bin/env bats

setup() { root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"; }

@test "bounded Bao/SPIRE identity is exact and has a negative service account" {
  run "$root/d2-signalloom/test/validate-bao-spire.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"configuration validates"* ]]
}

@test "all Bao-dependent application proof objects carry the consumer label" {
  run yq -e 'select(.kind == "Job") | .metadata.labels["bao.controlplane.io/consumer"] == "fe-signalloom"' "$root/d2-signalloom/apps/fe-signalloom/base/bao-spire-proof.yaml"
  [ "$status" -eq 0 ]
}
