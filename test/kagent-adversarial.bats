#!/usr/bin/env bats
# test/kagent-adversarial.bats — Negative RBAC and boundary probes.
#
# WHY EVERY DENIAL HERE NOW CARRIES A POSITIVE CONTROL
# ----------------------------------------------------
# `kubectl auth can-i <verb> <res> --as=system:serviceaccount:<ns>:<name>`
# answers "no" for a ServiceAccount that does not exist, for one that exists
# with no bindings, and for one that exists and is deliberately confined. Three
# very different states, one indistinguishable answer. Every test in this file
# used to assert only that answer, so all four passed identically whether the
# RBAC model was carefully drawn or entirely absent.
#
# Verified on this cluster:
#   kubectl auth can-i create pods --as=system:serviceaccount:fe-signalloom-agents:does-not-exist-at-all
#   -> no
#
# So each denial now (a) requires the subject ServiceAccount to exist, and the
# file as a whole carries (b) a positive control proving RBAC evaluation is live
# and is returning "no" as a decision rather than as a default.
#
# KNOWN LIMIT, STATED RATHER THAN HIDDEN: of the eight agent ServiceAccounts,
# only kagent-k8s-reader is bound to any Role. The other seven hold no
# permissions at all, so their denials below are true but weak — they confirm
# an absence, not a boundary. The positive control can therefore only be built
# on kagent-k8s-reader. This is reported upstream as a production gap; it is
# not something a test file can fix.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.kind/kubeconfig}"
  if [ -f "${KUBECONFIG_PATH}" ]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
  fi
  NS="fe-signalloom-agents"
}

# Assert a subject exists and is refused. The existence check is what stops
# this from passing for a ServiceAccount nobody ever created.
assert_denied() {
  local sa="$1" verb="$2" resource="$3"
  shift 3
  local sa_ns="${SA_NS:-$NS}"

  kubectl get sa "$sa" -n "$sa_ns" >/dev/null 2>&1 || {
    echo "ServiceAccount ${sa_ns}/${sa} does not exist"
    echo "'can-i' answers 'no' for a subject that was never created, so this"
    echo "denial would be evidence of nothing at all"
    return 1
  }

  # stdout only. For a cluster-scoped resource kubectl writes
  # "Warning: resource 'namespaces' is not namespace scoped" to STDERR; folding
  # that in with 2>&1 makes the verdict "Warning: ...\n\nno", which never equals
  # "no" and reports a *permitted* action for one that was in fact refused —
  # a denial test that fails loudly while the boundary is intact.
  local verdict
  verdict="$(kubectl auth can-i "$verb" "$resource" \
    --as="system:serviceaccount:${sa_ns}:${sa}" "$@" 2>/dev/null || true)"
  verdict="$(printf '%s' "$verdict" | tr -d '\r' | tail -1)"

  [ "$verdict" = "no" ] || {
    echo "${sa_ns}/${sa} is permitted to '${verb} ${resource}' ($*): '${verdict}'"
    return 1
  }
}

@test "kagent-adversarial: RBAC evaluation is live (positive control)" {
  # THE CONTROL FOR THIS ENTIRE FILE. If this fails, every "no" below is
  # uninformative and the denials must not be read as security evidence.
  kubectl get sa kagent-k8s-reader -n "${NS}" >/dev/null

  verdict="$(kubectl auth can-i get pods \
    --as="system:serviceaccount:${NS}:kagent-k8s-reader" -n default 2>/dev/null || true)"
  verdict="$(printf '%s' "$verdict" | tr -d '\r' | tail -1)"
  [ "$verdict" = "yes" ] || {
    echo "kagent-k8s-reader cannot 'get pods', which its ClusterRole grants."
    echo "verdict: ${verdict}"
    echo "RBAC is not being evaluated as expected — treat every denial in this"
    echo "file as unproven until this passes."
    return 1
  }
}

