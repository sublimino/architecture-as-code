#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  harness="$root/scripts/signalloom-test-1.sh"
}

@test "TEST-1 has one documented Make entrypoint" {
  run make -C "$root" -n demo-signalloom-test-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"./scripts/signalloom-test-1.sh"* ]]
}

@test "TEST-1 composes Playwright BATS pytest and Go contracts" {
  run bash -n "$harness"
  [ "$status" -eq 0 ]

  run grep -E 'playwright|acceptance-test' "$harness"
  [ "$status" -eq 0 ]
  run grep -E 'bats .*test-1-runtime|test-1-runtime\.bats' "$harness"
  [ "$status" -eq 0 ]
  run grep -E 'python -m pytest' "$harness"
  [ "$status" -eq 0 ]
  run grep -E 'go test' "$harness"
  [ "$status" -eq 0 ]
}

@test "TEST-1 browser cases enumerate the committed window matrix" {
  matrix="$root/docs/signalloom/dashboard-journey-matrix.md"
  spec="$root/test/acceptance/signalloom-test-1.spec.ts"
  run bash -c '
    count=0
    while IFS="|" read -r _ journey _rest; do
      journey="$(printf "%s" "$journey" | xargs)"
      case "$journey" in Journey|---|"") continue ;; esac
      grep -F "[\"$journey\"" "$2" >/dev/null || exit 1
      count=$((count + 1))
    done < <(sed -n "/## Routes and windows/,/## API journeys/p" "$1")
    test "$count" -eq 14
  ' _ "$matrix" "$spec"
  [ "$status" -eq 0 ]
}

@test "TEST-1 includes persistence fakes Gateway probes and policy negatives" {
  run grep -F 'src/tests' "$harness"
  [ "$status" -eq 0 ]
  run grep -F 'fake-integration-proxy/test' "$harness"
  [ "$status" -eq 0 ]

  runtime="$root/d2-signalloom/test/test-1-runtime.bats"
  run grep -E 'HTTPRoute|livez|readyz|NetworkPolicy|external egress|persistence' "$runtime"
  [ "$status" -eq 0 ]
}

@test "TEST-1 continues after failures but returns nonzero" {
  run grep -F 'FAILURES=$((FAILURES + 1))' "$harness"
  [ "$status" -eq 0 ]
  run grep -F 'if ((FAILURES > 0))' "$harness"
  [ "$status" -eq 0 ]
}
