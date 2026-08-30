#!/usr/bin/env bats
# d2-signalloom/test/kagent-agent-reachability.bats
#
# The kagent controller must be able to reach a controller-minted agent pod.
#
# WHY THIS SUITE EXISTS.
#
# On 2026-08-30 a NetworkPolicy change silently severed the demo's central
# path. `make demo-kagent-invoke` returned:
#
#   code -32603: failed to send HTTP request:
#     Post "http://kagent-k8s-reader.fe-signalloom-agents:8080": i/o timeout
#
# against a pod that was 1/1 Running, whose Agent CR reported
# Accepted=True Ready=True, with every bats suite green. Nothing failed. A
# human running the demo was the detector, which is exactly the arrangement
# this repo keeps trying to eliminate.
#
# Root cause was two-sided and neither side is visible from any status field:
#   1. the kagent controller builds the agent Deployment's pod template itself
#      and does not propagate `signalloom.ai/agent: "true"`, so the pods matched
#      `default-deny` (podSelector {}) and no allow rule;
#   2. `allow-signalloom-ingress` admitted only namespace `fe-signalloom`, while
#      the controller that proxies every A2A invocation runs in `kagent`.
#
# Note `i/o timeout` rather than `connection refused` is the tell: a refusal
# means nothing is listening, a timeout means the packet was dropped. A suite
# that only asserted "the pod is Ready" could not tell those apart, which is
# why this asserts reachability rather than readiness.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  NETPOL="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/networkpolicy.yaml"
  AGENT_NS="fe-signalloom-agents"
  KAGENT_NS="kagent"
  command -v yq >/dev/null || skip "yq is required"
}

cluster_up() {
  kubectl get ns "$AGENT_NS" >/dev/null 2>&1
}

# ── Static: the policy exists and is scoped, not a namespace-wide opening ────

@test "a policy admits the kagent namespace to the controller-minted agent pods" {
  local docs
  docs="$(yq eval-all 'select(.kind == "NetworkPolicy") | .metadata.name' "$NETPOL")"
  printf '%s\n' "$docs" | grep -Fxq 'allow-kagent-managed-agents' || {
    echo "no policy admits the kagent controller to the agent pods."
    echo "the agents would be covered by default-deny with no allow rule."
    return 1
  }
}

@test "that policy selects the label the controller actually sets, not the one we wish it set" {
  # The whole defect was selecting signalloom.ai/agent=true, which the
  # controller-minted pods do not carry. If someone "tidies" this selector
  # back to the Signal Loom label, the demo breaks again silently.
  local sel
  sel="$(yq eval-all '
    select(.kind == "NetworkPolicy" and .metadata.name == "allow-kagent-managed-agents")
    | .spec.podSelector.matchLabels["app.kubernetes.io/managed-by"]' "$NETPOL")"
  [ "$sel" = "kagent" ] || {
    echo "expected podSelector app.kubernetes.io/managed-by=kagent, got: '$sel'"
    return 1
  }
}

@test "the policy is port-scoped rather than opening the namespace" {
  # Collected into a variable and tested with [ -n ], never `! grep`: a
  # negated command is exempt from errexit and can never fail this test.
  local port
  port="$(yq eval-all '
    select(.kind == "NetworkPolicy" and .metadata.name == "allow-kagent-managed-agents")
    | .spec.ingress[0].ports[0].port' "$NETPOL")"
  [ "$port" = "8080" ] || {
    echo "expected ingress scoped to 8080, got: '$port'"
    return 1
  }
}

# ── Live: does a packet actually arrive? ────────────────────────────────────

@test "LIVE the kagent namespace can reach an agent pod on 8080" {
  cluster_up || skip "no cluster"
  local agent out
  agent="$(kubectl get pods -n "$AGENT_NS" -l app.kubernetes.io/managed-by=kagent \
    -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/name}' 2>/dev/null)"
  [ -n "$agent" ] || skip "no controller-minted agent pods deployed"

  out="$(kubectl run "npcheck-pos-$$" -n "$KAGENT_NS" --rm -i --restart=Never \
    --image=busybox:1.36 --timeout=120s -- \
    sh -c "nc -zv -w5 ${agent}.${AGENT_NS} 8080 >/dev/null 2>&1 && echo REACHABLE || echo BLOCKED" 2>/dev/null)"

  [[ "$out" == *REACHABLE* ]] || {
    echo "the kagent controller cannot reach ${agent}.${AGENT_NS}:8080."
    echo "every A2A invocation will fail with an i/o timeout while the pod"
    echo "still reports Running and its Agent CR reports Ready=True."
    echo "probe said: $out"
    return 1
  }
}

@test "LIVE an unrelated namespace is still denied — the policy constrains" {
  # Guards the guard. Without this, the test above would pass just as happily
  # against a namespace-wide opening, and would then be asserting nothing.
  cluster_up || skip "no cluster"
  local agent out
  agent="$(kubectl get pods -n "$AGENT_NS" -l app.kubernetes.io/managed-by=kagent \
    -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/name}' 2>/dev/null)"
  [ -n "$agent" ] || skip "no controller-minted agent pods deployed"

  out="$(kubectl run "npcheck-neg-$$" -n default --rm -i --restart=Never \
    --image=busybox:1.36 --timeout=120s -- \
    sh -c "nc -zv -w5 ${agent}.${AGENT_NS} 8080 >/dev/null 2>&1 && echo REACHABLE || echo DENIED" 2>/dev/null)"

  [[ "$out" == *DENIED* ]] || {
    echo "namespace 'default' reached ${agent}.${AGENT_NS}:8080."
    echo "the agent namespace is open to the cluster, so the positive test"
    echo "above proves nothing. probe said: $out"
    return 1
  }
}
