#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      cgroup-freeze-stun
# @target  d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go
# @doc     docs/signalloom/cgroup-v2-freeze-architecture.md
# @spec    CRKC-P1-2
#
# CRKC-P1-2 — Tier 0 kernel execution halt.
#
# Proves that `stun-sentinel` halts a CPU-burning container's execution
# in-kernel via cgroup-v2 `cgroup.freeze`, inside the 50ms deadline, and that
# the halt is real rather than merely reported.
#
# Structure. The expensive live cycle runs ONCE in setup_file() and writes a
# JSON artifact; each test then asserts one property of that artifact or makes
# its own independent kernel observation. Running the full freeze cycle per
# test would take minutes and would not add a single distinct assertion.
#
# On skipping. A suite that skips its way to green is worse than a red one.
# Every skip here is a genuine environment absence (no Kind cluster, no Go),
# it is announced, and `test_declared_count` asserts the suite's arity so a
# suite that silently stops loading tests — a committed conflict marker, a
# syntax error mid-file — is caught rather than read as a smaller pass.

# Number of tests this file is contracted to define. Asserted by the last
# test. `bats -f <pattern>` matching zero tests exits 0, and a suite that
# fails to parse partway through simply reports fewer tests; neither is
# distinguishable from success without this check.
DECLARED_TESTS=23

REPO_ROOT="$(cd -- "$(dirname -- "${BATS_TEST_FILENAME}")/.." && pwd)"
MODULE_DIR="${REPO_ROOT}/d2-signalloom/apps/stun-sentinel"
CLUSTER_CONTEXT="${CLUSTER_CONTEXT:-kind-osramp}"
KIND_NODE="${KIND_NODE:-osramp-control-plane}"
PROOF_JSON="${BATS_FILE_TMPDIR:-/tmp}/cgroup-freeze-proof.json"
HARNESS_LOG="${BATS_FILE_TMPDIR:-/tmp}/cgroup-freeze-harness.log"

have_cluster() {
  command -v docker >/dev/null 2>&1 || return 1
  command -v kubectl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  docker inspect "${KIND_NODE}" >/dev/null 2>&1 || return 1
  return 0
}

have_go() { command -v go >/dev/null 2>&1; }

# Read a jq expression out of the proof artifact.
proof() { jq -r "$1" "${PROOF_JSON}"; }

require_proof() {
  [[ -s "${PROOF_JSON}" ]] && return 0

  # If the cluster is absent, skipping is honest. If the cluster is PRESENT
  # and the harness still produced nothing, that is a failure — skipping it
  # would turn a broken live harness into a green suite, which is the exact
  # false-green this card exists to eliminate.
  if have_cluster; then
    echo "# live harness produced no artifact despite Kind node '${KIND_NODE}' being present" >&3
    [[ -s "${HARNESS_LOG}" ]] && sed 's/^/#   /' "${HARNESS_LOG}" >&3
    return 1
  fi
  skip "no Kind node '${KIND_NODE}' — live harness cannot run"
}

setup_file() {
  export REPO_ROOT MODULE_DIR CLUSTER_CONTEXT KIND_NODE PROOF_JSON HARNESS_LOG
  rm -f "${PROOF_JSON}" "${HARNESS_LOG}"

  if ! have_cluster; then
    echo "# no Kind node '${KIND_NODE}' — live tests will skip, unit tests still run" >&3
    return 0
  fi

  echo "# running the live freeze harness once for the whole file..." >&3
  # --keep leaves the daemon and namespace up so the independent kernel
  # observations below can talk to the same target the harness measured.
  KEEP=1 bash "${REPO_ROOT}/scripts/test-cgroup-freezer.sh" \
    --json "${PROOF_JSON}" --keep >"${HARNESS_LOG}" 2>&1 || true
}

