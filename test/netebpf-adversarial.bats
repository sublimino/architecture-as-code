#!/usr/bin/env bats
# test/netebpf-adversarial.bats — E2E Adversarial eBPF Network Telemetry Verification

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "netebpf adversarial: synthetic generator produces valid json flow events" {
  run "${REPO_ROOT}/scripts/netebpf-synthetic-generator.sh" 5
  [ "$status" -eq 0 ]
  [[ "$output" =~ "OpenAI" ]]
  [[ "$output" =~ "agent-cardvault-sa" ]]
}

@test "netebpf adversarial: sequence gap mode injects monotonic sequence discontinuity" {
  run "${REPO_ROOT}/scripts/netebpf-synthetic-generator.sh" 10 gap
  [ "$status" -eq 0 ]
  [[ "$output" =~ '"seq_num": 115' ]]
}

@test "netebpf adversarial: all signal-ingest and sentinel race tests pass" {
  cd "$REPO_ROOT/d2-signalloom/apps/signalloom-stun-sentinel"
  run go test -v -race ./...
  [ "$status" -eq 0 ]

  cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
  run go test -v -race ./collectors/netebpf/... ./correlation/...
  [ "$status" -eq 0 ]
}

@test "netebpf adversarial: dashboard Weave tests verify telemetry badges and fail-closed gap banner" {
  cd "$REPO_ROOT/d2-signalloom/apps/dashboard-signalloom"
  run bunx vitest run src/pages/WeavePage.test.tsx
  [ "$status" -eq 0 ]
}
