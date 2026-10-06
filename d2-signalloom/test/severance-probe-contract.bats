#!/usr/bin/env bats
# Pure, fixture-driven contract tests for the STUN severance verdict.
# No cluster, pod process, or network is touched by this suite.
#
# @id      severance-probe-contract
# @target  scripts/stun/severance-verdict.sh
# @doc     docs/signalloom/severance-probe-design.md
# @spec    docs/signalloom/evidence/severance-probe-contract.json
# @lib     (none)
#
# Recovered 2026-10-06 from the abandoned integration/stun-under-flux mission
# (tip 5482e79b, STUN-P4-1/P4-2). The mission's live-cluster severance claims
# (Cilium quarantine, admin-deny, the legacy-named probe DaemonSet) did not close —
# docs/signalloom/stun-dod-evidence.md records all of P4-1 and P6-1 as FAILED —
# and the base has since proven network severance a different way (direct tc
# filter + netlink veth drop: test/tc-ebpf-drop.bats, CRKC-P1-3). This file is
# the one piece of the mission that is CNI-agnostic and still untested
# anywhere else on the base: a pure, offline classifier that turns a closed
# witness/target traffic-pair observation into SEVERED / SURVIVED / UNVERIFIED,
# refusing to default to a pass on any malformed, incomplete or
# internally-contradictory input. Nothing else on the base does this
# evidence-shape validation, so it is ported verbatim and not superseded.

setup() {
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  classifier="$root/scripts/stun/severance-verdict.sh"
  fixtures="$root/d2-signalloom/test/fixtures/severance"
  schema="$root/docs/signalloom/evidence/severance-probe-contract.json"
  mutation_index=0
}

classify() {
  local record="$1"
  run bash -c '"$1" < "$2"' _ "$classifier" "$record"
}

mutate_severed() {
  local filter="$1"
  mutation_index=$((mutation_index + 1))
  local output="$BATS_TEST_TMPDIR/mutated-${mutation_index}.json"
  jq "$filter" "$fixtures/severed.json" >"$output"
  printf '%s\n' "$output"
}

assert_unverified() {
  local record="$1"
  classify "$record"
  [ "$status" -eq 3 ]
  [ "$output" = "UNVERIFIED" ]
}

@test "SEVERANCE-CONTRACT witness alive plus target silent is SEVERED" {
  classify "$fixtures/severed.json"
  [ "$status" -eq 0 ]
  [ "$output" = "SEVERED" ]
}

@test "SEVERANCE-CONTRACT both streams alive is SURVIVED" {
  classify "$fixtures/survived.json"
  [ "$status" -eq 0 ]
  [ "$output" = "SURVIVED" ]
}

@test "SEVERANCE-CONTRACT both streams silent is UNVERIFIED" {
  assert_unverified "$fixtures/unverified-both-silent.json"
}

@test "SEVERANCE-CONTRACT truncated JSON is UNVERIFIED" {
  assert_unverified "$fixtures/truncated.json"
}

@test "SEVERANCE-CONTRACT missing witnessStream is UNVERIFIED" {
  record="$(mutate_severed 'del(.witnessStream)')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT empty witness arrivals are UNVERIFIED" {
  record="$(mutate_severed '.witnessStream.arrivals = [] | .verdict = "UNVERIFIED" | .verdictReason = "insufficient-or-conflicting-evidence"')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT missing required targetUID is UNVERIFIED" {
  record="$(mutate_severed 'del(.targetUID)')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT frozen false plus target silent is UNVERIFIED" {
  record="$(mutate_severed '.frozen = false | .verdict = "UNVERIFIED" | .verdictReason = "insufficient-or-conflicting-evidence"')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT changed restartCount is UNVERIFIED" {
  record="$(mutate_severed '.restartCount.after = 1 | .verdict = "UNVERIFIED" | .verdictReason = "insufficient-or-conflicting-evidence"')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT disagreeing verdict field is rejected" {
  record="$(mutate_severed '.verdict = "SURVIVED"')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT disagreeing verdictReason field is rejected" {
  record="$(mutate_severed '.verdictReason = "witness-healthy-target-arrivals-observed"')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT null witness arrival timestamp is UNVERIFIED" {
  record="$(mutate_severed '.witnessStream.arrivals[0].receivedAt = null | .verdict = "UNVERIFIED" | .verdictReason = "insufficient-or-conflicting-evidence"')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT witness sequence gap is UNVERIFIED" {
  record="$(mutate_severed '.witnessStream.arrivals[5].sequence = 99 | .verdict = "UNVERIFIED" | .verdictReason = "insufficient-or-conflicting-evidence"')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT witness sequence must begin at one" {
  record="$(mutate_severed '.witnessStream.arrivals |= map(.sequence += 1) | .verdict = "UNVERIFIED" | .verdictReason = "insufficient-or-conflicting-evidence"')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT witness sharing target identity is UNVERIFIED" {
  record="$(mutate_severed '.witnessStream.senderPod = .targetPod | .verdict = "UNVERIFIED" | .verdictReason = "insufficient-or-conflicting-evidence"')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT streams naming different receivers are UNVERIFIED" {
  record="$(mutate_severed '.witnessStream.receiverPod = "fe-signalloom-agents/not-the-receiver" | .verdict = "UNVERIFIED" | .verdictReason = "insufficient-or-conflicting-evidence"')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT fourth verdict value is UNVERIFIED" {
  record="$(mutate_severed '.verdict = "UNKNOWN"')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT unknown top-level field is UNVERIFIED" {
  record="$(mutate_severed '.defaultPass = true')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT target silence with conntrack present is UNVERIFIED" {
  record="$(mutate_severed '.conntrackAfter.present = true | .verdict = "UNVERIFIED" | .verdictReason = "insufficient-or-conflicting-evidence"')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT target silence without new drops is UNVERIFIED" {
  record="$(mutate_severed '.tcDropCounters.afterPackets = .tcDropCounters.beforePackets | .verdict = "UNVERIFIED" | .verdictReason = "insufficient-or-conflicting-evidence"')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT empty object cannot default to a pass" {
  record="$BATS_TEST_TMPDIR/empty-object.json"
  printf '{}\n' >"$record"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT record lacking verdict-bearing fields is UNVERIFIED" {
  record="$(mutate_severed '{witnessStream: .witnessStream}')"
  assert_unverified "$record"
}

@test "SEVERANCE-CONTRACT schema closes verdict vocabulary to three values" {
  run jq -er '.properties.verdict.enum == ["SEVERED", "SURVIVED", "UNVERIFIED"]' "$schema"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "SEVERANCE-CONTRACT schema requires witness and restart evidence" {
  run jq -er '(.required | index("witnessStream")) != null and (.required | index("restartCount")) != null' "$schema"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}
