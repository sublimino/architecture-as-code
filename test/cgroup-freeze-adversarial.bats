#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      cgroup-freeze-adversarial
# @target  d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go
# @doc     docs/slaat/p1-4/sentinel-landlock-confinement-adversarial-dossier.md
# @spec    SLAAT-P1-4
#
# SLAAT-P1-4 — cgroup-freeze containment under adversarial load.
#
# Complements test/cgroup-freeze-stun.bats (CRKC-P1-2's functional proof that
# freeze/resume works against a plain CPU-burning container). This file
# attacks it: bounded fork-bomb-shaped PID churn, a child that has escaped
# into its own PID namespace via unshare(CLONE_NEWPID), concurrent overlapping
# freeze+resume calls, and a tight memory.max to test the kernel OOM killer
# independent of the sentinel.
#
# The expensive live cycle runs ONCE in setup_file() against an ISOLATED
# stun-sentinel instance that scripts/stress-agent-cgroups.sh builds and
# installs itself (own namespace, own port, own credentials) — it never
# touches the live deployed signalloom-stun-sentinel pod or any other card's
# fixtures. Each test then asserts one property of the resulting artifact,
# matching the structure test/cgroup-freeze-stun.bats already established.

# shellcheck source=../scripts/lib/live-gate.sh
source "${BATS_TEST_DIRNAME}/../scripts/lib/live-gate.sh"

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  HARNESS="${REPO_ROOT}/scripts/stress-agent-cgroups.sh"
  PROOF_JSON="${BATS_FILE_TMPDIR:-/tmp}/cgroup-freeze-adversarial-proof.json"
  HARNESS_LOG="${BATS_FILE_TMPDIR:-/tmp}/cgroup-freeze-adversarial-harness.log"
  export HARNESS PROOF_JSON HARNESS_LOG
  rm -f "${PROOF_JSON}" "${HARNESS_LOG}"

  if have_cluster; then
    echo "# running the live adversarial cgroup battery once for the whole file..." >&3
    bash "${HARNESS}" --json "${PROOF_JSON}" >"${HARNESS_LOG}" 2>&1 || true
  else
    echo "# no live kind-osramp cluster — live tests will skip" >&3
  fi
}

have_cluster() {
  command -v docker >/dev/null 2>&1 || return 1
  command -v kubectl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  command -v go >/dev/null 2>&1 || return 1
  # Live is opt-in (SLDC_LIVE=1) and must be reachable through KUBECONFIG;
  # `docker inspect` alone ignored KUBECONFIG=/dev/null and reached the node.
  sldc_live_gate kind-osramp osramp-control-plane || return 1
  return 0
}

require_proof() {
  [[ -s "${PROOF_JSON}" ]] && return 0
  if have_cluster; then
    echo "# live harness produced no artifact despite a Kind node being present" >&3
    [[ -s "${HARNESS_LOG}" ]] && sed 's/^/#   /' "${HARNESS_LOG}" >&3
    return 1
  fi
  skip "no Kind node 'osramp-control-plane' — live harness cannot run"
}

