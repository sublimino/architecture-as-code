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
  pipeline="$root/scripts/ci/vm-pipeline.sh"
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
    echo "vm-pipeline.sh never checks that signalloom-infra was activated"
    return 1
  }
  grep -qF 'SETUP failure, not a test failure' "$pipeline"
}
