#!/usr/bin/env bats
# test/kagent-agents.bats — Agent CR inventory and declared-tool contract.
#
# SCOPE. Every assertion here reads the SPEC of an object the repo itself
# applied. That makes this suite a check that `kubectl apply` succeeded and
# that the manifests say what the docs claim — worth having, and precisely
# bounded. It is not evidence that any agent runs, because nothing in a spec
# can be. The status side of the contract lives in test/kagent-anti-stub.bats
# ("every Agent CR has been reconciled to a non-null status").
#
# Three of these tests previously carried titles — "with compliance tools",
# "with finops tools", "with chaos tools" — whose bodies asserted only
# `runtime == go`. Identical assertions, three different claims. The tool names
# are now asserted for real.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.kind/kubeconfig}"
  if [ -f "${KUBECONFIG_PATH}" ]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
  fi
  NS="fe-signalloom-agents"
}

# The MCPServer names an agent binds to, comma-joined and sorted.
agent_servers() {
  kubectl get agent "$1" -n "${NS}" -o json |
    jq -r '[ .spec.declarative.tools[]?.mcpServer.name ] | sort | join(",")'
}

# The individual tool names an agent may call, comma-joined and sorted.
agent_tool_names() {
  kubectl get agent "$1" -n "${NS}" -o json |
    jq -r '[ .spec.declarative.tools[]?.mcpServer.toolNames[]? ] | sort | join(",")'
}

assert_agent() {
  local name="$1" want_servers="$2" want_tools="$3"

  run kubectl get agent "$name" -n "${NS}" -o jsonpath='{.spec.declarative.runtime}'
  [ "$status" -eq 0 ]
  [ "$output" = "go" ]

  local got_servers got_tools
  got_servers="$(agent_servers "$name")"
  got_tools="$(agent_tool_names "$name")"

  [ "$got_servers" = "$want_servers" ] || {
    echo "$name MCPServer bindings:"
    echo "  want: $want_servers"
    echo "  got : $got_servers"
    return 1
  }
  [ "$got_tools" = "$want_tools" ] || {
    echo "$name callable tool names:"
    echo "  want: $want_tools"
    echo "  got : $got_tools"
    return 1
  }
}

@test "kagent-agents: exactly 8 Agent CRs exist in fe-signalloom-agents" {
  # `wc -l` over `echo "$output"` counts 1 for empty output, so the old form
  # could not distinguish "none" from "one". Count the array instead, and pin
  # the number: docs/kagent-d5.md and scripts/kagent-agents.sh both enumerate
  # eight, so a ninth appearing unannounced is a documentation drift bug.
  run kubectl get agents -n "${NS}" -o json
  [ "$status" -eq 0 ]
  count="$(printf '%s' "$output" | jq '.items | length')"
  [ "${count:-0}" -eq 8 ] || {
    echo "expected 8 Agent CRs, found ${count:-0}:"
    kubectl get agents -n "${NS}" --no-headers
    return 1
  }
}

@test "kagent-agents: kagent-k8s-reader binds the cluster-read tools" {
  assert_agent kagent-k8s-reader \
    "kagent-tool-server" \
    "k8s_get_available_api_resources,k8s_get_resources"
}

@test "kagent-agents: kagent-commit-summariser binds the github tools" {
  assert_agent kagent-commit-summariser \
    "github-tool" \
    "github_get_commit,github_list_commits"
}

@test "kagent-agents: kagent-security-analyst binds 3 tool servers" {
  assert_agent kagent-security-analyst \
    "kagent-tool-server,policy-eval-tool,vuln-db-tool" \
    "evaluate_netpol,evaluate_rbac_policy,k8s_get_resources,lookup_cve,query_advisories"
}

@test "kagent-agents: kagent-network-auditor binds the network probe tools" {
  assert_agent kagent-network-auditor \
    "network-probe-tool" \
    "audit_netpol_rules,inspect_envoy_routes,probe_spiffe_boundaries"
}

@test "kagent-agents: kagent-incident-responder binds the incident triage tools" {
  assert_agent kagent-incident-responder \
    "incident-triage-tool" \
    "correlate_restarts,propose_remediation,triage_alert_events"
}

@test "kagent-agents: kagent-compliance-checker binds the compliance tools" {
  assert_agent kagent-compliance-checker \
    "kagent-tool-server" \
    "compliance_audit_cis,compliance_check_policies"
}

@test "kagent-agents: kagent-finops-optimizer binds the finops tools" {
  assert_agent kagent-finops-optimizer \
    "kagent-tool-server" \
    "finops_identify_waste,finops_query_metrics"
}

@test "kagent-agents: kagent-chaos-prober binds the chaos tools" {
  assert_agent kagent-chaos-prober \
    "kagent-tool-server" \
    "chaos_probe_recovery,chaos_simulate_latency"
}

@test "kagent-agents: every MCPServer an Agent references actually exists" {
  # Was: a fixed list of five names checked for existence. That could not catch
  # the failure that matters — an Agent binding a server nobody ever created,
  # which the API server accepts without complaint. Derive the required set from
  # the Agent CRs themselves so the check cannot drift away from them.
  wanted="$(kubectl get agents -n "${NS}" -o json |
    jq -r '[ .items[].spec.declarative.tools[]?.mcpServer.name ] | unique | .[]')"
  [ -n "$wanted" ] || {
    echo "no Agent CR references any MCPServer — nothing was inspected"
    return 1
  }

  # kagent-tool-server is the control-plane MCP endpoint in namespace kagent,
  # not an MCPServer CR in this namespace. Everything else must resolve here.
  missing=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$name" = "kagent-tool-server" ] && continue
    if ! kubectl get mcpserver "$name" -n "${NS}" >/dev/null 2>&1; then
      missing+="$name "
    fi
  done <<<"$wanted"

  if [ -n "$missing" ]; then
    echo "Agent CRs reference MCPServers that do not exist: $missing"
    echo "MCPServers present in ${NS}:"
    kubectl get mcpserver -n "${NS}" --no-headers
  fi
  [ -z "$missing" ]
}
