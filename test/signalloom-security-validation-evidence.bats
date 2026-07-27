#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  evidence="$root/docs/signalloom/security-validation-errata.md"
}

@test "bounded security evidence remains explicitly fail-closed" {
  run grep -F '<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->' "$evidence"
  [ "$status" -eq 0 ]

  run grep -F 'It neither authorises a release' "$evidence"
  [ "$status" -eq 0 ]
}

@test "bounded security evidence records every required gate" {
  for gate in Threat SAST SCA Secret DAST Egress SBOM Signature provenance digest; do
    run grep -F "$gate" "$evidence"
    [ "$status" -eq 0 ]
  done
}

@test "bounded security evidence distinguishes tests from candidate evidence" {
  run grep -F 'do not replace failed, blocked, or missing candidate-bound security evidence' "$evidence"
  [ "$status" -eq 0 ]
}
