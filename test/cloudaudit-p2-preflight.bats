#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "cloudaudit p2 preflight: CEL engine package compiles and passes TestRules_Compile" {
  cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
  run go test ./correlation... -run TestRules_Compile
  [ "$status" -eq 0 ]
}

@test "cloudaudit p2 preflight: dashboard TypeScript project is healthy" {
  cd "$REPO_ROOT/d2-signalloom/apps/dashboard-signalloom"
  [ -f "src/App.tsx" ]
  [ -f "src/pages/WeavePage.tsx" ]
}

@test "cloudaudit p2 preflight: scripts/cloudaudit-p2-preflight.sh executes successfully" {
  run "$REPO_ROOT/scripts/cloudaudit-p2-preflight.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Phase 2 Preflight Complete (PASS)" ]]
  [ -f "$REPO_ROOT/.cloudaudit-p2-preflight.json" ]
}
