#!/usr/bin/env bats
# test/baoaudit-p2-preflight.bats — BATS suite for BAOAUDIT Phase 2 preflight checks

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "baoaudit p2-preflight: scripts/baoaudit-p2-preflight.sh executes cleanly" {
    run "$REPO_ROOT/scripts/baoaudit-p2-preflight.sh"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "BAOAUDIT PHASE 2 PREFLIGHT PASSED" ]]
}

@test "baoaudit p2-preflight: vitest executes with zero failures" {
    cd "$REPO_ROOT/d2-signalloom/apps/dashboard-signalloom"
    run bunx vitest run
    [ "$status" -eq 0 ]
}

@test "baoaudit p2-preflight: CEL correlation engine passes unit tests" {
    cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
    run go test -v ./correlation/...
    [ "$status" -eq 0 ]
}

@test "baoaudit p2-preflight: acceptance spec coverage passes" {
    cd "$REPO_ROOT"
    run bats test/acceptance-spec-coverage.bats
    [ "$status" -eq 0 ]
}
