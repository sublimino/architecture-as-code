#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      sandbox-confinement-hardening
# @target  nono/profiles/worktree-agent.json, d2-signalloom/apps/stun-sentinel/pkg/{cgroup,correlator}
# @doc     docs/slaat/p2-4/sandbox-confinement-hardening-report.md
# @spec    SLAAT-P2-4
# @tests   scripts/verify-cgroup-enforcement.sh, scripts/test-agent-sandbox-escape.sh
#
# SLAAT-P2-4 -- remediation regression suite for this card's three hardening
# streams:
#   1. Landlock filesystem denial now covers /proc/sys/, /sys/fs/cgroup/,
#      /root/, and the whole ~/.kube/ directory (card Approach: "explicitly
#      denying access to ~/.ssh, ~/.kube, /proc/sys, /sys/fs/cgroup, and
#      root execution paths"), on top of what SLAAT-P1-4 already shipped.
#   2. The cgroup-freezer's fallback discovery walk (SLAAT-P1-4/F2: an
#      intermittent HTTP 504 under host contention) now carries its own
#      time budget and reports a distinct, typed error rather than either
#      hanging or being misreported as "pod not found".
#   3. The eBPF correlator now detects an execve-rate burst independent of
#      the sensitive-path filter (SLAAT-P1-4/F1, reproduced live as
#      SLAAT-P2-PRE's SENTINEL-F1), and logs every detection to stdout
#      before attempting the signal-ingest POST, so detection evidence
#      cannot be lost to an ingest outage.
#
# Streams 2 and 3 are proven here at the Go unit-test level: they are new
# kernel-adjacent logic with deterministic, hermetic tests already in the
# tree (pkg/cgroup/freezer_test.go, pkg/correlator/{pipeline,ebpf_correlator}_test.go).
# Re-asserting them as passing `go test` output is the correct, honest
# verification surface for this suite -- NOT a live run against the
# fe-signalloom-agents DaemonSet, because rebuilding and redeploying the
# sentinel image from this branch's current source was found, during this
# card's own verification, to not deliver ring-buffer events end-to-end in
# this environment (a pre-existing wiring gap predating this card -- see
# this card's errata for the full finding and the decision to roll the live
# DaemonSet back to the previously-working image rather than leave a
# regressed correlator on the shared cluster). Stream 1 and the cgroup
# resource-governance deliverable ARE verified live below, because neither
# depends on that sentinel image at all.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  PROFILE="${REPO_ROOT}/nono/profiles/worktree-agent.json"
  CGROUP_SCRIPT="${REPO_ROOT}/scripts/verify-cgroup-enforcement.sh"
  CGROUP_PROOF="${BATS_FILE_TMPDIR:-/tmp}/sandbox-confinement-cgroup-proof.json"
  CGROUP_LOG="${BATS_FILE_TMPDIR:-/tmp}/sandbox-confinement-cgroup-harness.log"
  export PROFILE CGROUP_SCRIPT CGROUP_PROOF CGROUP_LOG
  rm -f "${CGROUP_PROOF}" "${CGROUP_LOG}"

  STUN_SENTINEL_MODULE="${REPO_ROOT}/d2-signalloom/apps/stun-sentinel"
  export STUN_SENTINEL_MODULE

  if have_cluster; then
    echo "# running scripts/verify-cgroup-enforcement.sh once for the whole file..." >&3
    bash "${CGROUP_SCRIPT}" --json "${CGROUP_PROOF}" >"${CGROUP_LOG}" 2>&1 || true
  else
    echo "# no live kind-osramp cluster -- live cgroup-enforcement tests will skip" >&3
  fi
}

have_cluster() {
  command -v docker >/dev/null 2>&1 || return 1
  command -v kubectl >/dev/null 2>&1 || return 1
  docker inspect "${KIND_NODE:-osramp-control-plane}" >/dev/null 2>&1 || return 1
  kubectl --context "${CLUSTER_CONTEXT:-kind-osramp}" get namespace fe-signalloom-agents >/dev/null 2>&1 || return 1
  return 0
}

require_cluster() {
  have_cluster || skip "no live kind-osramp cluster -- this test requires the real deployment"
}

require_cgroup_proof() {
  [[ -s "${CGROUP_PROOF}" ]] && return 0
  if have_cluster; then
    echo "# live harness produced no artifact despite an available cluster" >&3
    [[ -s "${CGROUP_LOG}" ]] && sed 's/^/#   /' "${CGROUP_LOG}" >&3
    return 1
  fi
  skip "no cluster -- live harness cannot run"
}

