#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
}

@test "SUPERCRED SPIRE failures name the supported identity recovery target" {
  local script
  for script in supercred-demo.sh supercred-fleet-demo.sh; do
    grep -F 'SPIRE agent not ready' "$root/scripts/$script" | grep -Fq 'make demo-bao-up'
  done
}

@test "SUPERCRED SPIRE failure does not assert an unobserved token cause" {
  run grep -F 'SPIRE agent not ready — the agent needs a valid join token' \
    "$root/scripts/supercred-demo.sh"
  [ "$status" -ne 0 ]
}
