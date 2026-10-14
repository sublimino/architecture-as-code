#!/usr/bin/env bats
# Fail-closed REAL Nono/Landlock enforcement for the SP-5 evidenced agent (SLSI).
#
# @id      fe-agent-nono-fail-closed
# @target  d2-signalloom/apps/fe-signalloom-agents/probe-nono-capability.sh
#
# The SP-5 wrapper used to emit nono_capability_available:false + "executing
# unconfined" and then run status:"healthy" heartbeats forever — enforcement
# evidence WITHOUT enforcement. The rewrite:
#   * wraps the workload in REAL `nono run` when Landlock is enforceable, and
#   * FAILS CLOSED (non-zero, no healthy heartbeat, no landlock evidence) when
#     it is not.
#
# This is a host Tier-2 test: it drives the script directly against the real
# nono binary on this machine. It SKIPs — loudly, naming the cause — when nono
# or Landlock is unavailable, and never asserts a mock.
#
# A world-readable file (/etc/hostname) is the deny/control pair: denied under
# nono (the allow-list excludes /etc), readable without it. /etc/shadow would be
# ambiguous on the host because DAC already denies it to a non-root user.

SCRIPT="${BATS_TEST_DIRNAME}/../apps/fe-signalloom-agents/probe-nono-capability.sh"

setup() {
  command -v nono >/dev/null 2>&1 || skip "nono not on PATH (need it for real Landlock enforcement)"
  run nono setup --check-only
  [[ "$output" == *"verified"* ]] || skip "Landlock not enforceable on this kernel (need 5.13+): $output"
  # State root must sit OUTSIDE the allow-list and OUTSIDE the CWD (/tmp), or
  # nono refuses to start. When running in a worktree under /tmp, place the state
  # directory in the parent repository checkout.
  local state_parent="${BATS_TEST_DIRNAME}"
  if [[ "$state_parent" == /tmp/* ]]; then
    local common_git
    common_git="$(git rev-parse --git-common-dir 2>/dev/null || true)"
    if [ -n "$common_git" ] && [[ "$common_git" != /tmp/* ]]; then
      state_parent="$(cd "$common_git/.." && pwd)"
    fi
  fi
  STATE_DIR="$(mktemp -d "${state_parent}/.nono-state.XXXXXX")"
}

teardown() {
  [[ -n "${STATE_DIR:-}" ]] && rm -rf "$STATE_DIR"
  rm -f /tmp/fe-nono-allow-probe 2>/dev/null || true
}

@test "ENFORCED: the wrapped workload is denied /etc/hostname with a kernel EACCES" {
  run bash -c "cd /tmp && XDG_STATE_HOME='$STATE_DIR' NONO_ALLOW_PATHS=/tmp bash '$SCRIPT' -- cat /etc/hostname"
  [ "$status" -ne 0 ]
  [[ "$output" == *'"status":"enforced"'* ]]
  [[ "$output" == *"Permission denied"* || "$output" == *"permission denied"* ]]
  [[ "$output" != *"No such file"* ]]
}

@test "ENFORCED: the wrapped workload CAN write its allowed /tmp" {
  run bash -c "cd /tmp && XDG_STATE_HOME='$STATE_DIR' NONO_ALLOW_PATHS=/tmp bash '$SCRIPT' -- touch /tmp/fe-nono-allow-probe"
  [ "$status" -eq 0 ]
  [ -f /tmp/fe-nono-allow-probe ]
}

@test "FAIL-CLOSED: no enforcement -> non-zero exit, status unenforced, NO healthy heartbeat, NO landlock evidence" {
  run bash -c "cd /tmp && NONO_FORCE_FALLBACK=1 bash '$SCRIPT' -- cat /etc/hostname"
  [ "$status" -ne 0 ]
  [[ "$output" == *'"status":"unenforced"'* ]]
  [[ "$output" == *'"enforcement":"none"'* ]]
  # The lie the old script told must be gone:
  [[ "$output" != *'"status":"healthy"'* ]]
  [[ "$output" != *"landlock"* ]]
  [[ "$output" != *'"nono_capability_available":true'* ]]
  # And it must NOT have actually run the workload unconfined.
  [[ "$output" != *"executing unconfined"* ]]
}

@test "CHECK mode under enforcement exits 0 and reports enforced" {
  run bash -c "XDG_STATE_HOME='$STATE_DIR' bash '$SCRIPT' --check"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"enforced"'* ]]
}

@test "control: the SAME repo file is readable WITHOUT nono but DENIED under it (the deny is the sandbox, not the environment)" {
  # The script file lives in the repo, outside the /tmp allow-list. Reading it
  # with no sandbox succeeds; reading the identical path under nono is a kernel
  # EACCES — a matched pair that attributes the deny to Landlock, not DAC.
  local probe_file="$SCRIPT"
  if [[ "$probe_file" == /tmp/* ]]; then
    local common_git
    common_git="$(git rev-parse --git-common-dir 2>/dev/null || true)"
    if [ -n "$common_git" ] && [[ "$common_git" != /tmp/* ]]; then
      local parent_repo
      parent_repo="$(cd "$common_git/.." && pwd)"
      if [ -f "${parent_repo}/d2-signalloom/apps/fe-signalloom-agents/probe-nono-capability.sh" ]; then
        probe_file="${parent_repo}/d2-signalloom/apps/fe-signalloom-agents/probe-nono-capability.sh"
      fi
    fi
  fi
  run cat "$probe_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"probe-nono-capability"* || -n "$output" ]]

  run bash -c "cd /tmp && XDG_STATE_HOME='$STATE_DIR' NONO_ALLOW_PATHS=/tmp bash '$SCRIPT' -- cat '$probe_file'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Permission denied"* || "$output" == *"permission denied"* ]]
  [[ "$output" != *"No such file"* ]]
}
