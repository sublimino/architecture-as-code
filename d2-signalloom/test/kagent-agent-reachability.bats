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
  # shellcheck source=../../scripts/lib/live-gate.sh
  source "${REPO_ROOT}/scripts/lib/live-gate.sh"
  LIVE_CONTEXT="${KAGENT_LIVE_CONTEXT:-kind-osramp}"
  LIVE_NODE="${KAGENT_LIVE_NODE:-osramp-control-plane}"
  LIVE_OPENED=0
}

teardown() {
  # Only a test that passed the live gate can have created a probe pod.
  [ "${LIVE_OPENED:-0}" = 1 ] || return 0
  kc delete pod "npcheck-pos-$$" -n "$KAGENT_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kc delete pod "npcheck-neg-$$" -n default --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

kc() { sldc_kubectl --context "$LIVE_CONTEXT" "$@"; }

# SLDC_LIVE=1, a real KUBECONFIG, a /readyz answer and the kind node: all four,
# or the LIVE tests skip and touch nothing (scripts/lib/live-gate.sh).
cluster_up() {
  sldc_live_gate "$LIVE_CONTEXT" "$LIVE_NODE" || return 1
  LIVE_OPENED=1
}

# ── Offline safety: the live probes touch nothing unless the live gate opens ──
#
# The LIVE tests below `kubectl run` busybox pods in kagent and default and
# delete them in teardown. This suite is in the offline d2-signalloom glob, so
# a contributor with a kubeconfig loaded used to create pods on whatever cluster
# it named. Every cluster call now goes through scripts/lib/live-gate.sh.

@test "offline: the live probes reach no kubectl or docker without the live gate" {
  local rec="${BATS_TEST_TMPDIR}/rec" calls="${BATS_TEST_TMPDIR}/calls"
  mkdir -p "$rec"
  : >"$calls"
  for tool in kubectl docker; do
    printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 0\n' "$tool" "$calls" >"$rec/$tool"
    chmod +x "$rec/$tool"
  done

  # Opt-in absent, then opt-in present but KUBECONFIG=/dev/null: both refuse.
  run env -u SLDC_LIVE PATH="$rec:$PATH" bats -f '^LIVE ' "$BATS_TEST_FILENAME"
  [ "$status" -eq 0 ]
  run env SLDC_LIVE=1 KUBECONFIG=/dev/null PATH="$rec:$PATH" bats -f '^LIVE ' "$BATS_TEST_FILENAME"
  [ "$status" -eq 0 ]
  [ ! -s "$calls" ] || {
    echo "the gated LIVE tests still called a cluster tool:"
    cat "$calls"
    return 1
  }
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
  cluster_up || skip "live gate closed: ${SLDC_LIVE_GATE_REASON}"
  local agent out
  agent="$(kc get pods -n "$AGENT_NS" -l app.kubernetes.io/managed-by=kagent \
    -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/name}' 2>/dev/null)"
  # NOT a skip. `cluster_up || skip` above already excused the no-cluster case,
  # so reaching here means the cluster IS up and the agents are simply absent —
  # which is a real problem, not an inapplicable environment. Skipping would
  # leave this suite reporting all-ok with zero live coverage, which is the
  # exact shape this file's header warns about. Raised by kagent-tests-docs on
  # review; they were right.
  [ -n "$agent" ] || {
    echo "cluster is up but no pods carry app.kubernetes.io/managed-by=kagent."
    echo "the controller has minted no agent workloads, so the demo cannot run."
    return 1
  }

  out="$(kc run "npcheck-pos-$$" -n "$KAGENT_NS" --rm -i --restart=Never \
    --image=busybox:1.36 --timeout=120s -- \
    sh -c "for i in 1 2 3 4 5; do nc -zv -w3 ${agent}.${AGENT_NS} 8080 >/dev/null 2>&1 && { echo REACHABLE; exit 0; }; sleep 1; done; echo BLOCKED" 2>/dev/null)"

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
  cluster_up || skip "live gate closed: ${SLDC_LIVE_GATE_REASON}"
  local agent out
  agent="$(kc get pods -n "$AGENT_NS" -l app.kubernetes.io/managed-by=kagent \
    -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/name}' 2>/dev/null)"
  # NOT a skip. `cluster_up || skip` above already excused the no-cluster case,
  # so reaching here means the cluster IS up and the agents are simply absent —
  # which is a real problem, not an inapplicable environment. Skipping would
  # leave this suite reporting all-ok with zero live coverage, which is the
  # exact shape this file's header warns about. Raised by kagent-tests-docs on
  # review; they were right.
  [ -n "$agent" ] || {
    echo "cluster is up but no pods carry app.kubernetes.io/managed-by=kagent."
    echo "the controller has minted no agent workloads, so the demo cannot run."
    return 1
  }

  out="$(kc run "npcheck-neg-$$" -n default --rm -i --restart=Never \
    --image=busybox:1.36 --timeout=120s -- \
    sh -c "nc -zv -w5 ${agent}.${AGENT_NS} 8080 >/dev/null 2>&1 && echo REACHABLE || echo DENIED" 2>/dev/null)"

  [[ "$out" == *DENIED* ]] || {
    echo "namespace 'default' reached ${agent}.${AGENT_NS}:8080."
    echo "the agent namespace is open to the cluster, so the positive test"
    echo "above proves nothing. probe said: $out"
    return 1
  }
}