probe_field() {
  jq -r --arg id "$1" --arg f "$2" '.probes[] | select(.id==$id) | .[$f]' "${PROOF_JSON}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Live: the workload is real, under heavy PID churn, not a no-op
# ─────────────────────────────────────────────────────────────────────────────

@test "live: the harness ran every probe it declared" {
  have_cluster || skip "no Kind node 'osramp-control-plane'"
  require_proof
  local declared executed
  declared="$(jq -r '.totals.declared' "${PROOF_JSON}")"
  executed="$(jq -r '.totals.executed' "${PROOF_JSON}")"
  [ "$declared" -eq "$executed" ]
  [ "$executed" -gt 0 ]
}

@test "live: the target is under genuinely heavy PID churn before the freeze" {
  have_cluster || skip "no Kind node 'osramp-control-plane'"
  require_proof
  [ "$(probe_field stress.target-under-heavy-pid-churn-before-freeze verdict)" = "pass" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Live: auth — /stun is bearer-gated against this binary
# ─────────────────────────────────────────────────────────────────────────────

@test "live: an unauthenticated freeze call is refused with 401" {
  have_cluster || skip "no Kind node 'osramp-control-plane'"
  require_proof
  [ "$(probe_field auth.unauthenticated-freeze-refused verdict)" = "pass" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Live: freeze under load
# ─────────────────────────────────────────────────────────────────────────────

@test "live: an authenticated freeze under heavy fork-storm load still succeeds" {
  have_cluster || skip "no Kind node 'osramp-control-plane'"
  require_proof
  [ "$(probe_field stress.authenticated-freeze-under-load-succeeds verdict)" = "pass" ]
}

@test "live: freeze latency stays under the 50ms deadline under fork-storm load" {
  have_cluster || skip "no Kind node 'osramp-control-plane'"
  require_proof
  [ "$(probe_field stress.freeze-latency-under-fork-storm-stays-under-50ms verdict)" = "pass" ]
}

@test "live: the kernel confirms frozen=1 under load (read directly, not via the daemon)" {
  have_cluster || skip "no Kind node 'osramp-control-plane'"
  require_proof
  [ "$(probe_field stress.kernel-confirms-frozen-1-under-load verdict)" = "pass" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Live: the named failure mode — unshare(CLONE_NEWPID) as an escape attempt
# ─────────────────────────────────────────────────────────────────────────────

@test "live: unshare(CLONE_NEWPID) is denied under the target's default (non-elevated) capabilities" {
  have_cluster || skip "no Kind node 'osramp-control-plane'"
  require_proof
  [ "$(probe_field ns.unshare-denied-by-default-capabilities verdict)" = "pass" ]
}

@test "live: a process that DID unshare into a new PID namespace is still frozen (the adversarial payoff)" {
  have_cluster || skip "no Kind node 'osramp-control-plane'"
  require_proof
  [ "$(probe_field ns.unshare-escape-target-frozen-despite-elevated-capability verdict)" = "pass" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Live: concurrent/racing freeze+resume calls
# ─────────────────────────────────────────────────────────────────────────────

@test "live: two concurrent, unserialised resume calls are handled without the daemon crashing" {
  have_cluster || skip "no Kind node 'osramp-control-plane'"
  require_proof
  [ "$(probe_field stress.concurrent-resume-race-handled-without-crash verdict)" = "pass" ]
}

@test "live: the daemon survives the concurrent-resume race and stays healthy" {
  have_cluster || skip "no Kind node 'osramp-control-plane'"
  require_proof
  [ "$(probe_field stress.daemon-survives-concurrent-resume-race verdict)" = "pass" ]
}

@test "live: execution actually resumes after the race (not left stuck frozen)" {
  have_cluster || skip "no Kind node 'osramp-control-plane'"
  require_proof
  [ "$(probe_field stress.authorised-resume-restores-execution-after-race verdict)" = "pass" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Live: OOM — independent of the sentinel, the kernel's own memory controller
# ─────────────────────────────────────────────────────────────────────────────

@test "live: the kernel's memory cgroup kills a container that over-allocates past memory.max" {
  have_cluster || skip "no Kind node 'osramp-control-plane'"
  require_proof
  [ "$(probe_field oom.memory-cgroup-kills-the-overallocating-container verdict)" = "pass" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Skip accounting and arity
# ─────────────────────────────────────────────────────────────────────────────

@test "the live half is not silently skipped on a host that can run it" {
  local declared
  declared="$(grep -c '^@test "live: ' "${BATS_TEST_FILENAME}")"
  [ "$declared" -ge 10 ]

  if ! have_cluster; then
    echo "NOTE: ${declared} live tests were skipped — no Kind node 'osramp-control-plane'." >&3
    return 0
  fi

  run bats --count --filter '^live: ' "${BATS_TEST_FILENAME}"
  [ "$status" -eq 0 ]
  [ "$output" -eq "$declared" ] || {
    echo "filter selected ${output} live test(s) but ${declared} are declared." >&2
    false
  }
}

@test "arity: this suite defines exactly the number of tests it declares" {
  local defined
  defined="$(grep -c '^@test ' "${BATS_TEST_FILENAME}")"
  [ "$defined" -eq 14 ]
}
