#!/usr/bin/env bats
# d2-signalloom/test/kagent-contract.bats — Kagent Declarative Contract & Schema Tests

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "kagent-contract: Agent CR definitions are strictly fewer than 50 lines each across all agents" {
  count=0
  for f in "${REPO_ROOT}/d2-signalloom/infra/agent-swarm"/kagent-*/agent.yaml; do
    [ -f "$f" ]
    lines=$(wc -l < "$f")
    [ "$lines" -lt 50 ]
    count=$((count + 1))
  done
  [ "$count" -ge 8 ]
}

@test "kagent-contract: all Kagent agents declare signalloom.ai/agent label" {
  count=0
  for f in "${REPO_ROOT}/d2-signalloom/infra/agent-swarm"/kagent-*/agent.yaml; do
    grep -q "signalloom.ai/agent" "$f"
    count=$((count + 1))
  done
  [ "$count" -ge 8 ]
}

@test "kagent-contract: K8s Reader uses Go runtime and ModelConfig" {
  f="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-k8s-reader/agent.yaml"
  grep -q "runtime: go" "$f"
  grep -q "modelConfig: anthropic-claude" "$f"
}

@test "kagent-contract: OpenBao secret path map covers all 8 Kagent agents" {
  cm="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/openbao-secret-paths.yaml"
  for agent in kagent-k8s-reader kagent-commit-summariser kagent-security-analyst kagent-network-auditor kagent-incident-responder kagent-compliance-checker kagent-finops-optimizer kagent-chaos-prober; do
    grep -q "${agent}.json:" "$cm"
  done
}

@test "kagent-contract: A2A agent-cards exist and conform to schema" {
  count=0
  for card in "${REPO_ROOT}/d2-signalloom/infra/agent-swarm"/kagent-*/agent-card.json; do
    [ -f "$card" ] || continue
    jq -e ".name != null and .spiffeId != null and .runtime != null" "$card" >/dev/null
    count=$((count + 1))
  done
  [ "$count" -ge 8 ]
}
