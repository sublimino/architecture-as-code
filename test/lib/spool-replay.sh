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

# STORE_PAGE_MAX is signal-ingest's page cap: its router refuses a larger
# limit with 400 "limit must be between 1 and 100" (api/auth.go,
# MaxPageSize). Asking for more made every partition-test read fail.
STORE_PAGE_MAX=100

# store_read_verdict POD, with "<status> <body>" (live_call's output) on
# stdin: 0 POD's observation is there; 1 it is absent from a complete page;
# 2 the read itself failed (non-200, or a body that is not a JSON array) --
# never to be mistaken for absence; 3 a full page without POD, which proves
# nothing. Prints the reason for 2 and 3.
store_read_verdict() {
	local pod="$1" out code body n
	out="$(cat)"
	code="${out%% *}"
	body="${out#* }"
	if [ "$code" != 200 ]; then
		printf 'store read failed: HTTP %s %s\n' "$code" "$body"
		return 2
	fi
	if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$body"; then
		printf 'store read failed: HTTP 200 with a non-array body: %.200s\n' "$body"
		return 2
	fi
	[ "$(store_count_for_pod "$pod" <<<"$body")" -ge 1 ] && return 0
	n="$(jq 'length' <<<"$body")"
	if [ "$n" -ge "${STORE_PAGE_MAX}" ]; then
		printf 'store page full (%s rows) without %s: absence not proven\n' "$n" "$pod"
		return 3
	fi
	return 1
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