@test "kagent-adversarial: every agent ServiceAccount exists" {
  # Denials are only meaningful against subjects that are really there. Assert
  # the population once, so a deleted ServiceAccount surfaces here as a missing
  # identity rather than downstream as a suspiciously well-behaved agent.
  missing=""
  for sa in kagent-k8s-reader kagent-commit-summariser kagent-security-analyst \
    kagent-network-auditor kagent-incident-responder kagent-compliance-checker \
    kagent-finops-optimizer kagent-chaos-prober; do
    kubectl get sa "$sa" -n "${NS}" >/dev/null 2>&1 || missing+="$sa "
  done
  if [ -n "$missing" ]; then
    echo "agent ServiceAccounts absent from ${NS}: $missing"
  fi
  [ -z "$missing" ]
}

@test "kagent-adversarial: read-only reader SA is denied creating pods in any namespace" {
  assert_denied kagent-k8s-reader create pods -n default
  assert_denied kagent-k8s-reader create pods -n kube-system
  assert_denied kagent-k8s-reader create pods -n "${NS}"
}

@test "kagent-adversarial: read-only reader SA is denied deleting namespaces" {
  assert_denied kagent-k8s-reader delete namespaces
}

@test "kagent-adversarial: read-only reader SA is denied reading secrets" {
  # The sharpest denial available on the one agent that holds real grants: its
  # ClusterRole lists pods/services/deployments/namespaces/nodes/events and
  # deliberately omits secrets. Because the same subject demonstrably gets a
  # "yes" elsewhere, this "no" is a decision about secrets specifically.
  assert_denied kagent-k8s-reader get secrets -n kube-system
  assert_denied kagent-k8s-reader get secrets -n "${NS}"
}

@test "kagent-adversarial: commit-summariser SA is denied reading secrets outside its scope" {
  assert_denied kagent-commit-summariser get secrets -n kube-system
}

@test "kagent-adversarial: security-analyst SA is denied modifying cluster RBAC bindings" {
  assert_denied kagent-security-analyst create clusterrolebindings
}

@test "kagent-adversarial: the controller can write Agent status but cannot escalate RBAC" {
  # Two halves of the same boundary, and the pairing is the point. The write
  # permission is the one without which reconciliation is impossible, so
  # asserting it turns "Agent CRs have null status" into an unambiguous signal
  # about the controller rather than about its role. The refusal is the
  # escalation path a compromised controller would reach for first.
  SA_NS=kagent

  kubectl get sa kagent-controller -n kagent >/dev/null

  verdict="$(kubectl auth can-i update agents/status \
    --as="system:serviceaccount:kagent:kagent-controller" -n "${NS}" 2>/dev/null || true)"
  verdict="$(printf '%s' "$verdict" | tr -d '\r' | tail -1)"
  [ "$verdict" = "yes" ] || {
    echo "the controller cannot write agents/status (verdict: ${verdict})"
    echo "with this role no controller could ever reconcile an Agent CR, so the"
    echo "null-status finding in test/kagent-anti-stub.bats would be an RBAC bug"
    return 1
  }

  assert_denied kagent-controller create clusterrolebindings
  assert_denied kagent-controller escalate clusterroles
}

@test "kagent-adversarial: postgres NetworkPolicy actually declares Ingress" {
  # A NetworkPolicy whose policyTypes omit Ingress imposes no ingress
  # restriction whatsoever, while `kubectl get netpol` renders it exactly like
  # one that does. The ingress rule itself is asserted in test/kagent-install.bats;
  # this asserts the rule is switched on.
  run kubectl get netpol kagent-postgres-isolation -n kagent -o json
  [ "$status" -eq 0 ]

  types="$(printf '%s' "$output" | jq -r '(.spec.policyTypes // []) | join(",")')"
  [[ "$types" == *"Ingress"* ]] || {
    echo "policyTypes = '${types}' — no Ingress, so this policy restricts no inbound traffic"
    return 1
  }
}
