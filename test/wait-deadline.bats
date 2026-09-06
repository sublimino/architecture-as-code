#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  wait_lib="$root/scripts/lib/wait.sh"
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
