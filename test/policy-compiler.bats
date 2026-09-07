#!/usr/bin/env bats
# test/policy-compiler.bats — Verification of declarative CEL-to-Landlock policy compiler

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$REPO_ROOT/bin/policy-compiler"
  INVARIANTS="$REPO_ROOT/config/security-invariants.yaml"
  TMP_OUT="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP_OUT"
}

@test "policy-compiler binary is built and responds to help" {
  [ -x "$BIN" ]
  run "$BIN" help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Declarative CEL-to-Landlock Policy Compiler" ]]
}

@test "policy-compiler compiles invariants into VAP manifests and nono profile" {
  run "$BIN" compile -i "$INVARIANTS" -o "$TMP_OUT"
  [ "$status" -eq 0 ]
  [ -f "$TMP_OUT/vap/filesystem.yaml" ]
  [ -f "$TMP_OUT/vap/network.yaml" ]
  [ -f "$TMP_OUT/vap/process.yaml" ]
  [ -f "$TMP_OUT/nono/signalloom-agent-runtime.json" ]
  [ -f "$TMP_OUT/policies.lock.json" ]
}

@test "compiled nono profile is valid JSON" {
  "$BIN" compile -i "$INVARIANTS" -o "$TMP_OUT"
  run jq . "$TMP_OUT/nono/signalloom-agent-runtime.json"
  [ "$status" -eq 0 ]
}

@test "policy-compiler validate succeeds and confirms Rule SP-4 compliance" {
  run "$BIN" validate -i "$INVARIANTS"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Rule SP-4 CEL Non-Turing Completeness: PASS" ]]
  [[ "$output" =~ "Cross-Tier Semantic Equivalence: PASS" ]]
}

@test "policy-compiler verify reports in-sync for compiled output" {
  "$BIN" compile -i "$INVARIANTS" -o "$TMP_OUT"
  run "$BIN" verify -i "$INVARIANTS" -d "$TMP_OUT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "In-sync" ]]
}

@test "policy-compiler verify catches tampering and reports drift" {
  "$BIN" compile -i "$INVARIANTS" -o "$TMP_OUT"
  echo "# modified" >> "$TMP_OUT/vap/filesystem.yaml"
  run "$BIN" verify -i "$INVARIANTS" -d "$TMP_OUT"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Drift detected" ]]
}
