# shellcheck shell=bash
#
# @id      spool-replay-lib
# @tests   test/spool-replay-lib.bats
#
# Causal waits for the SLTM partition test (test/sltm-probe-apikey.bats): the
# warden's spool has replayed the partitioned batch, and the store holds the
# provoker's observation. The warden's evidence is its ebpf_correlator_stats
# log lines, which are emitted at most every 30 s and ONLY when a counter
# changed -- so the latest line can predate the partition entirely, and a
# "spool_batches 0" in it says nothing about a batch spooled since (live,
# 2026-10-03: the test read the store 8 s before the replay landed).
#
# Every function reads JSON lines on stdin and decides; none talks to a
# cluster, so the decisions are tested offline.

# spool_replayed_latest: spool_replayed of the latest stats line. Because lines
# are emitted only on change, it is the counter's value now. Fails when there
# is no stats line (an absent baseline is not 0).
spool_replayed_latest() {
	local v
	v="$(jq -Rr 'fromjson? | select(.event == "ebpf_correlator_stats") | (.details.stats.spool_replayed // empty)' | tail -n 1)"
	[ -n "$v" ] || return 1
	printf '%s\n' "$v"
}

# spool_replayed_since SINCE BASELINE: succeeds when the latest stats line
# written at or after SINCE (RFC3339, compared to the second) shows
# spool_replayed above BASELINE and spool_batches 0 -- the batch spooled during
# the partition was replayed after it was lifted and nothing is left queued.
spool_replayed_since() {
	local since="${1:0:19}" baseline="$2"
	jq -Rr --arg since "$since" --argjson base "$baseline" '
		fromjson? | select(.event == "ebpf_correlator_stats")
		| select((.timestamp // "")[0:19] >= $since)
		| [(.details.stats.spool_replayed // -1), (.details.stats.spool_batches // -1)] | @tsv' |
		tail -n 1 | {
		local replayed batches
		IFS=$'\t' read -r replayed batches || return 1
		[ "$replayed" -gt "$baseline" ] && [ "$batches" -eq 0 ]
	}
}

# store_count_for_pod POD: how many observations in the store's JSON array
# (on stdin) belong to POD.
store_count_for_pod() {
	jq -r --arg p "$1" '[.[]? | select(.labels.pod_name == $p)] | length'
}

# poll_until TRIES INTERVAL CMD...: run CMD until it succeeds, at most TRIES
# times, INTERVAL seconds apart. Fails when it never does.
poll_until() {
	local tries="$1" interval="$2" i
	shift 2
	for ((i = 1; i <= tries; i++)); do
		"$@" && return 0
		[ "$i" -lt "$tries" ] && sleep "$interval"
	done
	return 1
}
