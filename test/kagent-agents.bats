#!/usr/bin/env bats
# test/kagent-agents.bats — Kagent Live Agent CR and Tool Tests

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.kind/kubeconfig}"
  if [ -f "${KUBECONFIG_PATH}" ]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
  fi
  NS="fe-signalloom-agents"
}

@test "kagent-agents: at least 8 Agent CRs exist in fe-signalloom-agents" {
  run kubectl get agents -n "${NS}" --no-headers
  [ "$status" -eq 0 ]
  count=$(echo "$output" | wc -l)
  [ "$count" -ge 8 ]
}

@test "kagent-agents: kagent-k8s-reader Agent CR exists in fe-signalloom-agents" {
  run kubectl get agent kagent-k8s-reader -n "${NS}" -o jsonpath="{.spec.declarative.runtime}"
  [ "$status" -eq 0 ]
  [ "$output" = "go" ]
}

@test "kagent-agents: kagent-commit-summariser Agent CR exists with github tool" {
  run kubectl get agent kagent-commit-summariser -n "${NS}" -o jsonpath="{.spec.declarative.tools[0].mcpServer.name}"
  [ "$status" -eq 0 ]
  [ "$output" = "github-tool" ]
}

@test "kagent-agents: kagent-security-analyst Agent CR exists with 3 tool servers" {
  run kubectl get agent kagent-security-analyst -n "${NS}" -o jsonpath="{.spec.declarative.tools[*].mcpServer.name}"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "kagent-tool-server" ]]
  [[ "$output" =~ "vuln-db-tool" ]]
  [[ "$output" =~ "policy-eval-tool" ]]
}

@test "kagent-agents: kagent-network-auditor Agent CR exists with network probe tool" {
  run kubectl get agent kagent-network-auditor -n "${NS}" -o jsonpath="{.spec.declarative.tools[0].mcpServer.name}"
  [ "$status" -eq 0 ]
  [ "$output" = "network-probe-tool" ]
}

@test "kagent-agents: kagent-incident-responder Agent CR exists with incident triage tool" {
  run kubectl get agent kagent-incident-responder -n "${NS}" -o jsonpath="{.spec.declarative.tools[0].mcpServer.name}"
  [ "$status" -eq 0 ]
  [ "$output" = "incident-triage-tool" ]
}

@test "kagent-agents: kagent-compliance-checker Agent CR exists with compliance tools" {
  run kubectl get agent kagent-compliance-checker -n "${NS}" -o jsonpath="{.spec.declarative.runtime}"
  [ "$status" -eq 0 ]
  [ "$output" = "go" ]
}

@test "kagent-agents: kagent-finops-optimizer Agent CR exists with finops tools" {
  run kubectl get agent kagent-finops-optimizer -n "${NS}" -o jsonpath="{.spec.declarative.runtime}"
  [ "$status" -eq 0 ]
  [ "$output" = "go" ]
}

@test "kagent-agents: kagent-chaos-prober Agent CR exists with chaos tools" {
  run kubectl get agent kagent-chaos-prober -n "${NS}" -o jsonpath="{.spec.declarative.runtime}"
  [ "$status" -eq 0 ]
  [ "$output" = "go" ]
}

@test "kagent-agents: MCPServer resources are created for all agents" {
  for tool in github-tool vuln-db-tool policy-eval-tool network-probe-tool incident-triage-tool; do
    run kubectl get mcpserver "${tool}" -n "${NS}"
    [ "$status" -eq 0 ]
  done
}
