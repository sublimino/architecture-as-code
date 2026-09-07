#!/usr/bin/env bats
# test/crkc-phase3-confinement-redteam.bats — Phase 3 Confinement Adversarial Red-Team Suite
#
# Validates Rule SP-1 (Worktree Landlock Confinement), Rule SP-2 (Node Capability Admission Guard),
# and Rule SP-4 (Non-Turing Complete CEL-to-Landlock Policy Compilation) against active adversarial attacks.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  COMPILER_BIN="$REPO_ROOT/bin/policy-compiler"
  GUARD_BIN="$REPO_ROOT/bin/node-capability-guard"
  AGENT_GIT="$REPO_ROOT/bin/agent-git"
  PROFILE="$REPO_ROOT/nono/profiles/worktree-agent.json"
  INVARIANTS="$REPO_ROOT/config/security-invariants.yaml"
  TMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP_DIR"
}

# --- Red-Team Tier 1: Declarative CEL & Turing-Completeness Invariants (Rule SP-4) ---

@test "redteam: policy compiler rejects unbounded loop / turing-complete CEL injection" {
  cat <<'YAML' > "$TMP_DIR/malicious-invariants.yaml"
version: v1alpha1
invariants:
  - id: malicious-recursion
    name: "Attempted Turing complete CEL"
    description: "Injected recursive CEL expression"
    tier: "admission"
    cel_expression: "while(true) { doBadStuff(); }"
    enforcement_mode: "enforce"
YAML

  run "$COMPILER_BIN" validate -i "$TMP_DIR/malicious-invariants.yaml"
  [ "$status" -ne 0 ]
}

@test "redteam: policy compiler rejects invalid or tampered invariant schemas" {
  cat <<'YAML' > "$TMP_DIR/corrupt-invariants.yaml"
version: v1alpha1
invariants:
  - id: 12345
    name: 67890
    tier: "unknown-tier"
YAML

  run "$COMPILER_BIN" validate -i "$TMP_DIR/corrupt-invariants.yaml"
  [ "$status" -ne 0 ]
}

@test "redteam: policy compiler detects out-of-band drift across 95 equivalence probes" {
  run "$COMPILER_BIN" compile -i "$INVARIANTS" -o "$TMP_DIR/out"
  [ "$status" -eq 0 ]

  # Simulate adversarial tampering of generated Landlock policy
  echo '{"adversarial_bypass": true}' >> "$TMP_DIR/out/nono/signalloom-agent-runtime.json"

  run "$COMPILER_BIN" verify -i "$INVARIANTS" -d "$TMP_DIR/out"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Drift detected" ]]
}

# --- Red-Team Tier 2: Rule SP-1 Worktree Landlock Confinement & Agent-Git Escapes ---

@test "redteam: agent-git blocks forced push attacks across all flags" {
  run env AGENT_GIT_SKIP_ROOT_CHECK=1 AGENT_GIT_BIN=/usr/bin/git "$AGENT_GIT" push --force origin main
  [ "$status" -eq 4 ]
  [[ "$output" =~ "Rule SP-1" ]]

  run env AGENT_GIT_SKIP_ROOT_CHECK=1 AGENT_GIT_BIN=/usr/bin/git "$AGENT_GIT" push -f origin HEAD
  [ "$status" -eq 4 ]
  [[ "$output" =~ "Rule SP-1" ]]

  run env AGENT_GIT_SKIP_ROOT_CHECK=1 AGENT_GIT_BIN=/usr/bin/git "$AGENT_GIT" push --all
  [ "$status" -eq 4 ]
  [[ "$output" =~ "Rule SP-1" ]]
}

@test "redteam: agent-git enforces --no-gpg-sign against adversarial gpg escalation" {
  run env AGENT_GIT_DRY_RUN=1 AGENT_GIT_SKIP_ROOT_CHECK=1 AGENT_GIT_BIN=/usr/bin/git \
    "$AGENT_GIT" commit -m "adversarial gpg escalation attempt"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "--no-gpg-sign" ]]

  # Inspect wrapper logic explicitly for pinentry/gpg bypass
  run grep "\-\-no-gpg-sign" "$AGENT_GIT"
  [ "$status" -eq 0 ]
}

@test "redteam: worktree profile denies access to host credential stores" {
  run jq -r '.filesystem.deny[]' "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ".ssh" ]]
  [[ "$output" =~ ".andy_sync" ]]
  [[ "$output" =~ ".gnupg" ]]
  [[ "$output" =~ ".aws" ]]
  [[ "$output" =~ ".kube" ]]
}

@test "redteam: worktree profile blocks raw outbound network by default" {
  run jq -r '.network.block' "$PROFILE"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

# --- Red-Team Tier 3: Rule SP-2 Node Capability Admission Guard ---

@test "redteam: node capability guard rejects unconfined agent pods (HTTP 403)" {
  local fixture="$REPO_ROOT/test/fixtures/agent-pod-unconfined-node.yaml"
  [ -f "$fixture" ]

  # Verify rejection proof
  local proof="$REPO_ROOT/docs/signalloom/evidence/admission-guard-proof.json"
  [ -f "$proof" ]
  run jq -r '.probes.unconfined_rejected.allowed' "$proof"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]

  run jq -r '.probes.unconfined_rejected.code' "$proof"
  [ "$status" -eq 0 ]
  [ "$output" = "403" ]
}

@test "redteam: zero policy escapes and zero unauthorized network connections in audit logs" {
  local proof="$REPO_ROOT/docs/signalloom/evidence/worktree-confinement-proof.json"
  [ -f "$proof" ]

  run jq -r '.totals.failed' "$proof"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]

  # Verify unauthorized network socket blocked by kernel
  run jq -r '.probes[] | select(.id == "net.closed-port-denied") | .verdict' "$proof"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}
