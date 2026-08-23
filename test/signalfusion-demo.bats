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

@test "signalfusion-demo.sh embeds no double quote inside a python3 -c block" {
  # These blocks are `python3 -c "<program>"` — a double-quoted SHELL string.
  # A single " anywhere inside closes it early and mangles the program. The
  # failure is silent in the worst way: every call site pipes stderr to
  # /dev/null and falls back to an empty value, so the script keeps running and
  # produces a wrong result rather than an error.
  #
  # This shipped. A comment inside one of these blocks quoted an error message
  # ("run Act 1 first"). actor_id came back empty, the kernel observation was
  # posted with an empty actor_hint, correlation attached it to nothing, and
  # Act 3 reported "no kernel-layer evidence" immediately after Act 2 reported
  # success — which reads as a correlation-engine bug, not a quoting bug.
  #
  # Scans the region between `python3 -c "` and the closing `"` line.
  # Only UNESCAPED quotes break the string: \" inside these blocks is correct
  # and common (every f-string in here uses it). Matching a bare " would flag
  # forty valid lines and get the test deleted rather than the bug fixed.
  run awk '
    /python3 -c "$/ { inblk = 1; start = NR; next }
    inblk && /^" *(2>\/dev\/null)?\)?/ { inblk = 0; next }
    inblk && /(^|[^\\])"/ { print "line " NR " (block opened at " start "): " $0 }
  ' "$script"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "signalfusion-demo.sh actually extracts an actor id from a bare array" {
  # The behavioural half of the test above. Runs the real extraction block
  # against a fixture shaped like the live GET /api/v1/actors response, which
  # is a BARE ARRAY. Asserting the id comes back non-empty is what a syntax
  # scan cannot do: the block could parse fine and still read the wrong key.
  local block
  block="$(awk '/^  actor_id=\$\(printf/{f=1} f{print} /\|\| actor_id=""/{if(f) exit}' "$script")"
  [ -n "$block" ]

  run bash -c "actors_before='[{\"id\":\"actor-sa-ml-pipeline\"}]'
$block
printf '%s' \"\$actor_id\""
  [ "$status" -eq 0 ]
  [ "$output" = "actor-sa-ml-pipeline" ]
}
