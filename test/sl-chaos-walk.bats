#!/usr/bin/env bats
# test/sl-chaos-walk.bats
# Contract tests for the sl-chaos-walk skill and Tools/chaos-walk.sh.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_DIR="$ROOT/.agents/skills/sl-chaos-walk"
  TOOL="$SKILL_DIR/Tools/chaos-walk.sh"
}

@test "sl-chaos-walk skill files and executable tool exist" {
  [ -f "$SKILL_DIR/SKILL.md" ]
  [ -x "$TOOL" ]
  grep -q "^name: sl-chaos-walk$" "$SKILL_DIR/SKILL.md"
  grep -q "quick-walk" "$SKILL_DIR/SKILL.md"
  grep -q "deep-chaos" "$SKILL_DIR/SKILL.md"
  grep -q "api-storm" "$SKILL_DIR/SKILL.md"
}

@test "chaos-walk.sh --help outputs usage with all three profiles and --local option" {
  run "$TOOL" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--profile quick-walk"* ]]
  [[ "$output" == *"--profile deep-chaos"* ]]
  [[ "$output" == *"--profile api-storm"* ]]
  [[ "$output" == *"--local"* ]]
}

@test "chaos-walk.sh rejects invalid profile with exit 1" {
  run "$TOOL" --profile non-existent-profile
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unsupported profile"* ]]
}

@test "chaos-walk.sh --local targets localhost endpoint" {
  local out_dir="$BATS_TEST_TMPDIR/local-reports"
  mkdir -p "$out_dir"
  run "$TOOL" --profile quick-walk --local --mock --turns 1 --area /agents --out-dir "$out_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Target URL:      http://127.0.0.1:"* ]]
}

@test "chaos-walk.sh executes quick-walk in calibrated mock simulation mode" {
  local out_dir="$BATS_TEST_TMPDIR/chaos-reports"
  mkdir -p "$out_dir"
  run "$TOOL" --profile quick-walk --turns 2 --area /agents --mock --out-dir "$out_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
  [ -f "$out_dir"/*_quick-walk.md ]
}

@test "chaos-walk.sh executes deep-chaos in calibrated mock simulation mode" {
  local out_dir="$BATS_TEST_TMPDIR/deep-reports"
  mkdir -p "$out_dir"
  run "$TOOL" --profile deep-chaos --turns 1 --area /agents --mock --out-dir "$out_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"routes rendered"* ]]
  [ -f "$out_dir"/*_deep-chaos.md ]
}

@test "chaos-walk.sh executes api-storm with bounded requests and zero defects" {
  local out_dir="$BATS_TEST_TMPDIR/api-reports"
  mkdir -p "$out_dir"
  run "$TOOL" --profile api-storm --requests 5 --concurrency 2 --out-dir "$out_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Defects Found: 0"* ]]
  [ -f "$out_dir"/*_api-storm.md ]
}
