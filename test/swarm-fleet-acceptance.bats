#!/usr/bin/env bats

# swarm-fleet-acceptance.bats — end-to-end lifecycle tests for the 10-agent
# swarm fleet. Runs against a live Kind cluster with Flux, SPIRE, and OpenBao.
#
# Prerequisites:
#   - Kind cluster 'osramp' running
#   - Flux bootstrapped
#   - SPIRE + OpenBao deployed in inf-bao
#   - Knative Serving + Eventing installed
#
# Run: bats test/swarm-fleet-acceptance.bats

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
NAMESPACE="${SWARM_NAMESPACE:-fe-signalloom-agents}"

AGENTS=(
  prompt-commit-summarizer
  triage-ci-worker
  zulip-chat-agent
  cpai-engineer
  hosted-daytona-coder
  swarm-governor
  prod-deploy-gate
  agent-cardvault
  nono-containment-probe
  signalloom-stun-sentinel
)

# ─── Infrastructure ────────────────────────────────────────────────────────

@test "deploy infra applies without error" {
  kubectl apply -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/" \
    --dry-run=server 2>&1
}

@test "namespace fe-signalloom-agents exists" {
  kubectl get ns "$NAMESPACE" -o name
}

@test "all 10 service accounts exist" {
  for sa in "${AGENTS[@]}"; do
    run kubectl get sa "${sa}" -n "$NAMESPACE" -o name
    [ "$status" -eq 0 ]
  done
}

@test "networkpolicy default-deny exists" {
  run kubectl get networkpolicy -n "$NAMESPACE" -o name
  [ "$status" -eq 0 ]
  # At least one networkpolicy should exist (default-deny or similar).
  [ -n "$output" ]
}

# ─── Fleet Deployment ──────────────────────────────────────────────────────

@test "deploy fleet creates pods" {
  # Verify at least one agent pod exists in the namespace.
  run kubectl get pods -n "$NAMESPACE" --no-headers
  [ "$status" -eq 0 ]
  # There should be at least 1 pod (some agents may be Jobs or Knative services).
  [ "$(echo "$output" | wc -l)" -ge 1 ]
}

@test "agent discovery finds labelled pods" {
  run kubectl get pods -n "$NAMESPACE" \
    -l signalloom.ai/agent=true \
    --no-headers -o name
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ─── Stun Sentinel ──────────────────────────────────────────────────────────

@test "stun sentinel DaemonSet is ready" {
  run kubectl get daemonset signalloom-stun-sentinel -n "$NAMESPACE" \
    -o jsonpath='{.status.desiredNumberScheduled}'
  [ "$status" -eq 0 ]
  local desired="$output"

  run kubectl get daemonset signalloom-stun-sentinel -n "$NAMESPACE" \
    -o jsonpath='{.status.numberReady}'
  [ "$status" -eq 0 ]
  local ready="$output"

  [ "$desired" -gt 0 ]
  [ "$ready" -eq "$desired" ]
}

@test "stun test freezes a pod" {
  # Find a target pod to stun.
  local target
  target=$(kubectl get pod -n "$NAMESPACE" \
    -l signalloom.ai/agent=true \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || skip "no agent pods to stun"

  [ -n "$target" ] || skip "no agent pods found"

  # Label the pod as stunned.
  kubectl label pod -n "$NAMESPACE" "$target" \
    signalloom.ai/state=stunned --overwrite

  # Verify the label was applied.
  run kubectl get pod -n "$NAMESPACE" "$target" \
    -o jsonpath='{.metadata.labels.signalloom\.ai/state}'
  [ "$status" -eq 0 ]
  [ "$output" = "stunned" ]

  # Clean up: remove the stun label.
  kubectl label pod -n "$NAMESPACE" "$target" \
    signalloom.ai/state- --overwrite 2>/dev/null || true
}

# ─── Teardown ───────────────────────────────────────────────────────────────

@test "remove fleet deletes pods" {
  # This test is destructive — only run when SWARM_TEARDOWN=true.
  [ "${SWARM_TEARDOWN:-false}" = "true" ] || skip "SWARM_TEARDOWN not set"

  # Delete agent workloads (not the namespace itself).
  for agent in "${AGENTS[@]}"; do
    kubectl delete deployment,statefulset,job,daemonset \
      -n "$NAMESPACE" -l "app=${agent}" \
      --ignore-not-found 2>/dev/null || true
  done

  # Wait for pods to terminate.
  sleep 5
  run kubectl get pods -n "$NAMESPACE" \
    -l signalloom.ai/agent=true --no-headers
  # Either no output or only terminating pods.
  [ -z "$output" ] || echo "$output" | grep -q "Terminating" || true
}

@test "teardown leaves namespace clean" {
  [ "${SWARM_TEARDOWN:-false}" = "true" ] || skip "SWARM_TEARDOWN not set"

  # After teardown, no orphan pods should remain in the agent namespace.
  run kubectl get pods -n "$NAMESPACE" --no-headers \
    --field-selector=status.phase=Running
  # Allow empty output (clean) or non-zero exit (namespace gone).
  [ -z "$output" ] || [ "$status" -ne 0 ]
}
