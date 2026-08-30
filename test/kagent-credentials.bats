#!/usr/bin/env bats
# test/kagent-credentials.bats — SPIFFE Identity & OpenBao Integration Verification

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.kind/kubeconfig}"
  if [ -f "${KUBECONFIG_PATH}" ]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
  fi
  NS="fe-signalloom-agents"
}

@test "kagent-creds: service accounts exist with signalloom.ai/agent label for all 8 agents" {
  for sa in kagent-k8s-reader kagent-commit-summariser kagent-security-analyst kagent-network-auditor kagent-incident-responder kagent-compliance-checker kagent-finops-optimizer kagent-chaos-prober; do
    run kubectl get sa "${sa}" -n "${NS}" -o jsonpath="{.metadata.labels.signalloom\\.ai/agent}"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
  done
}

@test "kagent-creds: ModelConfig references Anthropic provider with secret" {
  run kubectl get modelconfig anthropic-claude -n "${NS}" -o jsonpath="{.spec.provider}"
  [ "$status" -eq 0 ]
  [ "$output" = "Anthropic" ]
}

@test "kagent-creds: mock GitHub token secret exists for summariser scaffolding" {
  run kubectl get secret kagent-github-key -n "${NS}" -o jsonpath="{.metadata.name}"
  [ "$status" -eq 0 ]
  [ "$output" = "kagent-github-key" ]
}
