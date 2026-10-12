#!/usr/bin/env bats
# test/impl-agent-log.bats — comprehensive verification for shared agent communication log

setup() {
  script="$BATS_TEST_DIRNAME/../scripts/impl-agent-log.sh"
  export TEST_TMP="$BATS_TEST_TMPDIR/agent-bus-$$"
  mkdir -p "$TEST_TMP"
  export IMPL_AGENT_LOG="$TEST_TMP/impl-agent.log"
  export IMPL_AGENT_LOCK="$TEST_TMP/impl-agent.log.lock"
  export AGENT_ID="test-agent-alpha"
  export AGENT_ROLE="TestWorker"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "IMPL_LOG init creates log file with header and permissions" {
  run bash "$script" init
  [ "$status" -eq 0 ]
  [ -f "$IMPL_AGENT_LOG" ]
  [ -f "$IMPL_AGENT_LOCK" ]
  run grep -F "OSRAMP / SIGNAL LOOM SHARED AGENT COMMUNICATION LOG" "$IMPL_AGENT_LOG"
  [ "$status" -eq 0 ]
  run grep -F "[INIT]" "$IMPL_AGENT_LOG"
  [ "$status" -eq 0 ]
}

@test "IMPL_LOG announce records agent id and role" {
  run bash "$script" announce "Coordinator" "Running preflight checks"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[test-agent-alpha]"* ]]
  [[ "$output" == *"[ANNOUNCE]"* ]]
  [[ "$output" == *"role=Coordinator Running preflight checks"* ]]
}

@test "IMPL_LOG heartbeat records ongoing progress" {
  run bash "$script" heartbeat "Processed 10/10 items"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[HEARTBEAT]"* ]]
  [[ "$output" == *"Processed 10/10 items"* ]]
}

@test "IMPL_LOG claim lifecycle: claim, conflict detection, release" {
  # 1. Claim a resource
  run bash "$script" claim "src/api/client.ts" "Refactoring demo error handling"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[CLAIM]"* ]]
  [[ "$output" == *"[src/api/client.ts]"* ]]

  # 2. Check active claims
  run bash "$script" claims
  [ "$status" -eq 0 ]
  [[ "$output" == *"[src/api/client.ts]"* ]]

  # 3. Attempting to claim the same resource as another agent without --force is REFUSED
  AGENT_ID="test-agent-beta" run bash "$script" claim "src/api/client.ts" "Conflicting work"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Conflict warning: Resource [src/api/client.ts] is already claimed"* ]]

  # 4. Overriding with --force succeeds
  AGENT_ID="test-agent-beta" run bash "$script" --force claim "src/api/client.ts" "Forced takeover"
  [ "$status" -eq 0 ]

  # 5. Release resource
  AGENT_ID="test-agent-beta" run bash "$script" release "src/api/client.ts" "Work completed"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[RELEASE]"* ]]

  # 6. Claims should now be empty for this resource
  run bash "$script" claims
  [ "$status" -eq 0 ]
  [[ "$output" != *"[src/api/client.ts]"* ]]
}

@test "IMPL_LOG discover records findings and severity" {
  run bash "$script" discover "HIGH" "crypto-audit" "Hardcoded SPIRE inventory found"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DISCOVERY]"* ]]
  [[ "$output" == *"[crypto-audit]"* ]]
  [[ "$output" == *"severity=HIGH Hardcoded SPIRE inventory found"* ]]
}

@test "IMPL_LOG msg records targeted and broadcast messages" {
  run bash "$script" msg "all" "Hello world from test suite"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[MSG]"* ]]
  [[ "$output" == *"[@all]"* ]]
  [[ "$output" == *"Hello world from test suite"* ]]

  run bash "$script" msg "worker-1" "Please check task queue"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[@worker-1]"* ]]
}

@test "IMPL_LOG read returns requested number of entries" {
  bash "$script" init
  for i in {1..10}; do
    bash "$script" heartbeat "Step $i"
  done

  run bash "$script" read 3
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[2]}" == *"Step 10"* ]]

  run bash "$script" read all
  [ "$status" -eq 0 ]
  # Header lines + init + 10 heartbeats
  [ "${#lines[@]}" -ge 16 ]
}

@test "IMPL_LOG status summarizes active agents and claims" {
  bash "$script" announce "Reviewer" "Reviewing PR #42"
  bash "$script" claim "docs/proposals/test.md" "Drafting proposal"
  bash "$script" discover "LOW" "typo" "Fixed documentation spelling"

  run bash "$script" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== Shared Agent Log Status ==="* ]]
  [[ "$output" == *"docs/proposals/test.md"* ]]
  [[ "$output" == *"Fixed documentation spelling"* ]]
  [[ "$output" == *"test-agent-alpha"* ]]
}

@test "IMPL_LOG input validation and bad argument handling" {
  # No arguments
  run bash "$script"
  [ "$status" -eq 2 ]

  # Unknown command
  run bash "$script" nonexistent-command
  [ "$status" -eq 2 ]

  # claim without resource
  run bash "$script" claim
  [ "$status" -eq 2 ]

  # release without resource
  run bash "$script" release
  [ "$status" -eq 2 ]

  # discover without severity or topic
  run bash "$script" discover
  [ "$status" -eq 2 ]

  # msg without target or message
  run bash "$script" msg
  [ "$status" -eq 2 ]
}

