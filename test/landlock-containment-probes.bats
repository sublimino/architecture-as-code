#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      landlock-containment-probes
# @target  nono/profiles/worktree-agent.json
# @doc     docs/slaat/p1-4/sentinel-landlock-confinement-adversarial-dossier.md
# @spec    SLAAT-P1-4
#
# SLAAT-P1-4 — Landlock sandbox syscall and filesystem path-restriction suite.
#
# Structural half (always runs, no skip): the shipped profile actually names
# the paths and rules this card's Objective requires. Live half: the
# PATH-RESTRICTION syscalls named verbatim in the card's Approach —
# openat(O_CREAT) on /etc, socket(AF_INET, SOCK_RAW), and reads of the named
# sensitive host paths — asserted against one run of
# scripts/test-agent-sandbox-escape.sh's JSON evidence, following the split
# this repo already uses in test/worktree-landlock-confinement.bats: a setup()
# skip takes the WHOLE FILE with it (obsidian-lint.bats read green for two
# commits that way), so nothing skips in setup() here either.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  PROFILE="${REPO_ROOT}/nono/profiles/worktree-agent.json"
  HARNESS="${REPO_ROOT}/scripts/test-agent-sandbox-escape.sh"
  PROOF_JSON="${BATS_FILE_TMPDIR:-/tmp}/landlock-containment-proof.json"
  HARNESS_LOG="${BATS_FILE_TMPDIR:-/tmp}/landlock-containment-harness.log"
  export PROFILE HARNESS PROOF_JSON HARNESS_LOG
  rm -f "${PROOF_JSON}" "${HARNESS_LOG}"

  if sandbox_available; then
    echo "# running the live escape battery once for the whole file..." >&3
    bash "${HARNESS}" --json "${PROOF_JSON}" >"${HARNESS_LOG}" 2>&1 || true
  else
    echo "# nono and/or Landlock unavailable — live tests will skip, structural tests still run" >&3
  fi
}

sandbox_available() {
  command -v nono >/dev/null 2>&1 || return 1
  grep -qw landlock /sys/kernel/security/lsm 2>/dev/null || return 1
  return 0
}

require_sandbox() {
  sandbox_available || skip "nono and/or Landlock unavailable on this host"
}

require_proof() {
  [[ -s "${PROOF_JSON}" ]] && return 0
  if sandbox_available; then
    echo "# live harness produced no artifact despite an available sandbox" >&3
    [[ -s "${HARNESS_LOG}" ]] && sed 's/^/#   /' "${HARNESS_LOG}" >&3
    return 1
  fi
  skip "no sandbox — live harness cannot run"
}

profile_query() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[k]
print(json.dumps(d))
' "${PROFILE}" "$1"
}

probe_field() {
  jq -r --arg id "$1" --arg f "$2" '.probes[] | select(.id==$id) | .[$f]' "${PROOF_JSON}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Structural: the profile names the paths this card's Objective requires
# ─────────────────────────────────────────────────────────────────────────────

@test "profile is parseable JSON" {
  [ -f "${PROFILE}" ]
  run python3 -m json.tool "${PROFILE}"
  [ "$status" -eq 0 ]
}

@test "profile's filesystem.deny names every sensitive path this card's Approach specifies" {
  local want path missing=""
  for want in "~/.ssh/" "~/.kube/config" "/etc/shadow"; do
    run profile_query 'filesystem.deny'
    [ "$status" -eq 0 ]
    case "$output" in
    *"$want"*) ;;
    *) missing="${missing}${want} " ;;
    esac
  done
  if [ -n "$missing" ]; then
    echo "filesystem.deny does not name: $missing"
    false
  fi
}

@test "profile blocks outbound network by default" {
  run profile_query 'network.block'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "profile's open_port allow-list never names a port for a raw/unfiltered egress bypass" {
  # 22/443/9418 are the git transport ports this profile is also required to
  # keep closed (see worktree-landlock-confinement.bats) — asserting here too
  # because a future edit could widen open_port without touching that file.
  run profile_query 'network.open_port'
  [ "$status" -eq 0 ]
  local bad
  bad="$(python3 -c '
import json, sys
ports = json.loads(sys.argv[1])
print(" ".join(str(p) for p in ports if p in (22, 443, 9418)))
' "$output")"
  [ -z "$bad" ] || { echo "open_port contains a transport-bypass port: $bad"; false; }
}

# ─────────────────────────────────────────────────────────────────────────────
# Live: the syscalls named in the card's Approach, against the shipped profile
# ─────────────────────────────────────────────────────────────────────────────

@test "LIVE: openat(O_CREAT) write to /etc is denied by the kernel" {
  require_sandbox
  require_proof
  [ "$(probe_field fs.etc-openat-o_creat-denied verdict)" = "pass" ]
}

@test "LIVE: socket(AF_INET, SOCK_RAW) is denied" {
  require_sandbox
  require_proof
  [ "$(probe_field net.raw-socket-denied-redundant-with-capability verdict)" = "pass" ]
  # Named "redundant-with-capability" in the evidence rather than attributed
  # to Landlock: recorded so this assertion cannot be misread as claiming
  # Landlock denies raw sockets when the real mechanism is a missing
  # CAP_NET_RAW, same uid, confined or not.
  [[ "$(probe_field net.raw-socket-denied-redundant-with-capability note)" == *"redundant-with-capability"* ]]
}

@test "LIVE: read of \$HOME/.kube/config is denied (clean Landlock differential — DAC alone permits it)" {
  require_sandbox
  require_proof
  [ "$(probe_field fs.kube-config-read-denied verdict)" = "pass" ]
}

@test "LIVE: read of /etc/shadow is denied" {
  require_sandbox
  require_proof
  [ "$(probe_field fs.shadow-read-denied-redundant-with-dac verdict)" = "pass" ]
}

@test "LIVE: read of \$HOME/.ssh/id_rsa is denied" {
  require_sandbox
  require_proof
  [ "$(probe_field fs.ssh-key-read-denied verdict)" = "pass" ]
}

@test "LIVE: a legitimate write inside the allow-listed worktree still succeeds (positive control)" {
  require_sandbox
  require_proof
  # Without this, every denial above would also "pass" against a sandbox that
  # simply refuses to execute anything at all.
  [ "$(probe_field control.allowed-write-inside-worktree-succeeds verdict)" = "pass" ]
}

@test "LIVE: non-allow-listed outbound port is denied, consistent with network.block" {
  require_sandbox
  require_proof
  [ "$(probe_field net.non-allowlisted-port-denied verdict)" = "pass" ]
}

@test "LIVE: the escape battery ran every probe it declared (no silent skip)" {
  require_sandbox
  require_proof
  local declared executed
  declared="$(jq -r '.totals.declared' "${PROOF_JSON}")"
  executed="$(jq -r '.totals.executed' "${PROOF_JSON}")"
  [ "$declared" -eq "$executed" ]
  [ "$executed" -gt 0 ]
}

@test "arity: this suite defines exactly the number of tests it declares" {
  local defined
  defined="$(grep -c '^@test ' "${BATS_TEST_FILENAME}")"
  [ "$defined" -eq 13 ]
}
