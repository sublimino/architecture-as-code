#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      landlock-adversarial-escape
# @target  nono/profiles/worktree-agent.json
# @doc     docs/slaat/p1-4/sentinel-landlock-confinement-adversarial-dossier.md
# @spec    SLAAT-P1-4
#
# SLAAT-P1-4 — Landlock sandbox ESCAPE-SCENARIO suite: symlink traversal,
# /proc inspection, ptrace attachment, unshare namespace creation, forbidden
# fd inheritance, and a background-thread exfiltration race. Complements
# test/landlock-containment-probes.bats, which covers the literal syscall
# probes (O_CREAT on /etc, raw sockets) and the named sensitive-path reads —
# this file covers the SCENARIO-shaped attacks from the card's Objective and
# Approach that are not simple single-syscall checks.
#
# Both files assert against ONE run of scripts/test-agent-sandbox-escape.sh —
# each runs it independently in its own setup_file() (not shared across
# files) so either suite is green or red on its own, matching the convention
# every other live suite in this repo already uses
# (test/cgroup-freeze-stun.bats, test/worktree-landlock-confinement.bats).
#
# Also runs scripts/probe-sentinel-evasion.sh once, live, against the
# deployed sentinel — the eBPF telemetry half of this card's adversarial
# battery, reported here because it shares this file's "can the kernel-level
# defense be evaded" framing.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  ESCAPE_HARNESS="${REPO_ROOT}/scripts/test-agent-sandbox-escape.sh"
  EVASION_HARNESS="${REPO_ROOT}/scripts/probe-sentinel-evasion.sh"
  ESCAPE_PROOF="${BATS_FILE_TMPDIR:-/tmp}/landlock-adversarial-escape-proof.json"
  EVASION_PROOF="${BATS_FILE_TMPDIR:-/tmp}/sentinel-evasion-proof.json"
  ESCAPE_LOG="${BATS_FILE_TMPDIR:-/tmp}/landlock-adversarial-escape-harness.log"
  EVASION_LOG="${BATS_FILE_TMPDIR:-/tmp}/sentinel-evasion-harness.log"
  export ESCAPE_HARNESS EVASION_HARNESS ESCAPE_PROOF EVASION_PROOF ESCAPE_LOG EVASION_LOG
  rm -f "${ESCAPE_PROOF}" "${EVASION_PROOF}" "${ESCAPE_LOG}" "${EVASION_LOG}"

  if sandbox_available; then
    echo "# running the live escape battery once for the whole file..." >&3
    bash "${ESCAPE_HARNESS}" --json "${ESCAPE_PROOF}" >"${ESCAPE_LOG}" 2>&1 || true
  else
    echo "# nono and/or Landlock unavailable — escape-scenario tests will skip" >&3
  fi

  if have_live_cluster; then
    echo "# running the live sentinel evasion probe once for the whole file..." >&3
    bash "${EVASION_HARNESS}" --json "${EVASION_PROOF}" >"${EVASION_LOG}" 2>&1 || true
  else
    echo "# no live kind-osramp cluster — eBPF evasion tests will skip" >&3
  fi
}

sandbox_available() {
  command -v nono >/dev/null 2>&1 || return 1
  grep -qw landlock /sys/kernel/security/lsm 2>/dev/null || return 1
  return 0
}

have_live_cluster() {
  command -v docker >/dev/null 2>&1 || return 1
  command -v kubectl >/dev/null 2>&1 || return 1
  docker inspect osramp-control-plane >/dev/null 2>&1 || return 1
  kubectl --context kind-osramp get namespace fe-signalloom-agents >/dev/null 2>&1 || return 1
  return 0
}

require_sandbox() {
  sandbox_available || skip "nono and/or Landlock unavailable on this host"
}

require_escape_proof() {
  [[ -s "${ESCAPE_PROOF}" ]] && return 0
  if sandbox_available; then
    echo "# live escape harness produced no artifact despite an available sandbox" >&3
    [[ -s "${ESCAPE_LOG}" ]] && sed 's/^/#   /' "${ESCAPE_LOG}" >&3
    return 1
  fi
  skip "no sandbox — live harness cannot run"
}

require_live_cluster() {
  have_live_cluster || skip "no live kind-osramp cluster with stun-sentinel deployed"
}

require_evasion_proof() {
  [[ -s "${EVASION_PROOF}" ]] && return 0
  if have_live_cluster; then
    echo "# live evasion harness produced no artifact despite an available cluster" >&3
    [[ -s "${EVASION_LOG}" ]] && sed 's/^/#   /' "${EVASION_LOG}" >&3
    return 1
  fi
  skip "no live cluster — evasion probe cannot run"
}

escape_field() {
  jq -r --arg id "$1" --arg f "$2" '.probes[] | select(.id==$id) | .[$f]' "${ESCAPE_PROOF}"
}

