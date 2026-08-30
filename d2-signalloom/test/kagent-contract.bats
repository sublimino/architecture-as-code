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

# ─── ServiceAccount-name derivation (SPIFFE identity integrity) ──────────────
#
# `_agent_from_kagent_cr` in apps/fake-integration-proxy/server.py reports
# `"service_account": <Agent CR metadata.name>`. It has no choice: an
# Agent.kagent.dev CR carries no ServiceAccount field, so the name is DERIVED,
# not observed.
#
# The dashboard turns that value into the second half of a SPIFFE ID
# (spiffe://<trust-domain>/ns/<ns>/sa/<sa>) in the Credential Inventory. So the
# moment one agent's ServiceAccount stops being named after the agent, the
# governance UI renders an identity SPIRE never issued — a fabricated
# credential, displayed with the same confidence as a real one, with nothing
# anywhere failing. The pod path refuses the analogous guess for exactly this
# reason ("Absent stays None — defaulting to 'default' would render a SPIFFE ID
# that was never registered", server.py).
#
# These tests are what make the derivation legitimate rather than lucky: they
# convert an unwritten naming convention into an enforced invariant, so a future
# agent that breaks it fails here instead of in the UI.

@test "kagent-contract: every Kagent agent's ServiceAccount is named after the agent" {
  count=0
  for dir in "${REPO_ROOT}/d2-signalloom/infra/agent-swarm"/kagent-*/; do
    agent_yaml="${dir}agent.yaml"
    sa_yaml="${dir}serviceaccount.yaml"
    [ -f "$agent_yaml" ] || continue

    # A missing ServiceAccount is a failure, not a skip: the proxy would still
    # emit a service_account for this agent, naming an SA that does not exist.
    [ -f "$sa_yaml" ] || {
      echo "no serviceaccount.yaml beside $(basename "$dir")agent.yaml"
      echo "(the proxy derives service_account for it regardless — see server.py)"
      return 1
    }

    agent_name="$(yq -r 'select(.kind == "Agent") | .metadata.name' "$agent_yaml")"
    sa_name="$(yq -r 'select(.kind == "ServiceAccount") | .metadata.name' "$sa_yaml")"
    [ -n "$agent_name" ] && [ "$agent_name" != "null" ]
    [ -n "$sa_name" ] && [ "$sa_name" != "null" ]

    [ "$agent_name" = "$sa_name" ] || {
      echo "SPIFFE derivation broken for $(basename "$dir")"
      echo "  Agent CR name  : $agent_name"
      echo "  ServiceAccount : $sa_name"
      echo "the proxy would report service_account=$agent_name, an SA that is not"
      echo "the one this workload runs as — a SPIFFE ID SPIRE never issued"
      return 1
    }
    count=$((count + 1))
  done
  [ "$count" -ge 8 ]
}

@test "kagent-contract: every agent-card spiffeId ends in the agent's own ServiceAccount" {
  # Independent second witness on the same invariant. The card's spiffeId is
  # the identity the A2A contract advertises; the SA is the identity SPIRE
  # actually issues against. They must name the same principal.
  count=0
  for card in "${REPO_ROOT}/d2-signalloom/infra/agent-swarm"/kagent-*/agent-card.json; do
    [ -f "$card" ] || continue
    dir="$(dirname "$card")"
    sa_name="$(yq -r 'select(.kind == "ServiceAccount") | .metadata.name' "${dir}/serviceaccount.yaml")"
    spiffe_id="$(jq -r '.spiffeId' "$card")"
    card_name="$(jq -r '.name' "$card")"

    [ "$card_name" = "$sa_name" ] || {
      echo "$(basename "$dir"): agent-card name '$card_name' != ServiceAccount '$sa_name'"
      return 1
    }

    # Compared as a whole trailing segment, not a substring: a plain grep would
    # let /sa/kagent-k8s-reader-v2 satisfy a check for kagent-k8s-reader.
    [ "${spiffe_id##*/sa/}" = "$sa_name" ] || {
      echo "$(basename "$dir"): spiffeId '$spiffe_id' does not end in /sa/$sa_name"
      return 1
    }
    count=$((count + 1))
  done
  [ "$count" -ge 8 ]
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
