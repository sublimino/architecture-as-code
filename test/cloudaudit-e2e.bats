#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "cloudaudit e2e: audit-gen CLI builds and generates valid JSON" {
  run go run "$REPO_ROOT/tools/audit-gen/main.go" --mode mixed --count 10 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "EventList" ]]
  [[ "$output" =~ "audit.k8s.io/v1" ]]
  [[ "$output" =~ "autonomous-agent-1" ]]
}

@test "cloudaudit e2e: signal-ingest receiver and collectors pass all unit tests" {
  cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
  run go test -v ./api/audit... ./collectors/gcpaudit... ./transform... ./correlation...
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PASS" ]]
}

@test "cloudaudit e2e: dashboard Weave page vitest suite passes with Layer 6 active" {
  cd "$REPO_ROOT/d2-signalloom/apps/dashboard-signalloom"
  run bunx vitest run src/pages/WeavePage.test.tsx src/components/EvidenceDrawer.test.tsx
  [ "$status" -eq 0 ]
}