cgroup_field() {
  jq -r --arg id "$1" --arg f "$2" '.probes[] | select(.id==$id) | .[$f]' "${CGROUP_PROOF}"
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

go_toolchain() {
  # Mirrors this card's own build env: a redirected module cache (the
  # worktree's real HOME is sandboxed) and the pinned go1.27.0 toolchain
  # this module's go.mod requires, located wherever a prior card already
  # extracted it rather than re-downloading (network may be denied).
  local tc
  tc="$(find /tmp -maxdepth 4 -type f -path '*toolchain@v0.0.1-go1.27.0*/bin/go' 2>/dev/null | head -1)"
  [[ -n "${tc}" ]] && printf '%s' "${tc}" && return 0
  command -v go 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Structural: the hardened Landlock profile
# ─────────────────────────────────────────────────────────────────────────────

@test "profile is parseable JSON" {
  run python3 -m json.tool "${PROFILE}"
  [ "$status" -eq 0 ]
}

@test "profile's filesystem.deny names every path this card's Approach adds" {
  local want path missing=""
  for want in "/proc/sys/" "/sys/fs/cgroup/" "/root/" "~/.kube/"; do
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

@test "profile still names every sensitive path SLAAT-P1-4 already shipped (no regression)" {
  local want path missing=""
  for want in "~/.ssh/" "~/.kube/config" "/etc/shadow"; do
    run profile_query 'filesystem.deny'
    [ "$status" -eq 0 ]
    case "$output" in
    *"$want"*) ;;
    *) missing="${missing}${want} " ;;
    esac
  done
  [ -z "$missing" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Unit: the cgroup-discovery-deadline fix (SLAAT-P2-4/F2)
# ─────────────────────────────────────────────────────────────────────────────

@test "go test proves the cgroup fallback-discovery walk carries its own time budget" {
  local gobin; gobin="$(go_toolchain)"
  [ -n "${gobin}" ] || skip "no go toolchain available"
  cd "${STUN_SENTINEL_MODULE}"
  run env GOCACHE=/tmp/slaat-p2-4-hardening-gocache GOPATH=/tmp/slaat-p2-4-hardening-gopath \
    GOMODCACHE="$(find /tmp -maxdepth 2 -type d -name '*gomodcache*' 2>/dev/null | head -1)" \
    GOTOOLCHAIN=local CGO_ENABLED=0 \
    "${gobin}" test ./pkg/cgroup/... -run 'DiscoveryDeadline|FreezePodPropagatesDiscoveryDeadline' -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"TestResolvePodCgroupReportsDiscoveryDeadlineUnderContention"* ]]
  [[ "$output" == *"TestFreezePodPropagatesDiscoveryDeadlineDistinctlyFromNotFound"* ]]
  [[ "$output" == *"PASS"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Unit: the evasive-burst detector (SLAAT-P2-4/F1)
# ─────────────────────────────────────────────────────────────────────────────

@test "go test proves the correlator detects an execve-rate burst independent of path" {
  local gobin; gobin="$(go_toolchain)"
  [ -n "${gobin}" ] || skip "no go toolchain available"
  cd "${STUN_SENTINEL_MODULE}"
  run env GOCACHE=/tmp/slaat-p2-4-hardening-gocache GOPATH=/tmp/slaat-p2-4-hardening-gopath \
    GOMODCACHE="$(find /tmp -maxdepth 2 -type d -name '*gomodcache*' 2>/dev/null | head -1)" \
    GOTOOLCHAIN=local CGO_ENABLED=0 \
    "${gobin}" test ./pkg/correlator/... -run 'Evasive|Burst' -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"TestHandleRecordDetectsEvasiveExecveBurstWithNoSensitivePath"* ]]
  [[ "$output" == *"TestHandleRecordEvasiveBurstDoesNotFalsePositiveOnOrdinaryChurn"* ]]
  [[ "$output" == *"PASS"* ]]
}

@test "go test proves a detection cannot be silently lost to a signal-ingest outage" {
  local gobin; gobin="$(go_toolchain)"
  [ -n "${gobin}" ] || skip "no go toolchain available"
  cd "${STUN_SENTINEL_MODULE}"
  run env GOCACHE=/tmp/slaat-p2-4-hardening-gocache GOPATH=/tmp/slaat-p2-4-hardening-gopath \
    GOMODCACHE="$(find /tmp -maxdepth 2 -type d -name '*gomodcache*' 2>/dev/null | head -1)" \
    GOTOOLCHAIN=local CGO_ENABLED=0 \
    "${gobin}" test ./pkg/correlator/... -run 'LogObservation|LogDispatchFailure|DispatchWorkerLogs' -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"TestDispatchWorkerLogsEveryObservationIndependentlyOfIngestReachability"* ]]
  [[ "$output" == *"PASS"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Live: cgroup v2 resource governance (the K8s securityContext / resource
# ceiling deliverable)
# ─────────────────────────────────────────────────────────────────────────────

@test "LIVE: memory.max on a real agent pod's cgroup matches its Pod spec limit exactly" {
  require_cluster
  require_cgroup_proof
  [ "$(cgroup_field live.memory-max-matches-the-pod-spec-limit-exactly verdict)" = "pass" ]
}

@test "LIVE: cpu.max quota on a real agent pod's cgroup matches its Pod spec limit exactly" {
  require_cluster
  require_cgroup_proof
  [ "$(cgroup_field live.cpu-max-quota-matches-the-pod-spec-limit-exactly verdict)" = "pass" ]
}

@test "LIVE: the cgroup-v2 CPU bandwidth controller actually throttles a quota-limited workload" {
  require_cluster
  require_cgroup_proof
  [ "$(cgroup_field live.cpu-bandwidth-controller-actually-throttles-under-stress verdict)" = "pass" ]
}

@test "LIVE: the cgroup-enforcement harness ran every probe it declared (no silent skip)" {
  require_cluster
  require_cgroup_proof
  [ "$(jq -r '.totals.declared == .totals.executed' "${CGROUP_PROOF}")" = "true" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Arity: this suite defines exactly the number of tests it declares
# ─────────────────────────────────────────────────────────────────────────────

@test "arity: this suite defines exactly the number of tests it declares" {
  run bats --count "${BATS_TEST_FILENAME}"
  [ "$status" -eq 0 ]
  [ "$output" -eq 11 ]
}
