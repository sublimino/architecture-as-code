#!/usr/bin/env bats

# This is a local harness test, not a claim that a Kind workload reconciled.
# It proves that the runtime acceptance script fails closed for each outcome it
# treats as security-significant.
#
# ── The staleness defect these tests were extended for (2026-08-23) ─────────
#
# A Kubernetes Job is TERMINAL. Once Complete it stays Complete forever, so
# `kubectl wait --for=condition=complete` against a Job that finished days ago
# returns instantly and successfully. The script waited without recreating, so
# it re-read history instead of re-proving anything.
#
# Observed on kind-osramp: bao-spire-positive-proof and bao-spire-negative-proof
# were Complete and 2d20h old while every SPIFFE login on that lane was failing.
# The proof reported a two-day-old pass throughout the outage. Job age was the
# only tell and nothing looked at it.
#
# Two mechanisms, deliberately both:
#   * RECREATE  — delete and let Flux rebuild before waiting. This is what
#                 actually produces fresh evidence.
#   * FRESHNESS — assert each Job was created during THIS run. On its own it
#                 could only report staleness, never cure it; its job is to fail
#                 if someone later removes the recreate.

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  bin="$BATS_TEST_TMPDIR/bin"
  calls="$BATS_TEST_TMPDIR/calls.log"
  mkdir -p "$bin"
  : >"$calls"
  export BAO_PROOF_CALL_LOG="$calls"

  cat >"$bin/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
case "$args" in
  *'delete job'*)
    echo "DELETE" >>"$BAO_PROOF_CALL_LOG"
    ;;
  *'wait job/bao-spire-positive-proof'*)
    echo "WAIT_POSITIVE" >>"$BAO_PROOF_CALL_LOG"
    [[ "${BAO_PROOF_SCENARIO:-pass}" != positive-incomplete ]]
    ;;
  *'wait job/bao-spire-negative-proof --for=condition=complete'*)
    echo "WAIT_NEGATIVE" >>"$BAO_PROOF_CALL_LOG"
    [[ "${BAO_PROOF_SCENARIO:-pass}" != negative-incomplete ]]
    ;;
  *'get job'*)
    echo "GET_TIMESTAMP" >>"$BAO_PROOF_CALL_LOG"
    # A Job created long before this run is exactly the observed defect.
    if [[ "${BAO_PROOF_SCENARIO:-pass}" == stale-job ]]; then
      printf '2026-08-20T00:00:00Z'
    else
      date -u +%Y-%m-%dT%H:%M:%SZ | tr -d '\n'
    fi
    ;;
  *'logs job/bao-spire-positive-proof'*)
    if [[ "${BAO_PROOF_SCENARIO:-pass}" == positive-marker-missing ]]; then
      printf 'positive job completed without its marker\n'
    else
      printf 'bounded Bao/SPIRE proof passed\n'
    fi
    ;;
  *'logs job/bao-spire-negative-proof -c jwt-svid'*)
    if [[ "${BAO_PROOF_SCENARIO:-pass}" == negative-marker-missing ]]; then
      printf 'authentication unexpectedly succeeded\n'
    else
      printf 'denied as expected\n'
    fi
    ;;
  *)
    printf 'unexpected kubectl invocation: %s\n' "$args" >&2
    exit 64
    ;;
esac
SCRIPT
  chmod +x "$bin/kubectl"

  cat >"$bin/flux" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
echo "RECONCILE" >>"$BAO_PROOF_CALL_LOG"
SCRIPT
  chmod +x "$bin/flux"
}

run_proof() {
  run env PATH="$bin:$PATH" BAO_PROOF_SCENARIO="$1" DEMO_WAIT_TIMEOUT=1s \
    BAO_PROOF_CALL_LOG="$calls" \
    "$root/scripts/bao-spire-proof.sh"
}

@test "accepts the expected positive identity and denied negative identity" {
  run_proof pass
  [ "$status" -eq 0 ]
  [[ "$output" == *'bounded Bao/SPIRE positive and negative identity proof passed'* ]]
}

@test "fails when the negative denial proof does not complete" {
  run_proof negative-incomplete
  [ "$status" -ne 0 ]
}

@test "accepts a completed positive job without shell-generated log markers" {
  run_proof positive-marker-missing
  [ "$status" -eq 0 ]
  [[ "$output" == *'bounded Bao/SPIRE positive and negative identity proof passed'* ]]
}

@test "fails when the negative job lacks its denial marker" {
  run_proof negative-marker-missing
  [ "$status" -ne 0 ]
  [[ "$output" == *'negative Bao/SPIRE proof did not emit its denial marker'* ]]
}

# STALENESS 1 — the mechanism.
#
# Asserts ORDER, not merely presence. "It called delete somewhere" is satisfied
# by a script that deletes AFTER waiting, which would still have waited on the
# stale Job and proved nothing. The delete must precede the first wait.
@test "STALE recreates both proof Jobs BEFORE waiting on them" {
  run_proof pass
  [ "$status" -eq 0 ]
  local seq
  seq="$(tr '\n' ' ' <"$calls")"
  [[ "$seq" == *DELETE* ]]
  [[ "$seq" == *RECONCILE* ]]
  # First DELETE must come before the first WAIT.
  local del_line wait_line
  del_line="$(grep -n '^DELETE$' "$calls" | head -1 | cut -d: -f1)"
  wait_line="$(grep -n '^WAIT_' "$calls" | head -1 | cut -d: -f1)"
  [ -n "$del_line" ]
  [ -n "$wait_line" ]
  [ "$del_line" -lt "$wait_line" ]
}

# STALENESS 2 — the guard.
#
# If someone removes the recreate above, this is what still fails. A Job created
# before this run started cannot be evidence about this run.
@test "STALE fails when a proof Job predates this run" {
  run_proof stale-job
  [ "$status" -ne 0 ]
  [[ "$output" == *'predates this run'* ]]
}

# The freshness check must actually READ the Job, not assume. Without this a
# guard that never calls kubectl would pass the test above by accident for the
# wrong reason.
@test "STALE the freshness check actually reads each Job's creation timestamp" {
  run_proof pass
  [ "$status" -eq 0 ]
  local n
  n="$(grep -c '^GET_TIMESTAMP$' "$calls")"
  [ "$n" -ge 2 ]
}
