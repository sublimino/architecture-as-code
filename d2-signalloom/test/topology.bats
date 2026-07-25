#!/usr/bin/env bats

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
}

@test "split-ready Signalloom topology validates without a control-plane bootstrap" {
  run "$repo_root/d2-signalloom/test/validate-topology.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"topology validation passed"* ]]
}

@test "active local fleet composes the canonical Signalloom ResourceSet source" {
  run cmp --silent \
    "$repo_root/d2-signalloom/fleet/local/signalloom.yaml" \
    "$repo_root/d2-osramp-fleet/tenants/local/signalloom.yaml"
  [ "$status" -eq 0 ]
}
