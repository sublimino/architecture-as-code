#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  wait_lib="${WAIT_LIB_OVERRIDE:-$root/scripts/lib/wait.sh}"
}

@test "WAIT zero deadline does not execute the probe" {
  marker="$BATS_TEST_TMPDIR/probe-ran"
  run env MARKER="$marker" bash -c 'source "$1"; _wait_retry 0 "zero probe" "touch \"$MARKER\""' _ "$wait_lib"

  [ "$status" -eq 1 ]
  [ ! -e "$marker" ]
}

@test "WAIT timeout diagnostics run exactly once and preserve failure" {
  callback_log="$BATS_TEST_TMPDIR/callback.log"
  run env WAIT_SLEEP=0.01 WAIT_BACKOFF=1 WAIT_JITTER=0 WAIT_ATTEMPT_TIMEOUT=0.1 \
    CALLBACK_LOG="$callback_log" bash -c '
      source "$1"
      diagnostics() { printf "%s\n" "$*" >> "$CALLBACK_LOG"; return 7; }
      WAIT_TIMEOUT_DIAGNOSTICS_CALLBACK=diagnostics _wait_retry 1 "callback probe" false
    ' _ "$wait_lib"

  [ "$status" -eq 1 ]
  [ "$(wc -l < "$callback_log")" -eq 1 ]
  [[ "$(<"$callback_log")" == callback\ probe* ]]
}

@test "WAIT successful probes never invoke timeout diagnostics" {
  callback_log="$BATS_TEST_TMPDIR/callback.log"
  run env CALLBACK_LOG="$callback_log" bash -c '
    source "$1"
    diagnostics() { printf "called\n" >> "$CALLBACK_LOG"; }
    WAIT_TIMEOUT_DIAGNOSTICS_CALLBACK=diagnostics _wait_retry 1 "successful probe" true
  ' _ "$wait_lib"

  [ "$status" -eq 0 ]
  [ ! -e "$callback_log" ]
}

@test "WAIT hard deadline bounds an oversized backoff sleep" {
  start=$SECONDS
  # shellcheck disable=SC2016
  run env WAIT_SLEEP=5 WAIT_BACKOFF=1 WAIT_JITTER=0 WAIT_ATTEMPT_TIMEOUT=0.1 \
    bash -c 'source "$1"; _wait_retry 1 "test probe" false' _ "$wait_lib"
  elapsed=$((SECONDS - start))

  [ "$status" -eq 1 ]
  [ "$elapsed" -le 2 ]
  [[ "$output" == *'deadline 1s exceeded'* ]]
}

@test "WAIT per-attempt timeout still fences a hanging probe" {
  start=$SECONDS
  # shellcheck disable=SC2016
  run env WAIT_SLEEP=0.1 WAIT_BACKOFF=1 WAIT_JITTER=0 WAIT_ATTEMPT_TIMEOUT=0.1 \
    bash -c 'source "$1"; _wait_retry 1 "hanging probe" "sleep 10"' _ "$wait_lib"
  elapsed=$((SECONDS - start))

  [ "$status" -eq 1 ]
  [ "$elapsed" -le 2 ]
  [[ "$output" == *'deadline 1s exceeded'* ]]
}

@test "WAIT remaining deadline caps the configured attempt timeout" {
  start=$SECONDS
  # shellcheck disable=SC2016
  run env WAIT_SLEEP=0.1 WAIT_BACKOFF=1 WAIT_JITTER=0 WAIT_ATTEMPT_TIMEOUT=5 \
    bash -c 'source "$1"; _wait_retry 1 "hanging probe" "sleep 10"' _ "$wait_lib"
  elapsed=$((SECONDS - start))

  [ "$status" -eq 1 ]
  [ "$elapsed" -le 2 ]
  [[ "$output" == *'deadline 1s exceeded'* ]]
}
