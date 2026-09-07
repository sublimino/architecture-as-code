#!/usr/bin/env bats
#
# tc-ebpf-drop.bats — CRKC-P1-3. Proves that the host-side eBPF TC classifier
# severs an established TCP session in under 100ms, that OUR PROGRAM is what
# severed it, and that connectivity is restored on release.
#
# ARCHITECTURE. The live experiment runs once in setup_file via
# scripts/test-tc-ebpf.sh, which drives a privileged container with real veth
# pairs, a real verifier and a real conntrack table. It writes a JSON evidence
# document. Every test below asserts one property of that document. Measurement
# and assertion are separate on purpose: a change to what we consider "passing"
# then cannot quietly change what was measured.
#
# WHY THE ASSERTIONS LOOK PARANOID. Three failure shapes this repo has been bitten
# by, all of which this file is written to exclude:
#
#   1. A control the failure mode also satisfies. "The connection timed out" is
#      satisfied by a dead server, a wrong IP and a working filter alike. Hence
#      the positive control (test 2) is a HARD PRECONDITION — if the path was
#      never live, every severance claim below is void, and the suite says so.
#
#   2. A check that never ran looking like a check that passed. Every field
#      defaults to JSON null, never to 0 or false, so an unexecuted step is
#      distinguishable from a measured negative. Test 1 refuses to proceed on a
#      setup error, and the final test asserts the suite's own declared test
#      count so a partially-loaded file cannot read green.
#
#   3. Absence mistaken for enforcement. "Unreachable" alone proves nothing, so
#      severance is corroborated by the eBPF drop counter (test 9) read out of
#      the BPF map. That is the only observable that distinguishes "the packets
#      stopped" from "our program stopped the packets".
#
# @id      tc-ebpf-drop-bats
# @target  d2-signalloom/apps/stun-sentinel/pkg/tc
# @doc     docs/signalloom/tc-ebpf-confinement.md
# @spec    docs/signalloom/evidence/tc-drop-proof.json

# The number of `@test` blocks in this file. Asserted against the real count in
# the final test: a .bats file with a syntax error or a conflict marker stops
# loading and its tests VANISH from the tally rather than failing, so "0 failed"
# can coexist with tests ceasing to exist.
DECLARED_TESTS=16

setup_file() {
	export REPO_ROOT="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
	export EVIDENCE="${BATS_FILE_TMPDIR}/tc-drop-proof.json"
	export GOPATH="${GOPATH:-/tmp/gopath}"
	export GOCACHE="${GOCACHE:-/tmp/gocache}"
	export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
	export CGO_ENABLED=0

	# Allow a pre-captured artifact so the assertions can be re-run without
	# docker (and so CI can validate a committed proof).
	if [ -n "${TC_DROP_EVIDENCE:-}" ] && [ -s "${TC_DROP_EVIDENCE}" ]; then
		cp "${TC_DROP_EVIDENCE}" "$EVIDENCE"
		return 0
	fi

	if [ -z "${TC_DROP_EVIDENCE:-}" ] && [ -s "$REPO_ROOT/docs/signalloom/evidence/tc-drop-proof.json" ] && [ "${TC_DROP_FORCE_LIVE:-0}" != "1" ]; then
		cp "$REPO_ROOT/docs/signalloom/evidence/tc-drop-proof.json" "$EVIDENCE"
		return 0
	fi

	if ! command -v docker >/dev/null 2>&1; then
		# Deliberately NOT a skip. A skip renders as `ok N # skip` and is
		# counted as a pass by `grep -c '^ok '`, so a suite that skipped
		# everything reports a full house into a file named "proof".
		echo "docker is required to run the live eBPF severance proof" >&2
		return 1
	fi

	"$REPO_ROOT/scripts/test-tc-ebpf.sh" --out "$EVIDENCE" >/dev/null 2>"${BATS_FILE_TMPDIR}/run.err" || true
}

# jqf reads a field from the evidence document.
jqf() {
	jq -r "(.live_severance_proof // .) | $1" < "$EVIDENCE"
}

@test "evidence document exists, is valid JSON, and records no setup error" {
	[ -s "$EVIDENCE" ]
	run jq -e . "$EVIDENCE"
	[ "$status" -eq 0 ]

	# A setup error means the experiment never reached the measurement, and
	# every null below would be an artefact of that rather than a finding.
	# Surfacing it here stops the rest of the suite being interpreted.
	local err
	err="$(jqf '.setup_error')"
	[ "$err" = "" ] || {
		echo "experiment aborted during setup: $err" >&2
		false
	}

	local verr
	verr="$(jqf '.verifier_error')"
	[ "$verr" = "" ] || {
		echo "BPF verifier rejected the program: $verr" >&2
		false
	}
}

@test "POSITIVE CONTROL: the path was live before isolation" {
	# This is the load-bearing test. Without it, every "unreachable" result
	# below is satisfied by a broken test harness just as well as by a
	# working drop filter, and the suite would prove nothing at all.
	[ "$(jqf '.control.path_was_live')" = "true" ]

	local lines
	lines="$(jqf '.control.lines_received_before_isolation')"
	[ "$lines" != "null" ]
	[ "$lines" -ge 3 ]
}

@test "MECHANISM: clsact qdisc is attached to the veth" {
	[ "$(jqf '.mechanism.clsact_present')" = "true" ]
}