evasion_field() {
  jq -r --arg id "$1" --arg f "$2" '.probes[] | select(.id==$id) | .[$f]' "${EVASION_PROOF}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Live: symlink traversal
# ─────────────────────────────────────────────────────────────────────────────

@test "LIVE: a symlink inside the allowed worktree pointing at a denied target is still denied" {
  require_sandbox
  require_escape_proof
  [ "$(escape_field fs.symlink-traversal-denied verdict)" = "pass" ]
}

@test "LIVE: a symlink to a baseline system-read path still resolves (control, not a leak)" {
  require_sandbox
  require_escape_proof
  [ "$(escape_field fs.symlink-to-baseline-system-read-succeeds verdict)" = "pass" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Live: /proc inspection
# ─────────────────────────────────────────────────────────────────────────────

@test "LIVE: reading another process's /proc/<pid>/environ is denied" {
  require_sandbox
  require_escape_proof
  [ "$(escape_field proc.other-pid-environ-denied verdict)" = "pass" ]
}

@test "LIVE: self-introspection via /proc/self is still permitted (not an over-broad lockdown)" {
  require_sandbox
  require_escape_proof
  [ "$(escape_field proc.self-fd-introspection verdict)" = "pass" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Live: ptrace attachment
# ─────────────────────────────────────────────────────────────────────────────

@test "LIVE: ptrace-attach to an unrelated process is denied" {
  require_sandbox
  require_escape_proof
  [ "$(escape_field proc.ptrace-attach-unrelated-pid-denied verdict)" = "pass" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Live: unshare namespace creation
# ─────────────────────────────────────────────────────────────────────────────

@test "LIVE: a process that unshares into a new PID namespace gains no new filesystem access" {
  require_sandbox
  require_escape_proof
  [ "$(escape_field ns.unshare-does-not-widen-fs-access verdict)" = "pass" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Live: child process inheritance and a background-thread exfiltration race
# ─────────────────────────────────────────────────────────────────────────────

@test "LIVE: a child process spawned by a confined shell inherits the same confinement" {
  require_sandbox
  require_escape_proof
  [ "$(escape_field proc.child-process-inherits-confinement verdict)" = "pass" ]
}

@test "LIVE: a background subshell racing the Landlock ruleset has no exfiltration window" {
  require_sandbox
  require_escape_proof
  [ "$(escape_field proc.background-thread-race-no-exfil-window verdict)" = "pass" ]
}

@test "LIVE: the escape battery's positive control (allowed write) succeeded" {
  require_sandbox
  require_escape_proof
  [ "$(escape_field control.allowed-write-inside-worktree-succeeds verdict)" = "pass" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Live: eBPF telemetry evasion (sentinel)
# ─────────────────────────────────────────────────────────────────────────────

@test "LIVE: the live sentinel's eBPF probe is confirmed socket-state-only by static source inspection" {
  require_live_cluster
  require_evasion_proof
  [ "$(evasion_field static.deployed-probe-is-socket-state-only verdict)" = "pass" ]
}

@test "LIVE: a 200-process-spawn + unshare(CLONE_NEWPID) burst generates zero syscall-shaped telemetry" {
  require_live_cluster
  require_evasion_proof
  # The headline finding of this card's eBPF half: not a bypass, an absence.
  [ "$(evasion_field live.evasion-burst-generates-no-syscall-telemetry verdict)" = "pass" ]
}

@test "LIVE: the TCP-flow instrumented surface remains live and counting (control)" {
  require_live_cluster
  require_evasion_proof
  # Without this, "no telemetry for the burst" could mean "nothing is
  # instrumented at all", a different and worse finding than the one made.
  [ "$(evasion_field live.control-tcp-connect-stays-within-instrumented-surface verdict)" = "pass" ]
}

@test "LIVE: the sentinel daemon itself is healthy throughout" {
  require_live_cluster
  require_evasion_proof
  [ "$(evasion_field live.sentinel-healthz-reachable verdict)" = "pass" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Skip accounting
# ─────────────────────────────────────────────────────────────────────────────

@test "the LIVE half is not silently skipped on a host that can run it" {
  local declared
  declared="$(grep -c '^@test "LIVE: ' "${BATS_TEST_FILENAME}")"
  [ "$declared" -ge 10 ]

  if ! sandbox_available && ! have_live_cluster; then
    echo "NOTE: ${declared} LIVE tests were skipped — no sandbox and no live cluster." >&3
    return 0
  fi

  run bats --count --filter '^LIVE: ' "${BATS_TEST_FILENAME}"
  [ "$status" -eq 0 ]
  [ "$output" -eq "$declared" ] || {
    echo "filter selected ${output} LIVE test(s) but ${declared} are declared." >&2
    false
  }
}

@test "arity: this suite defines exactly the number of tests it declares" {
  local defined
  defined="$(grep -c '^@test ' "${BATS_TEST_FILENAME}")"
  [ "$defined" -eq 15 ]
}
