#!/usr/bin/env bats
# test/kagent-adversarial.bats — Adversarial Security, Negative RBAC & Boundary Probes

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.kind/kubeconfig}"
  if [ -f "${KUBECONFIG_PATH}" ]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
  fi
  NS="fe-signalloom-agents"
}

@test "kagent-adversarial: read-only reader SA is denied creating pods in any namespace" {
  run kubectl auth can-i create pods --as="system:serviceaccount:${NS}:kagent-k8s-reader" -n default
  [ "$status" -eq 1 ] || [ "$output" = "no" ]
}

@test "kagent-adversarial: read-only reader SA is denied deleting namespaces" {
  run kubectl auth can-i delete namespaces --as="system:serviceaccount:${NS}:kagent-k8s-reader"
  [ "$status" -eq 1 ] || [ "$output" = "no" ]
}

@test "kagent-adversarial: commit-summariser SA is denied reading secrets outside its scope" {
  run kubectl auth can-i get secrets --as="system:serviceaccount:${NS}:kagent-commit-summariser" -n kube-system
  [ "$status" -eq 1 ] || [ "$output" = "no" ]
}

@test "kagent-adversarial: security-analyst SA is denied modifying cluster RBAC bindings" {
  run kubectl auth can-i create clusterrolebindings --as="system:serviceaccount:${NS}:kagent-security-analyst"
  [ "$status" -eq 1 ] || [ "$output" = "no" ]
}

@test "kagent-adversarial: controller Deployment limits memory strictly <= 512Mi" {
  run kubectl get deploy kagent-controller -n kagent -o jsonpath="{.spec.template.spec.containers[0].resources.limits.memory}"
  [ "$status" -eq 0 ]
  [ "$output" = "512Mi" ]
}

@test "kagent-adversarial: postgres state store has active restrictive NetworkPolicy" {
  run kubectl get netpol kagent-postgres-isolation -n kagent -o jsonpath="{.spec.ingress[0].from[0].podSelector.matchLabels.app\\.kubernetes\\.io/component}"
  [ "$status" -eq 0 ]
  [ "$output" = "controller" ]
}
