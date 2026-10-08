#!/usr/bin/env bats
# test/slaws-slaat-cross-plane-probes.bats — BATS suite for SLAWS-SLAAT cross-plane permutations
# Validates one-shot execution across telemetry ingest and adversarial attack boundaries.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  MATRIX_SCRIPT="${REPO_ROOT}/scripts/slaws-slaat-permutation-matrix.sh"
  TEST_TMP="${BATS_TEST_TMPDIR}/slaws-slaat"
  mkdir -p "$TEST_TMP"
}

@test "permutation harness script exists and is executable" {
  [ -x "$MATRIX_SCRIPT" ]
}

@test "permutation harness dry-run succeeds with zero exceptions" {
  run "$MATRIX_SCRIPT" --dry-run "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Verdict                 : PASS"* ]]
  [ -f "${TEST_TMP}/slaws-slaat-permutation-baseline.json" ]
}

@test "permutation harness individual suites run cleanly" {
  for suite in suite1 suite2 suite3 suite4 suite5; do
    run "$MATRIX_SCRIPT" --dry-run --suite "$suite" "$TEST_TMP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Running Suite"* ]]
  done
}

@test "permutation baseline evidence records valid JSON with pass status" {
  run "$MATRIX_SCRIPT" "$TEST_TMP"
  [ "$status" -eq 0 ]
  run jq -e '.status == "PASS" and .passedVectors > 0 and .failedVectors == 0' "${TEST_TMP}/slaws-slaat-permutation-baseline.json"
  [ "$status" -eq 0 ]
}
