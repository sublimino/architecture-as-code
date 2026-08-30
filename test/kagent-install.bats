#!/usr/bin/env bats
# test/kagent-install.bats — Kagent v0.9.9 Infrastructure & CRD Verification

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.kind/kubeconfig}"
  if [ -f "${KUBECONFIG_PATH}" ]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
  fi
}

@test "kagent: CustomResourceDefinitions are registered in cluster" {
  run kubectl get crd agents.kagent.dev
  [ "$status" -eq 0 ]
  run kubectl get crd modelconfigs.kagent.dev
  [ "$status" -eq 0 ]
  run kubectl get crd mcpservers.kagent.dev
  [ "$status" -eq 0 ]
}

@test "kagent: kagent namespace exists with governance label" {
  run kubectl get namespace kagent -o jsonpath='{.metadata.labels.controlplane\.io/governance}'
  [ "$status" -eq 0 ]
  [ "$output" = "infrastructure" ]
}

@test "kagent: controller deployment is running with <=512Mi memory limit" {
  run kubectl get deployment kagent-controller -n kagent -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
  [ "$status" -eq 0 ]
  [ "$output" = "512Mi" ]
}

@test "kagent: bundled postgres state store is running" {
  run kubectl get deployment kagent-postgres -n kagent -o jsonpath='{.status.readyReplicas}'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "kagent: tool-server deployment is ready" {
  run kubectl get deployment kagent-tool-server -n kagent -o jsonpath='{.status.readyReplicas}'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "kagent: UI deployment is present" {
  run kubectl get deployment kagent-ui -n kagent -o jsonpath='{.status.readyReplicas}'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "kagent: postgres network policy restricts ingress to controller" {
  run kubectl get networkpolicy kagent-postgres-isolation -n kagent -o jsonpath='{.spec.ingress[0].from[0].podSelector.matchLabels.app\.kubernetes\.io/name}'
  [ "$status" -eq 0 ]
  [ "$output" = "kagent" ]
}
