#!/usr/bin/env bats
#
# @id      spool-replay-lib
# @target  test/lib/spool-replay.sh (used by test/sltm-probe-apikey.bats "an ingest partition...")
#
# Live, 2026-10-03, SLTM live run 2: "an ingest partition loses no observation
# within the spool cap" failed with "No observations found for
# sltm-partition-provoker-2571". The spool lost nothing. The warden detected
# the provoker at 13:06:22.66, spooled the batch (stats 13:06:52:
# spool_batches 1) and replayed it (signal-ingest accepted it at
# 13:06:58.045). The test read the store at 13:06:49.8 -- before the replay --
# because its drain check took the LATEST stats line, 13:06:22 (spool_batches
# 0, written before anything was spooled), as "drained". Stats lines are
# emitted at most every 30 s and only on change, so the latest line can
# predate the partition entirely.
#
# The wait is now causal: the spool must have replayed past the pre-partition
# baseline in a stats line written after the partition was lifted, and the
# store must hold the provoker's own observation. These are offline tests of
# those decisions over the live run's own stats lines.

setup() {
  # shellcheck source=lib/spool-replay.sh
  source "${BATS_TEST_DIRNAME}/lib/spool-replay.sh"
}

stat_line() { # ts batches replayed
  printf '{"timestamp":"%s","event":"ebpf_correlator_stats","details":{"stats":{"spool_batches":%s,"spool_replayed":%s,"dispatch_ok":4}}}\n' "$1" "$2" "$3"
}

# The run's own lines, in order.
L1="$(stat_line 2026-10-03T13:06:22.744Z 0 1)"
L2="$(stat_line 2026-10-03T13:06:52.744Z 1 1)"
L3="$(stat_line 2026-10-03T13:07:22.744Z 0 2)"

@test "the baseline is the latest line's spool_replayed (lines are emitted only on change)" {
  [ "$(spool_replayed_latest <<<"${L1}")" = 1 ]
  [ "$(spool_replayed_latest <<<"$(printf '%s\n%s\n' "$L1" "$L3")")" = 2 ]
}

@test "no stats line at all is not a baseline of 0" {
  run spool_replayed_latest <<<""
  [ "$status" -ne 0 ]
}

@test "the run's stale pre-partition line is NOT a replay (the flake)" {
  # Partition lifted at ~13:06:30; baseline from the 13:06:22 line.
  run spool_replayed_since 2026-10-03T13:06:30Z 1 <<<"${L1}"
  [ "$status" -ne 0 ]
}

@test "spooled but not yet replayed is not a replay" {
  run spool_replayed_since 2026-10-03T13:06:30Z 1 <<<"$(printf '%s\n%s\n' "$L1" "$L2")"
  [ "$status" -ne 0 ]
}

@test "replayed past the baseline, after the lift, with the spool empty, is a replay" {
  run spool_replayed_since 2026-10-03T13:06:30Z 1 <<<"$(printf '%s\n%s\n%s\n' "$L1" "$L2" "$L3")"
  [ "$status" -eq 0 ]
}

# After the lift a stats line can show the spool empty because nothing was
# replayed yet (any other counter moved): not a replay.
@test "a post-lift line with the spool empty but no replay is not a replay" {
  local idle; idle="$(stat_line 2026-10-03T13:06:52.744Z 0 1)"
  run spool_replayed_since 2026-10-03T13:06:30Z 1 <<<"$(printf '%s\n%s\n' "$L1" "$idle")"
  [ "$status" -ne 0 ]
}

@test "a replay counted before the lift does not count" {
  local early; early="$(stat_line 2026-10-03T13:06:25.000Z 0 2)"
  run spool_replayed_since 2026-10-03T13:06:30Z 1 <<<"$(printf '%s\n%s\n' "$L1" "$early")"
  [ "$status" -ne 0 ]
}

@test "replayed but more still spooled is not drained" {
  local partial; partial="$(stat_line 2026-10-03T13:07:22.744Z 1 2)"
  run spool_replayed_since 2026-10-03T13:06:30Z 1 <<<"$(printf '%s\n%s\n' "$L1" "$partial")"
  [ "$status" -ne 0 ]
}

@test "unparseable or non-stats lines are ignored, never read as a replay" {
  run spool_replayed_since 2026-10-03T13:06:30Z 1 <<<"$(printf 'not json\n{"event":"unstun","timestamp":"2026-10-03T13:07:00Z"}\n%s\n' "$L1")"
  [ "$status" -ne 0 ]
}

@test "the store check finds the provoker's own observation and nothing else" {
  local body='[{"labels":{"pod_name":"other"}},{"labels":{"pod_name":"sltm-partition-provoker-2571"}}]'
  [ "$(store_count_for_pod sltm-partition-provoker-2571 <<<"$body")" = 1 ]
  [ "$(store_count_for_pod sltm-partition-provoker-9 <<<"$body")" = 0 ]
  [ "$(store_count_for_pod x <<<"[]")" = 0 ]
}

@test "poll_until retries to success, and gives up after its bound" {
  local n="${BATS_TEST_TMPDIR}/n"; echo 0 >"$n"
  third_try() { local c; c=$(($(cat "$n") + 1)); echo "$c" >"$n"; [ "$c" -ge 3 ]; }
  run poll_until 10 0 third_try
  [ "$status" -eq 0 ]
  [ "$(cat "$n")" = 3 ]
  never() { return 1; }
  run poll_until 3 0 never
  [ "$status" -ne 0 ]
}
