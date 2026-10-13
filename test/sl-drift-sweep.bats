#!/usr/bin/env bats
# test/sl-drift-sweep.bats
# Contract tests for the sl-drift-sweep skill and Tools/drift-sweep.sh.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_DIR="$ROOT/.agents/skills/sl-drift-sweep"
  TOOL="$SKILL_DIR/Tools/drift-sweep.sh"
}

@test "sl-drift-sweep skill files and executable tool exist" {
  [ -f "$SKILL_DIR/SKILL.md" ]
  [ -f "$SKILL_DIR/Workflows/Sweep.md" ]
  [ -f "$SKILL_DIR/References/DriftAndSmellBaseline.md" ]
  [ -x "$TOOL" ]
  grep -q "^name: sl-drift-sweep$" "$SKILL_DIR/SKILL.md"
}

@test "drift-sweep.sh defaults to PAUSE_FOR_APPROVAL and reports CLEAN on remediated repo" {
  run "$TOOL" --skip-docs-lint --ignore-dirty
  [ "$status" -eq 0 ]
  [[ "$output" == *"Execution Mode : PAUSE_FOR_APPROVAL"* ]]
  [[ "$output" == *"STATUS: CLEAN (standards=0, spec=0, jobs=0,"*"mode=PAUSE_FOR_APPROVAL)"* ]]
}

@test "drift-sweep.sh emits PAUSE action when drift is detected in default mode" {
  local tmp_repo
  tmp_repo="$(mktemp -d)"
  git -C "$tmp_repo" init -q
  mkdir -p "$tmp_repo/docs" "$tmp_repo/d2-signalloom/apps/fleet-manager"
  # Simulate proposal sprawl (>1 ungrouped proposal) and missing httputil.go
  cat << 'EOF' > "$tmp_repo/docs/README.md"
| [P1](P1.md) | — | Delivered |
| [P2](P2.md) | — | Delivered |
EOF

  run "$TOOL" --repo-root "$tmp_repo" --proposal-sprawl-threshold 1 --skip-docs-lint --ignore-dirty
  rm -rf "$tmp_repo"

  [ "$status" -eq 0 ]
  [[ "$output" == *"STATUS: DRIFT_DETECTED (standards=1, spec=1, jobs=2,"*"mode=PAUSE_FOR_APPROVAL)"* ]]
  [[ "$output" == *"ACTION: PAUSE — Present the Two-Axis Report"* ]]
}

@test "drift-sweep.sh --auto emits AUTO_EXECUTE action when drift is detected" {
  local tmp_repo
  tmp_repo="$(mktemp -d)"
  git -C "$tmp_repo" init -q
  mkdir -p "$tmp_repo/docs" "$tmp_repo/d2-signalloom/apps/fleet-manager"
  cat << 'EOF' > "$tmp_repo/docs/README.md"
| [P1](P1.md) | — | Delivered |
| [P2](P2.md) | — | Delivered |
EOF

  run "$TOOL" --auto --repo-root "$tmp_repo" --proposal-sprawl-threshold 1 --skip-docs-lint --ignore-dirty
  rm -rf "$tmp_repo"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Execution Mode : AUTO"* ]]
  [[ "$output" == *"STATUS: DRIFT_DETECTED (standards=1, spec=1, jobs=2,"*"mode=AUTO)"* ]]
  [[ "$output" == *"ACTION: AUTO_EXECUTE — Proceed to Phase 4"* ]]
}