teardown_file() {
  if have_cluster; then
    kubectl --context "${CLUSTER_CONTEXT}" delete namespace crkc-freeze-test \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
    docker exec "${KIND_NODE}" sh -c 'pkill -x stun-sentinel >/dev/null 2>&1; exit 0' || true
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Unit layer — the library, without a cluster
# ─────────────────────────────────────────────────────────────────────────────

@test "unit: cgroup freezer package tests pass with the race detector" {
  have_go || skip "go toolchain not installed"
  # -buildvcs=false: go build/test inside a git worktree fails with
  # "error obtaining VCS status: exit status 128".
  run env GOFLAGS=-buildvcs=false go test -C "${MODULE_DIR}" -race -count=1 ./pkg/cgroup/
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "unit: telemetry emitter tests pass with the race detector" {
  have_go || skip "go toolchain not installed"
  run env GOFLAGS=-buildvcs=false go test -C "${MODULE_DIR}" -race -count=1 ./pkg/telemetry/
  [ "$status" -eq 0 ]
}

@test "unit: daemon tests pass" {
  have_go || skip "go toolchain not installed"
  run env GOFLAGS=-buildvcs=false go test -C "${MODULE_DIR}" -race -count=1 ./cmd/stun-sentinel/
  [ "$status" -eq 0 ]
}

@test "unit: cgroup package statement coverage is at least 90 percent" {
  have_go || skip "go toolchain not installed"
  run env GOFLAGS=-buildvcs=false go test -C "${MODULE_DIR}" -cover -count=1 ./pkg/cgroup/
  [ "$status" -eq 0 ]
  local pct
  pct="$(printf '%s' "$output" | grep -o 'coverage: [0-9.]*%' | grep -o '[0-9.]*')"
  [ -n "$pct" ]
  awk -v p="$pct" 'BEGIN{exit !(p >= 90)}'
}

@test "unit: the freeze deadline constant is 50ms" {
  run grep -E 'DefaultFreezeDeadline = 50 \* time\.Millisecond' \
    "${MODULE_DIR}/pkg/cgroup/freezer.go"
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Live layer — the kernel
# ─────────────────────────────────────────────────────────────────────────────

@test "live: the harness ran every probe it declared" {
  have_cluster || skip "no Kind node '${KIND_NODE}'"
  require_proof
  local declared executed
  declared="$(proof '.probes.declared')"
  executed="$(proof '.probes.executed')"
  [ "$declared" -eq "$executed" ]
  [ "$executed" -gt 0 ]
}

@test "live: every harness probe passed" {
  have_cluster || skip "no Kind node '${KIND_NODE}'"
  require_proof
  if [ "$(proof '.probes.failed')" -ne 0 ]; then
    echo "# failing probes:" >&3
    jq -r '.probes.results[] | select(.status=="fail") | "#   \(.probe): \(.detail)"' "${PROOF_JSON}" >&3
    false
  fi
  [ "$(proof '.overall')" = "pass" ]
}

@test "live: stun-sentinel can write the host cgroup hierarchy" {
  have_cluster || skip "no Kind node '${KIND_NODE}'"
  require_proof
  [ "$(proof '.probes.results[] | select(.probe|startswith("P01")) | .status')" = "pass" ]
}

@test "live: the target container was burning CPU before the freeze" {
  have_cluster || skip "no Kind node '${KIND_NODE}'"
  require_proof
  # Without this the "CPU dropped to zero" assertion is vacuous: a container
  # that was never running also uses zero CPU.
  local running
  running="$(proof '.measurements.cpu_usec_running')"
  [ "$running" -gt 100000 ]
}

@test "live: cgroup.events reports frozen 1 after the stun" {
  have_cluster || skip "no Kind node '${KIND_NODE}'"
  require_proof
  [[ "$(proof '.measurements.cgroup_events_after')" == *"frozen 1"* ]]
  [[ "$(proof '.measurements.cgroup_events_before')" == *"frozen 0"* ]]
}

@test "live: container CPU utilisation drops to exactly zero while frozen" {
  have_cluster || skip "no Kind node '${KIND_NODE}'"
  require_proof
  # Exactly zero, not "low". A frozen task executes no instructions, so the
  # cgroup's usage_usec must not advance by a single microsecond.
  [ "$(proof '.measurements.cpu_usec_frozen')" -eq 0 ]
}

@test "live: freeze latency is inside the 50ms deadline" {
  have_cluster || skip "no Kind node '${KIND_NODE}'"
  require_proof
  local latency
  latency="$(proof '.measurements.freeze_latency_ms')"
  awk -v l="$latency" 'BEGIN{exit !(l < 50)}'
  awk -v l="$latency" 'BEGIN{exit !(l > 0)}'
}

@test "live: the daemon resolved the kind kubelet.slice cgroup layout" {
  have_cluster || skip "no Kind node '${KIND_NODE}'"
  require_proof
  # The card assumed /sys/fs/cgroup/kubepods.slice, which does not exist on
  # this cluster. This asserts the layout actually in use.
  local path
  path="$(proof '.target.cgroup_path')"
  [[ "$path" == *"kubelet.slice/kubelet-kubepods.slice"* ]]
  [[ "$path" == *".slice" ]]
}

@test "live: the pod UID in the cgroup path is systemd-mangled to underscores" {
  have_cluster || skip "no Kind node '${KIND_NODE}'"
  require_proof
  local uid path
  uid="$(proof '.target.pod_uid')"
  path="$(proof '.target.cgroup_path')"
  [[ "$path" == *"pod${uid//-/_}"* ]]
  # And the literal dashed form must NOT appear — that is the mangling.
  [[ "$path" != *"pod${uid}"* ]]
}

@test "live: resume without a governance credential is refused" {
  have_cluster || skip "no Kind node '${KIND_NODE}'"
  require_proof
  [ "$(proof '.probes.results[] | select(.probe|startswith("P11")) | .status')" = "pass" ]
  [[ "$(proof '.probes.results[] | select(.probe|startswith("P11")) | .detail')" == *"403"* ]]
}

@test "live: an authorised resume restores execution" {
  have_cluster || skip "no Kind node '${KIND_NODE}'"
  require_proof
  [ "$(proof '.measurements.cpu_usec_after_resume')" -gt 100000 ]
}

@test "live: a StunExecutionHalted telemetry record was published" {
  have_cluster || skip "no Kind node '${KIND_NODE}'"
  require_proof
  [ "$(proof '.signal_loom_telemetry.event')" = "StunExecutionHalted" ]
  [ "$(proof '.signal_loom_telemetry.tier')" = "tier-0-kernel-execution-state" ]
  [ "$(proof '.signal_loom_telemetry.frozen')" = "true" ]
  [ "$(proof '.signal_loom_telemetry.pid_count')" -gt 0 ]
  # The record must carry a parseable timestamp and the PID list.
  [ -n "$(proof '.signal_loom_telemetry.timestamp')" ]
  [ "$(proof '.signal_loom_telemetry.pids | length')" -gt 0 ]
}

@test "live: the cgroup-v2 freezer is a core interface, not a listed controller" {
  have_cluster || skip "no Kind node '${KIND_NODE}'"
  # The CRKC-P1-2 card states that cgroup.controllers contains "freezer".
  # It does not, on any cgroup-v2 host — the freezer was made a core
  # interface precisely so it needs no controller enablement. Asserting the
  # true behaviour here stops the claim being re-derived every phase.
  run docker exec "${KIND_NODE}" cat /sys/fs/cgroup/cgroup.controllers
  [ "$status" -eq 0 ]
  [[ "$output" != *"freezer"* ]]

  # And yet the control files are present on a non-root cgroup.
  run docker exec "${KIND_NODE}" test -f /sys/fs/cgroup/kubelet.slice/cgroup.freeze
  [ "$status" -eq 0 ]
  run docker exec "${KIND_NODE}" test -f /sys/fs/cgroup/kubelet.slice/cgroup.events
  [ "$status" -eq 0 ]
}

@test "live: the true root cgroup exposes no freezer, as the kernel specifies" {
  [ -d /sys/fs/cgroup ] || skip "no cgroup filesystem on this host"
  [ "$(stat -fc %T /sys/fs/cgroup)" = "cgroup2fs" ] || skip "host is not cgroup-v2 unified"

  # The root cgroup cannot be frozen, so it carries no cgroup.freeze. This is
  # asserted against the HOST root, not the node's — the node container has
  # its own cgroup namespace whose apparent root is a non-root cgroup and
  # therefore does expose the file.
  [ ! -e /sys/fs/cgroup/cgroup.freeze ]

  # A non-root cgroup on the same hierarchy does expose it. Without this
  # second half, the assertion above would also pass on a host with no
  # freezer support at all.
  local a_child
  a_child="$(find /sys/fs/cgroup -mindepth 1 -maxdepth 1 -type d -name '*.slice' | head -1)"
  [ -n "$a_child" ]
  [ -e "${a_child}/cgroup.freeze" ]
}

@test "live: frozen tasks park in the kernel freezer (wchan get_signal)" {
  have_cluster || skip "no Kind node '${KIND_NODE}'"
  require_proof
  # Recorded rather than asserted as 'D': cgroup-v2 places frozen tasks in
  # TASK_INTERRUPTIBLE, so /proc reports 'S', not the 'D' the cgroup-v1
  # freezer produced. wchan=get_signal is where __refrigerator() is entered
  # and is the discriminating signal. See the CRKC-P1-2 errata Deviations.
  local states
  states="$(proof '.measurements.frozen_task_states')"
  [ -n "$states" ]
  [[ "$states" == *"get_signal"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Artifact and arity
# ─────────────────────────────────────────────────────────────────────────────

@test "artifact: the committed proof artifact parses and records a pass" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local committed="${REPO_ROOT}/docs/signalloom/evidence/cgroup-freeze-proof.json"
  [ -f "$committed" ]
  run jq -e '.' "$committed"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.card' "$committed")" = "CRKC-P1-2" ]
  [ "$(jq -r '.overall' "$committed")" = "pass" ]
  [ "$(jq -r '.measurements.cpu_usec_frozen' "$committed")" -eq 0 ]
  awk -v l="$(jq -r '.measurements.freeze_latency_ms' "$committed")" 'BEGIN{exit !(l < 50)}'
}

@test "artifact: the benchmark report records a p99 under 25ms over 100 iterations" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local bench="${REPO_ROOT}/docs/signalloom/evidence/cgroup-freeze-benchmark.json"
  [ -f "$bench" ]
  run jq -e '.' "$bench"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.iterations' "$bench")" -ge 100 ]
  [ "$(jq -r '.verdict' "$bench")" = "pass" ]
  awk -v p="$(jq -r '.latency_ms.p99' "$bench")" 'BEGIN{exit !(p < 25)}'
  # A benchmark reporting exactly zero across every percentile did not run.
  awk -v m="$(jq -r '.latency_ms.max' "$bench")" 'BEGIN{exit !(m > 0)}'
}

@test "arity: this suite defines exactly the number of tests it declares" {
  # bats -f with a zero-match filter exits 0, and a suite that stops parsing
  # partway through reports fewer tests. Both read as success without this.
  local defined
  defined="$(grep -c '^@test ' "${BATS_TEST_FILENAME}")"
  if [ "$defined" -ne "$DECLARED_TESTS" ]; then
    echo "# suite defines ${defined} tests but declares ${DECLARED_TESTS}" >&3
    false
  fi
  [ "$defined" -eq "$DECLARED_TESTS" ]
}
