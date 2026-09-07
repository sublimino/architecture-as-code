#!/usr/bin/env bats
# test/admission-node-guard.bats — Node capability admission guard verification

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$REPO_ROOT/bin/node-capability-guard"
  PROOF="$REPO_ROOT/docs/signalloom/evidence/admission-guard-proof.json"
}

@test "node-capability-guard binary is built and executable" {
  [ -x "$BIN" ]
}

@test "admission guard rejects unconfined agent pod with 403" {
  [ -f "$PROOF" ]
  run jq -r ".probes.unconfined_rejected.allowed" "$PROOF"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]

  run jq -r ".probes.unconfined_rejected.code" "$PROOF"
  [ "$status" -eq 0 ]
  [ "$output" = "403" ]
}

@test "admission guard admits compliant agent pod with 200" {
  [ -f "$PROOF" ]
  run jq -r ".probes.compliant_admitted.allowed" "$PROOF"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]

  run jq -r ".probes.compliant_admitted.code" "$PROOF"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
}

@test "rejections and admissions metrics incremented" {
  [ -f "$PROOF" ]
  run jq -r ".probes.metrics.node_capability_rejections_total" "$PROOF"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]

  run jq -r ".probes.metrics.node_capability_admissions_total" "$PROOF"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}
