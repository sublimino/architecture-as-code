#!/usr/bin/env bats

# This is a local harness test, not a claim that a Kind workload reconciled.
# It proves that the runtime acceptance script fails closed for each outcome it
# treats as security-significant.

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat >"$bin/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
case "$args" in
  *'wait job/bao-spire-positive-proof'*)
    [[ "${BAO_PROOF_SCENARIO:-pass}" != positive-incomplete ]]
    ;;
  *'wait job/bao-spire-negative-proof --for=condition=complete'*)
    [[ "${BAO_PROOF_SCENARIO:-pass}" == negative-unexpected-success ]]
    ;;
  *'wait job/bao-spire-negative-proof --for=condition=failed'*)
    [[ "${BAO_PROOF_SCENARIO:-pass}" != negative-not-failed ]]
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
}

run_proof() {
  run env PATH="$bin:$PATH" BAO_PROOF_SCENARIO="$1" DEMO_WAIT_TIMEOUT=1s \
    "$root/scripts/bao-spire-proof.sh"
}

@test "accepts the expected positive identity and denied negative identity" {
  run_proof pass
  [ "$status" -eq 0 ]
  [[ "$output" == *'bounded Bao/SPIRE positive and negative identity proof passed'* ]]
}

@test "fails when the negative identity unexpectedly completes" {
  run_proof negative-unexpected-success
  [ "$status" -ne 0 ]
  [[ "$output" == *'negative Bao/SPIRE identity unexpectedly succeeded'* ]]
}

@test "fails when the negative identity does not reach Failed" {
  run_proof negative-not-failed
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
