#!/usr/bin/env bats

# swarm-demo-script.bats — structural tests for scripts/swarm-fleet-demo.sh.
# No cluster needed — validates syntax, subcommands, gate functions, and
# default configuration.
#
# Run: bats test/swarm-demo-script.bats

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
DEMO_SCRIPT="${REPO_ROOT}/scripts/swarm-fleet-demo.sh"

# ─── Script Existence and Syntax ───────────────────────────────────────────

@test "swarm-fleet-demo.sh exists" {
  [ -f "$DEMO_SCRIPT" ]
}

@test "swarm-fleet-demo.sh is executable" {
  [ -x "$DEMO_SCRIPT" ]
}

@test "script is syntactically valid bash" {
  run bash -n "$DEMO_SCRIPT"
  [ "$status" -eq 0 ]
}

# ─── Subcommands ───────────────────────────────────────────────────────────

@test "deploy subcommand exists" {
  grep -q 'deploy)' "$DEMO_SCRIPT" || \
  grep -q 'deploy_infra\|deploy_fleet' "$DEMO_SCRIPT"
}

@test "verify subcommand exists" {
  grep -q 'verify)' "$DEMO_SCRIPT" || \
  grep -q 'run_verification' "$DEMO_SCRIPT"
}

@test "teardown subcommand exists" {
  grep -q 'teardown)' "$DEMO_SCRIPT"
}

@test "all subcommand exists" {
  grep -q '"all")\|all)' "$DEMO_SCRIPT"
}

# ─── Gate Functions ────────────────────────────────────────────────────────

@test "verify_discovery function exists" {
  grep -q 'verify_discovery' "$DEMO_SCRIPT"
}

@test "verify_prompt_summarizer function exists" {
  grep -q 'verify_prompt_summarizer' "$DEMO_SCRIPT"
}

@test "verify_triage_worker function exists" {
  grep -q 'verify_triage_worker' "$DEMO_SCRIPT"
}

@test "verify_chatops function exists" {
  grep -q 'verify_chatops' "$DEMO_SCRIPT"
}

@test "verify_cpai function exists" {
  grep -q 'verify_cpai' "$DEMO_SCRIPT"
}

@test "verify_daytona function exists" {
  grep -q 'verify_daytona' "$DEMO_SCRIPT"
}

@test "verify_governor function exists" {
  grep -q 'verify_governor' "$DEMO_SCRIPT"
}

@test "verify_deploy_gate function exists" {
  grep -q 'verify_deploy_gate' "$DEMO_SCRIPT"
}

@test "verify_cardvault function exists" {
  grep -q 'verify_cardvault' "$DEMO_SCRIPT"
}

@test "verify_nono function exists" {
  grep -q 'verify_nono' "$DEMO_SCRIPT"
}

@test "verify_stun_sentinel function exists" {
  grep -q 'verify_stun_sentinel' "$DEMO_SCRIPT"
}

@test "verify_stun_action function exists" {
  grep -q 'verify_stun_action' "$DEMO_SCRIPT"
}

# ─── Configuration ─────────────────────────────────────────────────────────

@test "NAMESPACE defaults to fe-signalloom-agents" {
  run grep 'NAMESPACE.*fe-signalloom-agents' "$DEMO_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "script references all 10 agent names" {
  local agents=(
    prompt-commit-summarizer
    triage-ci-worker
    zulip-chat-agent
    cpai-engineer
    hosted-daytona-coder
    swarm-governor
    prod-deploy-gate
    agent-cardvault
    nono-containment-probe
    signalloom-stun-sentinel
  )
  for agent in "${agents[@]}"; do
    grep -q "$agent" "$DEMO_SCRIPT"
  done
}

# ─── Helper Dependencies ──────────────────────────────────────────────────

@test "script sets colour variables" {
  # The script defines colour/color helpers for terminal output.
  grep -qE 'RED=|GREEN=|YELLOW=|CYAN=|NC=|BOLD=' "$DEMO_SCRIPT"
}

@test "script defines pass/fail/warn/info helpers" {
  grep -qE 'pass\(\)|fail\(\)|warn\(\)|info\(\)' "$DEMO_SCRIPT"
}
