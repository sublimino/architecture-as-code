#!/usr/bin/env bats
# test/phase1-governor-verification.bats — scripts/test-phase1-governor.sh.
#
# go and bats are stubbed on PATH so these tests exercise the gate's own
# decisions (step order, fail-fast, log audit, certification contents), not the
# suites it wraps; those suites run on their own.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATE="${REPO_ROOT}/scripts/test-phase1-governor.sh"
  export P1_GOV_OUT="${BATS_TEST_TMPDIR}/out"
  CALLS="${BATS_TEST_TMPDIR}/calls"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  for tool in go bats; do
    cat >"${BATS_TEST_TMPDIR}/bin/${tool}" <<STUB
#!/bin/sh
echo "${tool} \$(basename "\$PWD") \$*" >>"${CALLS}"
exit \${STUB_${tool}_RC:-0}
STUB
    chmod +x "${BATS_TEST_TMPDIR}/bin/${tool}"
  done
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  LOG="${BATS_TEST_TMPDIR}/sentinel.log"
  printf '%s\n' '{"timestamp":"t","event":"stun","pod":"a"}' '{"timestamp":"t","event":"unstun","pod":"a"}' >"$LOG"
}

cert() { jq -r "$1" "${P1_GOV_OUT}/phase1-governance-certification.json"; }

@test "p1 governor: clean log and passing suites certify the current commit" {
  run "$GATE" --log "$LOG"
  [ "$status" -eq 0 ]
  [ "$(cert .status)" = certified ]
  [ "$(cert '.verifications | [.[]] | unique | join(",")')" = pass ]
  [ "$(cert .git_commit)" = "$(git -C "$REPO_ROOT" rev-parse HEAD)" ]
  grep -qx 'go stun-sentinel test ./...' "$CALLS"
  grep -qx 'go signalloom-stun-sentinel test ./...' "$CALLS"
  grep -q 'test/p1-sentinel-preflight.bats .*test/sentinel-capabilities.bats' "$CALLS"
}

@test "p1 governor: reconcile_failed events in the log refuse certification" {
  printf '%s\n' '{"event":"reconcile_failed","pod":"a"}' '{"event": "reconcile_failed","pod":"b"}' >>"$LOG"
  run "$GATE" --log "$LOG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: 2 reconcile_failed events in ${LOG}"* ]]
  [ "$(cert .status)" = failed ]
  [ "$(cert .verifications.zero_reconcile_failed)" = fail ]
}

@test "p1 governor: a reconcile_failed mention outside the event field is not an event" {
  echo '{"event":"stun","detail":"previous reconcile_failed cleared"}' >>"$LOG"
  run "$GATE" --log "$LOG"
  [ "$status" -eq 0 ]
}

@test "p1 governor: without a sentinel log the gate is incomplete, never certified" {
  run "$GATE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"INCOMPLETE: no --log given"* ]]
  [ "$(cert .status)" = incomplete ]
  [ "$(cert .verifications.zero_reconcile_failed)" = not-run ]
}

@test "p1 governor: a failing Go suite stops the gate before later steps" {
  export STUB_go_RC=1
  run "$GATE" --log "$LOG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: go test failed in d2-signalloom/apps/stun-sentinel"* ]]
  [ "$(cert .verifications.go_suites)" = fail ]
  [ "$(cert .verifications.bats_suites)" = not-run ]
  run grep -q '^bats' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "p1 governor: a failing BATS suite refuses certification" {
  export STUB_bats_RC=1
  run "$GATE" --log "$LOG"
  [ "$status" -eq 1 ]
  [ "$(cert .verifications.bats_suites)" = fail ]
  [ "$(cert .verifications.zero_reconcile_failed)" = not-run ]
}

@test "p1 governor: an unreadable log or unknown argument is a usage error" {
  run "$GATE" --log "${BATS_TEST_TMPDIR}/absent.log"
  [ "$status" -eq 2 ]
  [[ "$output" == *"sentinel log not found or unreadable"* ]]
  run "$GATE" --certify-anyway
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument: --certify-anyway"* ]]
  [ ! -e "${P1_GOV_OUT}/phase1-governance-certification.json" ]
}