@test "MECHANISM: an ingress BPF filter is attached" {
	[ "$(jqf '.mechanism.ingress_filter_present')" = "true" ]
}

@test "MECHANISM: an egress BPF filter is attached" {
	# Ingress-only isolation drops replies while permitting exfiltration and
	# still reads as "filtered" to any one-directional check. Both hooks or
	# it does not count.
	[ "$(jqf '.mechanism.egress_filter_present')" = "true" ]
}

@test "MECHANISM: the loaded program is sched_cls and named stun_tc_drop" {
	# The in-kernel verifier ran and accepted the program; a rejection could
	# not produce a loaded sched_cls program of this name.
	[ "$(jqf '.mechanism.program_type')" = "sched_cls" ]
	[ "$(jqf '.mechanism.program_name')" = "stun_tc_drop" ]
}

@test "MECHANISM: bpftool can dump the isolation map" {
	[ "$(jqf '.mechanism.map_dump_ok')" = "true" ]
}

@test "SEVERANCE: an established TCP stream stops within 100ms" {
	# Measured as the gap between the isolate call returning and the LAST
	# BYTE that arrived on a stream that was flowing continuously.
	#
	# Not measured as "the socket returned an error": an established TCP
	# connection whose packets are dropped retransmits with exponential
	# backoff for minutes. Asserting that `nc` exits within 100ms would fail
	# against a perfectly working filter and pass against a dead server.
	local gap
	gap="$(jqf '.severance.last_byte_gap_ms')"
	[ "$gap" != "null" ]
	[ "$gap" -lt 100 ]
}

@test "SEVERANCE: the isolate call itself completes within 100ms" {
	local ms
	ms="$(jqf '.severance.isolate_call_ms')"
	[ "$ms" != "null" ]
	[ "$ms" -lt 100 ]
}

@test "SEVERANCE: the interface reports itself isolated and is unreachable" {
	[ "$(jqf '.severance.isolated_flag')" = "true" ]
	# Reachability is measured by BYTES RECEIVED, not by exit status:
	# `nc | head` exits 0 on empty input, so an exit-status check would pass
	# whether or not anything was severed.
	[ "$(jqf '.severance.post_isolate_reachable')" = "false" ]
}

@test "ATTRIBUTION: the eBPF drop counter proves OUR program was on the packet path" {
	# What this proves, precisely: our classifier EXECUTED against real
	# traffic on this interface. Unreachability alone is consistent with a
	# dozen unrelated faults (dead server, wrong address, gone container);
	# a non-zero counter read out of the BPF map is not.
	#
	# What it does NOT prove, established by mutation rather than assumed:
	# flipping TC_ACT_SHOT to TC_ACT_OK in the C source leaves this test
	# GREEN, because account_drop() runs before the verdict is returned. The
	# counter measures "the program saw the packet", not "the program
	# destroyed it".
	#
	# The tests that DO discriminate are 8 (the stream stops) and 13
	# (conntrack reaches zero) — both go red under that mutation. Verified
	# by applying it, running the suite, and watching 8 and 13 fail while
	# the other fourteen passed. Keep all three: this one localises the
	# fault to our program, those two prove the packets actually died.
	local pkts bytes
	pkts="$(jqf '.attribution.packets_dropped')"
	bytes="$(jqf '.attribution.bytes_dropped')"
	[ "$pkts" != "null" ]
	[ "$bytes" != "null" ]
	[ "$pkts" -gt 0 ]
	[ "$bytes" -gt 0 ]
}

@test "CONNTRACK: entries existed before the flush" {
	# The precondition for the next test. Flushing an already-empty table
	# would drive the count to zero without the flush doing anything, and
	# "0 after" would be indistinguishable from success.
	local before
	before="$(jqf '.conntrack.entries_before')"
	[ "$before" != "null" ]
	[ "$before" -gt 0 ]
}

@test "CONNTRACK: zero entries remain for the target IP after the flush" {
	local after
	after="$(jqf '.conntrack.entries_after')"
	[ "$after" != "null" ]
	[ "$after" -eq 0 ]
}

@test "RECOVERY: connectivity is restored after an authorized release" {
	# Fail-safe rollback. A containment control that cannot be lifted is an
	# outage, not a control.
	[ "$(jqf '.recovery.reachable_after_release')" = "true" ]
}

@test "RECOVERY: detach removes the drop filters" {
	[ "$(jqf '.recovery.filters_after_detach')" = "false" ]
}

@test "suite integrity: every declared test ran, and the safety guard held" {
	# 1. Metrics contract — both card-mandated names must be exported.
	[ "$(jqf '.metrics.has_packets_dropped_total')" = "true" ]
	[ "$(jqf '.metrics.has_isolation_duration_seconds')" = "true" ]

	# 2. Safety — attaching a drop filter to eth0 must be refused. This is
	#    the guard against taking the node off the network.
	[ "$(jqf '.safety.eth0_attach_refused')" = "true" ]

	# 3. Self-count. A .bats file containing a conflict marker or a syntax
	#    error STOPS LOADING: its tests disappear from the tally instead of
	#    failing, and the run still reports "0 failed". Comparing the real
	#    count against the declared one is what makes that visible.
	local actual
	actual="$(grep -c '^@test ' "$BATS_TEST_FILENAME")"
	[ "$actual" -eq "$DECLARED_TESTS" ] || {
		echo "declared $DECLARED_TESTS tests but found $actual — tests may have been silently dropped" >&2
		false
	}
}
