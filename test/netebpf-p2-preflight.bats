#!/usr/bin/env bats
# test/netebpf-p2-preflight.bats — NETEBPF Phase 2 Preflight Verification Suite

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "netebpf p2 preflight: scripts/netebpf-p2-preflight.sh executes cleanly" {
  run "${REPO_ROOT}/scripts/netebpf-p2-preflight.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Phase 2 Preflight Summary: 4 passed, 0 failed" ]]
}

@test "netebpf p2 preflight: FrostDB store schema initializes" {
  cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
  run go test ./store/...
  [ "$status" -eq 0 ]
}

@test "netebpf p2 preflight: CEL engine compiles all correlation rules" {
  cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
  run go test ./correlation/...
  [ "$status" -eq 0 ]
}

@test "netebpf p2 preflight: dashboard Vitest suite is operational" {
  cd "$REPO_ROOT/d2-signalloom/apps/dashboard-signalloom"
  run bunx vitest run src/pages/WeavePage.test.tsx
  [ "$status" -eq 0 ]
}
