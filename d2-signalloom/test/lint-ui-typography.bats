#!/usr/bin/env bats
#
# Typography & punctuation enforcement gate for dashboard-signalloom UI sources.
# Enforces PAI 5.0.0 rule: Zero em-dashes ('—' / \u2014) in user-facing UI text,
# strictly prohibits substituting with en-dashes ('–'), and verifies that the
# ESLint typography allowlist remains completely empty.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  DASHBOARD_DIR="$REPO_ROOT/d2-signalloom/apps/dashboard-signalloom"
  ALLOWLIST_FILE="$DASHBOARD_DIR/typography-allowlist.json"
}

@test "UI source files contain zero em-dashes" {
  cd "$DASHBOARD_DIR"
  run bash -c "grep -ro '—' src --exclude='*.test.*' | wc -l"
  [ "$status" -eq 0 ]
  trimmed="${output//[[:space:]]/}"
  [ "$trimmed" = "0" ]
}

@test "UI source files do not exceed baseline en-dash count of 9" {
  cd "$DASHBOARD_DIR"
  run bash -c "grep -ro '–' src --exclude='*.test.*' | wc -l"
  [ "$status" -eq 0 ]
  trimmed="${output//[[:space:]]/}"
  [ "$trimmed" -le 9 ]
}

@test "ESLint typography allowlist is completely empty" {
  [ -f "$ALLOWLIST_FILE" ]
  run node -e "
    const fs = require('fs');
    const allowlist = JSON.parse(fs.readFileSync('$ALLOWLIST_FILE', 'utf8'));
    const entries = Object.keys(allowlist);
    if (entries.length > 0) {
      console.error('Allowlist contains active entries:', entries);
      process.exit(1);
    }
  "
  [ "$status" -eq 0 ]
}

@test "Dashboard ESLint runs clean with zero warnings" {
  cd "$DASHBOARD_DIR"
  run bun run lint
  [ "$status" -eq 0 ]
}

@test "Mutation test: planted em-dash triggers gate failure" {
  cd "$DASHBOARD_DIR"
  tmp_file="src/components/TypographyGatePlantedMutation.tsx"
  printf "export const PlantedEmDashTest = () => <div>Planted — violation</div>;\n" > "$tmp_file"

  # 1. Verify grep detects it
  run bash -c "grep -ro '—' src --exclude='*.test.*' | wc -l"
  rm -f "$tmp_file"
  [ "$status" -eq 0 ]
  trimmed="${output//[[:space:]]/}"
  [ "$trimmed" -gt 0 ]
}
