#!/usr/bin/env bats
#
# Activating a ResourceSet must wait for it to exist first.
#
# The ResourceSets are delivered by the flux-system/tenants Kustomization,
# which reconciles asynchronously. On 2026-08-04 both CI VMs aborted here:
#
#   Error from server (NotFound): resourcesets.fluxcd.controlplane.io
#   "signalloom-infra" not found
#
# `activate_resourceset` patched immediately, and under `set -euo pipefail` a
# failed patch aborts `up` on its FIRST activation. The pipeline's fallback then
# repaired signalloom-apps only, leaving signalloom-infra inactive, and the run
# went on to execute eight stages against a cluster whose infra was never
# brought up.
#
# It only loses on a COLD cluster: on a warm one the ResourceSets survive from
# an earlier run, which is why this passed locally every time and failed on a VM
# built from nothing.

setup() {
  root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  local_sh="$root/scripts/signalloom-local.sh"
  pipeline="$root/scripts/gcp-tf/demo-pipeline.sh"
}

@test "RSRACE activate_resourceset waits for the object before patching it" {
  body="$(awk '/^activate_resourceset\(\)/,/^}/' "$local_sh")"
  # The wait must come BEFORE the patch, or it guards nothing.
  wait_line="$(printf '%s\n' "$body" | grep -n 'wait_k8s_exists' | head -1 | cut -d: -f1)"
  patch_line="$(printf '%s\n' "$body" | grep -n 'kubectl .*patch' | head -1 | cut -d: -f1)"
  [ -n "$wait_line" ] || { echo "activate_resourceset does not wait for existence"; return 1; }
  [ -n "$patch_line" ]
  [ "$wait_line" -lt "$patch_line" ] || {
    echo "the existence wait must precede the patch (wait@$wait_line patch@$patch_line)"
    return 1
  }
}

@test "RSRACE the pipeline refuses to run tests when infra was never activated" {
  # The fallback historically repaired signalloom-apps only. Proceeding after a
  # setup abort reports stages 6-8 as test failures, sending the reader to the
  # tests instead of the setup.
  grep -qF 'resourceset signalloom-infra' "$pipeline" || {
    echo "demo-pipeline.sh never checks that signalloom-infra was activated"
    return 1
  }
  grep -qF 'SETUP failure, not a test failure' "$pipeline"
  # Defined is not enough: it must RUN after the estate bring-up and before
  # the first cluster-dependent stage.
  up_line="$(grep -n '^retry .*demo-signalloom-up$' "$pipeline" | head -1 | cut -d: -f1)"
  call_line="$(grep -n '^assert_infra_activated$' "$pipeline" | head -1 | cut -d: -f1)"
  stage_line="$(grep -n 'MAKE_BIN} demo-signalloom-test"' "$pipeline" | head -1 | cut -d: -f1)"
  [ -n "$up_line" ]
  [ -n "$stage_line" ]
  [ -n "$call_line" ] || { echo "assert_infra_activated is never called"; return 1; }
  if [ "$call_line" -le "$up_line" ] || [ "$call_line" -ge "$stage_line" ]; then
    echo "guard must run between bring-up (@$up_line) and first stage (@$stage_line), is @$call_line"
    return 1
  fi
}

# Behaviour, not just presence: extract the guard and run it against a stubbed
# kubectl. The two greps above would still pass with the condition inverted.
run_infra_guard() {
  local fn
  fn="$(awk '/^assert_infra_activated\(\)/,/^}/' "$pipeline")"
  [ -n "$fn" ] || { echo "assert_infra_activated() not found in demo-pipeline.sh"; return 1; }
  printf '%s' "$1" >"$BATS_TEST_TMPDIR/inputs"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$BATS_TEST_TMPDIR/inputs" >"$BATS_TEST_TMPDIR/kubectl"
  chmod +x "$BATS_TEST_TMPDIR/kubectl"
  run bash -c "KUBECTL_BIN='$BATS_TEST_TMPDIR/kubectl'
$fn
assert_infra_activated
echo GUARD-PASSED"
}

@test "RSRACE the infra guard stops the pipeline when signalloom-infra inputs are empty" {
  run_infra_guard '[]'
  [ "$status" -eq 2 ]
  [[ "$output" == *"SETUP failure, not a test failure"* ]]
  [[ "$output" != *"GUARD-PASSED"* ]]
}

@test "RSRACE the infra guard lets an activated signalloom-infra through" {
  run_infra_guard '[{"component":"inf-bao","tenant":"inf-bao"}]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"GUARD-PASSED"* ]]
}