@test "IMPL_LOG concurrent appends preserve integrity under flock" {
  bash "$script" init

  # Launch 20 concurrent writer processes in background
  for i in {1..20}; do
    AGENT_ID="worker-$i" bash "$script" heartbeat "Concurrent entry $i" &
  done
  wait

  # Verify all 20 lines landed without mangling
  count=$(grep -c "Concurrent entry" "$IMPL_AGENT_LOG")
  [ "$count" -eq 20 ]

  # Verify every worker ID is distinct in output
  for i in {1..20}; do
    grep -q "\[worker-$i\]" "$IMPL_AGENT_LOG"
  done
}

@test "IMPL_LOG claim self-renewal succeeds for owning agent without --force" {
  run bash "$script" claim "src/service.ts" "Phase 1 work"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[src/service.ts]"* ]]

  # Same agent re-claims to renew lease or update progress
  run bash "$script" claim "src/service.ts" "Phase 2 work"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(renewed)"* ]]
  [[ "$output" == *"Phase 2 work"* ]]
}

@test "IMPL_LOG release permission check prevents unauthorized release" {
  run bash "$script" claim "src/protected.ts" "Alpha exclusive lock"
  [ "$status" -eq 0 ]

  # Sibling agent attempts to release alpha's claim without --force -> REFUSED
  AGENT_ID="test-agent-gamma" run bash "$script" release "src/protected.ts" "Rogue release"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: Resource [src/protected.ts] is claimed by [test-agent-alpha], not [test-agent-gamma]"* ]]

  # Sibling agent with --force succeeds
  AGENT_ID="test-agent-gamma" run bash "$script" --force release "src/protected.ts" "Coordinator takeover"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[RELEASE]"* ]]

  # Claim is now cleared
  run bash "$script" claims
  [ "$status" -eq 0 ]
  [[ "$output" != *"[src/protected.ts]"* ]]
}

@test "IMPL_LOG claim lease TTL expiration permits graceful recovery" {
  # Claim with 1 second TTL
  run bash "$script" --ttl 1 claim "src/expiring.ts" "Short-lived lock"
  [ "$status" -eq 0 ]

  # Immediate attempt by sibling fails with conflict
  AGENT_ID="test-agent-delta" run bash "$script" claim "src/expiring.ts" "Should conflict"
  [ "$status" -eq 1 ]

  # Sleep past TTL
  sleep 2

  # Active claims should show empty
  run bash "$script" claims
  [ "$status" -eq 0 ]
  [[ "$output" != *"[src/expiring.ts]"* ]]

  run bash "$script" claims --expired
  [ "$status" -eq 0 ]
  [[ "$output" == *"[src/expiring.ts]"* ]]
  [[ "$output" == *"[EXPIRED:"* ]]

  # Sibling agent delta can now acquire without --force
  AGENT_ID="test-agent-delta" run bash "$script" claim "src/expiring.ts" "Acquiring expired lease"
  [ "$status" -eq 0 ]
  [[ "$output" == *"lease-acquired:expired-from:test-agent-alpha"* ]]
}

@test "IMPL_LOG handles resources with brackets, spaces, and path slashes" {
  local res="bundle/[slug]/components/Header (v2).tsx"
  run bash "$script" claim "$res" "Bracket path editing"
  [ "$status" -eq 0 ]

  run bash "$script" claims
  [ "$status" -eq 0 ]
  [[ "$output" == *"$res"* ]]

  # Conflict check works with brackets
  AGENT_ID="test-agent-beta" run bash "$script" claim "$res" "Conflicting bracket"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Conflict warning: Resource [$res] is already claimed"* ]]

  # Clean release works
  run bash "$script" release "$res" "Done bracket edits"
  [ "$status" -eq 0 ]

  run bash "$script" claims
  [ "$status" -eq 0 ]
  [[ "$output" != *"$res"* ]]
}

@test "IMPL_LOG msg normalizes @ prefix cleanly" {
  run bash "$script" msg "@all" "Testing @all normalization"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[@all]"* ]]
  [[ "$output" != *"[@@all]"* ]]

  run bash "$script" msg "team" "Testing team normalization"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[@team]"* ]]
}

@test "IMPL_LOG read filtering by event, agent, and topic" {
  bash "$script" init
  bash "$script" discover "HIGH" "sec-vuln" "Demo key leak"
  bash "$script" msg "ops" "Please rotate keys"
  bash "$script" heartbeat "Monitoring active"

  # Filter by event
  run bash "$script" read --event DISCOVERY
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DISCOVERY]"* ]]
  [[ "$output" != *"[MSG]"* ]]
  [[ "$output" != *"[HEARTBEAT]"* ]]

  # Filter by topic
  run bash "$script" read --topic sec-vuln
  [ "$status" -eq 0 ]
  [[ "$output" == *"[sec-vuln]"* ]]
  [[ "$output" != *"rotate keys"* ]]

  # Invalid count validation
  run bash "$script" read --invalid
  [ "$status" -eq 2 ]
}

@test "IMPL_LOG status detects all active agents regardless of entry type" {
  # Agent without announce, only doing claim and discover
  AGENT_ID="unannounced-worker" bash "$script" claim "worker-file.txt" "Silent worker"
  AGENT_ID="discovery-scout" bash "$script" discover "LOW" "lint" "Minor lint issue"

  run bash "$script" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"unannounced-worker"* ]]
  [[ "$output" == *"discovery-scout"* ]]
}
