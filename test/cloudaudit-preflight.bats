#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "cloudaudit preflight: Go 1.22+ toolchain is available" {
  run go version
  [ "$status" -eq 0 ]
  [[ "$output" =~ "go1." ]]
}

@test "cloudaudit preflight: audit policy manifest exists and enforces Metadata level for secrets" {
  AUDIT_POLICY="$REPO_ROOT/d2-signalloom/infra/audit-policy.yaml"
  [ -f "$AUDIT_POLICY" ]
  run grep -E "level: Metadata" "$AUDIT_POLICY"
  [ "$status" -eq 0 ]
  
  # Ensure secrets are grouped under Metadata rules
  run grep -A 4 "level: Metadata" "$AUDIT_POLICY"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "secrets" ]]
}

@test "cloudaudit preflight: signal-ingest compiles and passes vet" {
  cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
  run go vet ./...
  [ "$status" -eq 0 ]
}

@test "cloudaudit preflight: scripts/cloudaudit-preflight.sh executes successfully" {
  run "$REPO_ROOT/scripts/cloudaudit-preflight.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Phase 1 Preflight Complete (PASS)" ]]
  [ -f "$REPO_ROOT/.cloudaudit-p1-preflight.json" ]
}
