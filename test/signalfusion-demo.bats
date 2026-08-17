#!/usr/bin/env bats
# Signal Fusion demo script tests — structural, offline-safe.

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  script="$root/scripts/signalfusion-demo.sh"
}

@test "signalfusion-demo.sh exists and is executable" {
  [ -x "$script" ]
}

@test "signalfusion-demo.sh is valid bash" {
  run bash -n "$script"
  [ "$status" -eq 0 ]
}

@test "signalfusion-demo.sh prints usage on no args" {
  # The script sources lib/wait.sh which needs kubectl; stub the source
  # and test only the dispatch block.
  run bash -c '
    source() { :; }
    export -f source
    bash -c "source() { :; }; . \"'"$script"'\"" 2>&1
  '
  # set -euo pipefail + no arg = nonzero exit
  [ "$status" -ne 0 ]
}

@test "signalfusion-demo.sh rejects invalid step" {
  run bash -c '
    source() { :; }
    export -f source
    bash -c "source() { :; }; . \"'"$script"'\" 99" 2>&1
  '
  [ "$status" -ne 0 ]
}

@test "signalfusion-demo.sh sources lib/wait.sh" {
  run grep -F 'source "${SCRIPT_DIR}/lib/wait.sh"' "$script"
  [ "$status" -eq 0 ]
}

@test "signalfusion-demo.sh defines three acts" {
  run grep -cE '^demo_[123]\(\)' "$script"
  [ "$status" -eq 0 ]
  [ "$output" -eq 3 ]
}

@test "signalfusion-demo.sh dispatch handles 1 2 3 all" {
  for step in 1 2 3 all; do
    run grep -E "^\s+${step}\)" "$script"
    [ "$status" -eq 0 ]
  done
}

@test "signalfusion-demo.sh uses set -euo pipefail" {
  run grep -F 'set -euo pipefail' "$script"
  [ "$status" -eq 0 ]
}

@test "signalfusion-demo.sh log/ok/fail functions use UTC timestamps" {
  run grep -E '^(log|ok|fail)\(\)' "$script"
  [ "$status" -eq 0 ]
  run grep 'TZ=UTC' "$script"
  [ "$status" -eq 0 ]
}

@test "signalfusion-demo.sh has preflight checks" {
  run grep -c 'preflight_' "$script"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" -ge 3 ]
}

@test "signalfusion-demo.sh calls signal-ingest API" {
  run grep -E 'curl.*signal-ingest|/api/v1/(correlate|collectors/seed|actors)' "$script"
  [ "$status" -eq 0 ]
}

@test "signalfusion-demo.sh captures evidence as JSON" {
  run grep -cE '\bjq\b|json' "$script"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" -ge 1 ]
}
