#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scenario.sh — the live severance experiment. Runs INSIDE a privileged
# container; emits a single JSON object of measured evidence on stdout.
#
# This script is the measurement apparatus. It asserts nothing; it observes and
# reports. test/tc-ebpf-drop.bats does the asserting, against the JSON. Keeping
# those apart means a change to what we consider "passing" cannot quietly
# change what was measured.
#
# THE EXPERIMENT
#
#   host ns                                  pod ns
#   10.99.0.1 ---[veth-host]===[veth-pod]--- 10.99.0.2
#                    ^
#                    the drop filter attaches here
#
# A server in the pod namespace streams a line every 10ms. A reader in the host
# namespace timestamps each line it receives. We isolate mid-stream and measure
# the gap between the isolate call returning and the last line that arrived.
#
# WHY "LAST BYTE" AND NOT "SOCKET ERROR". An established TCP connection does not
# fail fast when its packets are dropped — the kernel retransmits with
# exponential backoff for minutes. A test asserting that `nc` EXITS within 100ms
# would fail against a perfectly working drop filter. What actually happens
# within 100ms, and what actually matters, is that data stops moving. That is
# what is measured here.
#
# @id      stun-sentinel-tc-scenario
# @doc     docs/signalloom/tc-ebpf-confinement.md
# @tests   test/tc-ebpf-drop.bats
set -uo pipefail

HOST_IF="veth-host"
POD_IF="veth-pod"
POD_NS="stunpod"
HOST_IP="10.99.0.1"
POD_IP="10.99.0.2"
PORT="9000"
WORK="$(mktemp -d)"

# Every observation starts as the JSON literal null. A step that does not run
# leaves null, which is distinguishable from a real measurement of 0 or false.
# This matters: an unexecuted check and a check that passed must never look the
# same, and "0" or "false" defaults would make them identical.
control_lines=null
control_ok=null
ct_before=null
ct_after=null
isolate_ms=null
isolate_reported_ms=null
sever_gap_ms=null
packets_dropped=null
bytes_dropped=null
isolated_flag=null
post_isolate_reachable=null
released_reachable=null
ingress_filter=null
egress_filter=null
clsact_present=null
prog_type=null
prog_name=null
verifier_error=""
bpftool_map_dump=null
metrics_has_drop_counter=null
metrics_has_duration=null
detach_left_filters=null
guard_eth0_refused=null
setup_error=""

