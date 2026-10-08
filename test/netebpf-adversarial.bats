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
  cd "$REPO_ROOT/d2-signalloom/apps/stun-sentinel"
  run env PATH="/home/linuxbrew/.linuxbrew/bin:/usr/bin:$PATH" GONOSUMDB="*" GOTOOLCHAIN="local" CGO_ENABLED=0 GOPATH="${GOPATH:-/tmp/gopath}" GOCACHE="${GOCACHE:-/tmp/gocache}" GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}" GOFLAGS=-buildvcs=false go test -v ./...
  [ "$status" -eq 0 ]

  cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
  run env PATH="/home/linuxbrew/.linuxbrew/bin:/usr/bin:$PATH" GONOSUMDB="*" GOTOOLCHAIN="local" CGO_ENABLED=0 GOPATH="${GOPATH:-/tmp/gopath}" GOCACHE="${GOCACHE:-/tmp/gocache}" GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}" GOFLAGS=-buildvcs=false go test -v ./collectors/netebpf/... ./correlation/...
  [ "$status" -eq 0 ]
}

@test "netebpf adversarial: dashboard Weave tests verify telemetry badges and fail-closed gap banner" {
  cd "$REPO_ROOT/d2-signalloom/apps/dashboard-signalloom"
  run env PATH="/home/andy/.bun/bin:/home/andy/.local/bin:$PATH" bunx vitest run src/pages/WeavePage.test.tsx
  [ "$status" -eq 0 ]
}
