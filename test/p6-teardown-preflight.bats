#!/usr/bin/env bats
#
# SLDC-P6-PRE: Pre-flight readiness checks for dual-cluster teardown and scratch standup.
#
# @target scripts/verify-teardown-prereqs.sh scripts/lib/cluster-reset-helpers.sh
# @doc    docs/eap/SLDC-P6-PREFLIGHT.md

setup() {
  root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  script="$root/scripts/verify-teardown-prereqs.sh"
  helpers="$root/scripts/lib/cluster-reset-helpers.sh"
}

@test "teardown prereqs script runs with --dry-run and exits 0" {
  run bash "$script" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "VERDICT: PASS" ]]
}

@test "teardown prereqs script writes machine-readable readiness json" {
  tmp_out="$BATS_TEST_TMPDIR/readiness.json"
  run bash "$script" --dry-run --out "$tmp_out"
  [ "$status" -eq 0 ]
  [ -f "$tmp_out" ]
  run jq -e '.verdict == "PASS" and .total_checks >= 7 and .failed_checks == 0' "$tmp_out"
  [ "$status" -eq 0 ]
}

@test "cluster-reset-helpers: check_cgroup_v2_status returns 0" {
  source "$helpers"
  run check_cgroup_v2_status
  [ "$status" -eq 0 ]
}

@test "cluster-reset-helpers: find_orphaned_veths executes without error" {
  source "$helpers"
  run find_orphaned_veths
  [ "$status" -eq 0 ]
}

@test "cluster-reset-helpers: cleanup_orphaned_veths dry-run succeeds" {
  source "$helpers"
  run cleanup_orphaned_veths 1
  [ "$status" -eq 0 ]
}

@test "cluster-reset-helpers: check_zot_cache_status reports cache" {
  source "$helpers"
  run check_zot_cache_status "$root"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Zot cache" ]]
}

@test "cold-start manifests tsv catalog has valid headers and non-empty rows" {
  tsv="$root/test/fixtures/cold-start-manifests.tsv"
  [ -f "$tsv" ]
  header="$(head -1 "$tsv")"
  [ "$header" = "component	kind	manifest_path	image	required" ]
  rows="$(grep -c -v '^component' "$tsv")"
  [ "$rows" -ge 10 ]
}

@test "mutation: fake missing keys directory causes verify-teardown-prereqs to fail" {
  tmp_empty="$BATS_TEST_TMPDIR/empty_keys"
  mkdir -p "$tmp_empty"
  tmp_out="$BATS_TEST_TMPDIR/mutated_readiness.json"
  run env KEYS_DIR="$tmp_empty" bash "$script" --dry-run --out "$tmp_out"
  [ "$status" -ne 0 ]
  run jq -e '.verdict == "FAIL" and .failed_checks > 0' "$tmp_out"
  [ "$status" -eq 0 ]
}

@test "mutation: missing manifest catalog causes verify-teardown-prereqs to fail" {
  tmp_root="$BATS_TEST_TMPDIR/fake_root"
  mkdir -p "$tmp_root"
  tmp_out="$BATS_TEST_TMPDIR/mutated_readiness2.json"
  run env REPO_ROOT="$tmp_root" bash "$script" --dry-run --out "$tmp_out"
  [ "$status" -ne 0 ]
}
