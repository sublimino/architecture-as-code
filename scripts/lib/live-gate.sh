# shellcheck shell=bash
#
# live-gate.sh - the single gate between an "offline" test run and a shared
# live kind node.
#
# @id      live-gate
# @tests   test/cgroup-freeze-live-gate.bats
#
# The cgroup-freeze suites and their harnesses used to decide "live" by
# `docker inspect <node>` alone. That ignores KUBECONFIG, so a run under
# KUBECONFIG=/dev/null still docker-cp'd binaries onto the shared node and
# pkill'd the deployed stun-sentinel (2026-10-02: restartCount 2). Live work
# now needs BOTH an explicit opt-in and a cluster reachable through KUBECONFIG.
#
# Injectable boundaries: SLDC_DOCKER, SLDC_KUBECTL. Every node-touching call
# in the suites goes through sldc_docker / sldc_kubectl, so a test can record
# them instead of reaching a real node.

sldc_docker() { "${SLDC_DOCKER:-docker}" "$@"; }
sldc_kubectl() { "${SLDC_KUBECTL:-kubectl}" "$@"; }

# sldc_live_gate CONTEXT NODE -> 0 only when SLDC_LIVE=1, KUBECONFIG is not
# /dev/null, CONTEXT answers /readyz and NODE exists. On refusal
# SLDC_LIVE_GATE_REASON says why. The checks are ordered so nothing reaches
# docker until the opt-in and the API server have both said yes.
sldc_live_gate() {
  local context="${1:?context required}" node="${2:?node required}"
  SLDC_LIVE_GATE_REASON=""
  if [ "${SLDC_LIVE:-0}" != "1" ]; then
    SLDC_LIVE_GATE_REASON="SLDC_LIVE=1 not set (live node work is opt-in)"
    return 1
  fi
  if [ "${KUBECONFIG:-}" = "/dev/null" ]; then
    SLDC_LIVE_GATE_REASON="KUBECONFIG=/dev/null"
    return 1
  fi
  if ! sldc_kubectl --context "${context}" get --raw /readyz >/dev/null 2>&1; then
    SLDC_LIVE_GATE_REASON="context ${context} is not reachable through KUBECONFIG"
    return 1
  fi
  if ! sldc_docker inspect "${node}" >/dev/null 2>&1; then
    SLDC_LIVE_GATE_REASON="kind node ${node} is not running"
    return 1
  fi
  return 0
}
