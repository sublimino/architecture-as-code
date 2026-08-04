#!/usr/bin/env bats
# Harness tests for supercred-fleet-demo.sh — validates script structure,
# subcommand definitions, shared lib sourcing, and known traps.
#
# These tests run offline (no cluster required).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  FLEET_SCRIPT="${REPO_ROOT}/scripts/supercred-fleet-demo.sh"
}

# ─── Script basics ───────────────────────────────────────────────────────────

@test "HARNESS fleet demo script exists and is executable" {
  [ -f "$FLEET_SCRIPT" ]
  [ -x "$FLEET_SCRIPT" ]
}

@test "HARNESS fleet demo script passes bash -n syntax check" {
  run bash -n "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "HARNESS fleet demo script does not use set -u" {
  run grep -c 'set -u' "$FLEET_SCRIPT"
  # grep exit 1 means no match — that is what we want
  [ "$status" -eq 1 ] || [ "$output" = "0" ]
}

# ─── Subcommand definitions ─────────────────────────────────────────────────

@test "HARNESS deploy-fleet subcommand is defined" {
  run grep -c 'deploy-fleet' "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "HARNESS scan-fleet subcommand is defined" {
  run grep -c 'scan-fleet' "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "HARNESS stun-agent subcommand is defined" {
  run grep -c 'stun-agent' "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "HARNESS recover-agent subcommand is defined" {
  run grep -c 'recover-agent' "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "HARNESS reset-fleet subcommand is defined" {
  run grep -c 'reset-fleet' "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ─── Shared lib sourcing ────────────────────────────────────────────────────

@test "HARNESS script sources lib/wait.sh" {
  run grep -c 'source.*lib/wait.sh' "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "HARNESS script defines log function" {
  run grep -c '^log()' "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "HARNESS script defines ok function" {
  run grep -c '^ok()' "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "HARNESS script defines fail function" {
  run grep -c '^fail()' "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ─── Safety checks ──────────────────────────────────────────────────────────

@test "HARNESS script does not modify supercred-demo.sh patterns" {
  # The fleet script must not reference the single-agent demo functions
  run grep -c 'demo_1\|demo_2\|demo_3\|demo_4\|demo_5' "$FLEET_SCRIPT"
  [ "$status" -eq 1 ] || [ "$output" = "0" ]
}

@test "HARNESS script uses fleet-specific log prefix" {
  # Should use [fleet] not [supercred]
  run grep -c '\[fleet\]' "$FLEET_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "HARNESS script references all five agents" {
  for agent in agent-cardvault agent-txn-pipeline agent-llm-classifier agent-api-gateway agent-monitor; do
    run grep -c "$agent" "$FLEET_SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
  done
}

@test "HARNESS no-args invocation prints usage" {
  # Source the script in a subshell that won't connect to a cluster
  run bash -c "source '$FLEET_SCRIPT' 2>/dev/null || true"
  # The case statement default prints usage and exits 1
  [[ "$output" == *"Usage"* ]] || [[ "$output" == *"deploy-fleet"* ]]
}