cleanup() {
	stop_server 2>/dev/null
	ip netns del "$POD_NS" 2>/dev/null
	ip link del "$HOST_IF" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

fail_out() {
	setup_error="$1"
	emit
	exit 1
}

emit() {
	cat <<JSON
{
  "schema": "signalloom.tc-drop-proof/v1",
  "kernel": "$(uname -r)",
  "host_interface": "$HOST_IF",
  "pod_ip": "$POD_IP",
  "setup_error": "$setup_error",
  "verifier_error": "$verifier_error",
  "control": {
    "lines_received_before_isolation": $control_lines,
    "path_was_live": $control_ok
  },
  "mechanism": {
    "clsact_present": $clsact_present,
    "ingress_filter_present": $ingress_filter,
    "egress_filter_present": $egress_filter,
    "program_type": $prog_type,
    "program_name": $prog_name,
    "map_dump_ok": $bpftool_map_dump
  },
  "severance": {
    "isolate_call_ms": $isolate_ms,
    "isolate_reported_ms": $isolate_reported_ms,
    "last_byte_gap_ms": $sever_gap_ms,
    "isolated_flag": $isolated_flag,
    "post_isolate_reachable": $post_isolate_reachable
  },
  "attribution": {
    "packets_dropped": $packets_dropped,
    "bytes_dropped": $bytes_dropped
  },
  "conntrack": {
    "entries_before": $ct_before,
    "entries_after": $ct_after
  },
  "recovery": {
    "reachable_after_release": $released_reachable,
    "filters_after_detach": $detach_left_filters
  },
  "metrics": {
    "has_packets_dropped_total": $metrics_has_drop_counter,
    "has_isolation_duration_seconds": $metrics_has_duration
  },
  "safety": {
    "eth0_attach_refused": $guard_eth0_refused
  }
}
JSON
}

now_ms() { date +%s%3N; }

# --- setup ------------------------------------------------------------------

mount -t bpf bpf /sys/fs/bpf 2>/dev/null

ip netns add "$POD_NS" || fail_out "could not create netns"
ip link add "$HOST_IF" type veth peer name "$POD_IF" || fail_out "could not create veth pair"
ip link set "$POD_IF" netns "$POD_NS" || fail_out "could not move peer into netns"
ip addr add "$HOST_IP/24" dev "$HOST_IF" || fail_out "could not address host veth"
ip link set "$HOST_IF" up || fail_out "could not bring host veth up"
ip netns exec "$POD_NS" ip addr add "$POD_IP/24" dev "$POD_IF" || fail_out "could not address pod veth"
ip netns exec "$POD_NS" ip link set "$POD_IF" up || fail_out "could not bring pod veth up"
ip netns exec "$POD_NS" ip link set lo up

# Conntrack only populates when a netfilter hook asks it to. With no rules at
# all the table stays empty and the flush would have nothing to prove. These
# ACCEPT rules are TEST SCAFFOLDING inside a throwaway namespace — the Sentinel
# itself never touches iptables (explicitly out of scope on the card).
iptables -I INPUT -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
iptables -I OUTPUT -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null

# Streaming server: one line every 10ms.
#
# `nc -l` serves exactly ONE connection and then exits, so a single invocation
# is consumed by the positive control and every later reader finds nothing
# listening. The supervisor loop respawns it after each client, which is what
# lets the control and the measurement both have a live server.
start_server() {
	ip netns exec "$POD_NS" bash -c \
		"while true; do
			while true; do echo TICK; sleep 0.01; done | nc -l -p $PORT -q 0
			sleep 0.05
		done" >/dev/null 2>&1 &
	SERVER_SUPERVISOR=$!
}
stop_server() {
	[ -n "${SERVER_SUPERVISOR:-}" ] && kill "$SERVER_SUPERVISOR" 2>/dev/null
	pkill -f "nc -l -p $PORT" 2>/dev/null
}
start_server
sleep 1

# --- positive control -------------------------------------------------------
# ISC-129. Without this, every downstream "unreachable" observation is
# worthless: a dead server, a wrong address and a working drop filter all
# produce identical silence.

timeout 3 nc -w 2 "$POD_IP" "$PORT" 2>/dev/null | head -5 > "$WORK/control.txt"
control_lines=$(wc -l < "$WORK/control.txt" | tr -d ' ')
if [ "$control_lines" -ge 3 ]; then control_ok=true; else control_ok=false; fi

if [ "$control_ok" != "true" ]; then
	fail_out "positive control failed: the path was never live, so nothing downstream can be concluded"
fi

ct_before=$(conntrack -L 2>/dev/null | grep -c "$POD_IP")

# --- safety guard -----------------------------------------------------------
# ISC-63: refusing eth0 must happen, and must happen before any kernel call.

if stun-tcctl attach --interface eth0 >"$WORK/eth0.txt" 2>&1; then
	guard_eth0_refused=false
else
	if grep -qi "non-veth" "$WORK/eth0.txt"; then
		guard_eth0_refused=true
	else
		guard_eth0_refused=false
	fi
fi

# --- attach -----------------------------------------------------------------

if ! stun-tcctl attach --interface "$HOST_IF" >"$WORK/attach.txt" 2>&1; then
	verifier_error=$(tr -d '"' < "$WORK/attach.txt" | tr '\n' ' ' | cut -c1-400)
	fail_out "attach failed (see verifier_error)"
fi

tc qdisc show dev "$HOST_IF" | grep -q clsact && clsact_present=true || clsact_present=false
tc filter show dev "$HOST_IF" ingress | grep -q stun_tc_drop && ingress_filter=true || ingress_filter=false
tc filter show dev "$HOST_IF" egress | grep -q stun_tc_drop && egress_filter=true || egress_filter=false

if bpftool prog show | grep -q "name stun_tc_drop"; then
	prog_name='"stun_tc_drop"'
	if bpftool prog show | grep "name stun_tc_drop" | grep -q sched_cls; then
		prog_type='"sched_cls"'
	else
		prog_type='"unexpected"'
	fi
else
	prog_name=null
	prog_type=null
fi

bpftool map dump name stun_isolation_ >/dev/null 2>&1 && bpftool_map_dump=true || bpftool_map_dump=false

# --- the measurement --------------------------------------------------------
# A reader timestamps each line. We isolate mid-stream and compare the isolate
# timestamp against the timestamp of the last line that got through.

: > "$WORK/stream.txt"
(
	timeout 12 nc -w 10 "$POD_IP" "$PORT" 2>/dev/null | while IFS= read -r _line; do
		printf '%s\n' "$(date +%s%3N)" >> "$WORK/stream.txt"
	done
) &
reader_pid=$!

sleep 2
lines_before_isolate=$(wc -l < "$WORK/stream.txt" | tr -d ' ')
if [ "${lines_before_isolate:-0}" -lt 5 ]; then
	kill "$reader_pid" 2>/dev/null
	fail_out "stream was not flowing before isolation (only $lines_before_isolate lines); nothing to sever"
fi

t0=$(now_ms)
stun-tcctl isolate --interface "$HOST_IF" --ip "$POD_IP" --json > "$WORK/isolate.json" 2>"$WORK/isolate.err"
isolate_rc=$?
t1=$(now_ms)
isolate_ms=$((t1 - t0))

if [ "$isolate_rc" -ne 0 ]; then
	kill "$reader_pid" 2>/dev/null
	setup_error="isolate returned $isolate_rc: $(tr -d '"' < "$WORK/isolate.err" | tr '\n' ' ' | cut -c1-300)"
fi
isolate_reported_ms=$(grep -o '"elapsed_ms":[^,}]*' "$WORK/isolate.json" 2>/dev/null | cut -d: -f2 | tr -d ' ' )
[ -z "$isolate_reported_ms" ] && isolate_reported_ms=null

# Let any in-flight packet land, then take the last timestamp.
sleep 2
kill "$reader_pid" 2>/dev/null
wait "$reader_pid" 2>/dev/null

last_ts=$(tail -1 "$WORK/stream.txt" 2>/dev/null)
if [ -n "$last_ts" ]; then
	gap=$((last_ts - t1))
	# A negative gap means the last byte predates the isolate returning,
	# i.e. the stream had already stopped. Clamp to 0 and let the assertion
	# on lines_before_isolate carry the "was it flowing" question.
	[ "$gap" -lt 0 ] && gap=0
	sever_gap_ms=$gap
fi

# Conntrack is counted HERE, immediately after the flush and BEFORE any
# attribution traffic is generated.
#
# TC egress runs AFTER netfilter POSTROUTING in the packet path, so a probe
# packet is conntracked and THEN dropped. Counting after the probes measured
# the probes rather than the flush, and reported entries_after=4 against
# entries_before=1 — an increase, on a control whose whole purpose is to drive
# the count to zero.
ct_after=$(conntrack -L 2>/dev/null | grep -c "$POD_IP")

# --- attribution ------------------------------------------------------------
# Generate traffic that MUST be dropped, then read the counter out of the map.
# This is what separates "packets stopped" from "our program stopped packets".

timeout 2 ping -c 5 -i 0.2 -W 1 "$POD_IP" >/dev/null 2>&1
timeout 2 nc -w 1 "$POD_IP" "$PORT" >/dev/null 2>&1
timeout 2 nc -w 1 "$POD_IP" 9999 >/dev/null 2>&1

stun-tcctl status --interface "$HOST_IF" --json > "$WORK/status.json" 2>/dev/null
packets_dropped=$(grep -o '"packets_dropped":[^,}]*' "$WORK/status.json" | cut -d: -f2 | tr -d ' ')
bytes_dropped=$(grep -o '"bytes_dropped":[^,}]*' "$WORK/status.json" | cut -d: -f2 | tr -d ' ')
isolated_flag=$(grep -o '"isolated":[^,}]*' "$WORK/status.json" | cut -d: -f2 | tr -d ' ')
[ -z "$packets_dropped" ] && packets_dropped=null
[ -z "$bytes_dropped" ] && bytes_dropped=null
[ -z "$isolated_flag" ] && isolated_flag=null

# Reachability after isolation, measured by BYTES RECEIVED rather than by exit
# status. `nc | head` exits 0 on empty input, so an exit-status check here
# would pass whether or not anything was severed.
timeout 3 nc -w 2 "$POD_IP" "$PORT" 2>/dev/null | head -1 > "$WORK/after.txt"
if [ -s "$WORK/after.txt" ]; then post_isolate_reachable=true; else post_isolate_reachable=false; fi

# --- metrics ----------------------------------------------------------------

stun-tcctl metrics --interface "$HOST_IF" > "$WORK/metrics.txt" 2>/dev/null
grep -q "stun_tc_packets_dropped_total" "$WORK/metrics.txt" && metrics_has_drop_counter=true || metrics_has_drop_counter=false
grep -q "stun_tc_isolation_duration_seconds" "$WORK/metrics.txt" && metrics_has_duration=true || metrics_has_duration=false

# --- recovery ---------------------------------------------------------------

stun-tcctl release --interface "$HOST_IF" --ip "$POD_IP" >/dev/null 2>&1

# Poll for restoration with a bounded deadline instead of sampling once.
# Dropping every packet ages the host ARP entry for the pod out of the cache, so
# the first attempt after release spends time re-resolving. A single sample
# inside that window reports a working release as a failure. A restoration never
# spontaneously reverts, so polling cannot launder a genuine failure into a pass
# — it can only avoid a false negative.
released_reachable=false
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
	ping -c 1 -W 1 "$POD_IP" >/dev/null 2>&1
	timeout 4 nc -w 2 "$POD_IP" "$PORT" 2>/dev/null | head -1 > "$WORK/recovered.txt"
	if [ -s "$WORK/recovered.txt" ]; then
		released_reachable=true
		break
	fi
	sleep 1
done

# --- detach -----------------------------------------------------------------

stun-tcctl detach --interface "$HOST_IF" >/dev/null 2>&1
if tc filter show dev "$HOST_IF" ingress 2>/dev/null | grep -q stun_tc_drop; then
	detach_left_filters=true
else
	detach_left_filters=false
fi

emit
