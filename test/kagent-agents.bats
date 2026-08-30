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
  KAGENT_NS="${KAGENT_NS:-kagent}"
  # shellcheck source=test/lib/mcp.bash
  . "${BATS_TEST_DIRNAME}/lib/mcp.bash"

  # An agent may declare tools it knows are not built yet, but only out loud.
  ROADMAP_ANNOTATION="signalloom.ai/tools-roadmap"
}

teardown() {
  mcp_pf_stop
}

# (agent, tool) pairs declared across every Agent CR, tab-separated.
requested_tool_pairs() {
  kubectl get agents -n "${NS}" -o json |
    jq -r '.items[] as $a
           | $a.spec.declarative.tools[]?.mcpServer.toolNames[]?
           | "\($a.metadata.name)\t\(.)"' | sort -u
}

# Agents that have declared, in the manifest, that some of their tools are
# roadmap items rather than working bindings.
roadmap_agents() {
  kubectl get agents -n "${NS}" -o json |
    jq -r --arg k "$ROADMAP_ANNOTATION" '
      .items[] | select((.metadata.annotations // {})[$k] != null) | .metadata.name'
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

# ═════════════════════════════════════════════════════════════════════════════
# WHY THERE IS NO LONGER ONE TEST PER AGENT PINNING ITS EXACT TOOL NAMES
#
# There used to be eight, and before that they were worse: three carried titles
# like "with compliance tools" whose bodies asserted only `runtime == go`.
# Fixing that by pinning each agent's exact toolNames list was an improvement,
# but it bought a weaker property than it looked like — those assertions read
# the manifest and compared it to a copy of the manifest. Circular, and green
# whether or not a single named tool exists.
#
# The non-circular version of the same question is "does the tool server offer
# this tool", which is asserted below against a live tools/list. That is
# strictly stronger, and it does not churn every time an agent is legitimately
# re-pointed at a different tool — which happened to five of the eight while
# this file was being written.
#
# So: shape is asserted here for all eight at once, existence is asserted
# against the server, and MCPServer references are resolved against the API.
# Nothing asserts a hardcoded tool name any more, deliberately.
# ═════════════════════════════════════════════════════════════════════════════

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

@test "kagent-agents: every agent declares a usable shape" {
  agents="$(kubectl get agents -n "${NS}" -o json)"
  total="$(printf '%s' "$agents" | jq '.items | length')"
  [ "${total:-0}" -gt 0 ] || {
    echo "no Agent CRs in ${NS} — nothing was inspected"
    return 1
  }

  # An agent with no tools cannot act; one with no MCPServer has nowhere to send
  # a call; one on an unexpected runtime is not what the docs describe.
  bad="$(printf '%s' "$agents" | jq -r '
    .items[]
    | . as $a
    | ($a.spec.declarative.runtime // "ABSENT") as $rt
    | ([$a.spec.declarative.tools[]?.mcpServer.name] | length) as $nsrv
    | ([$a.spec.declarative.tools[]?.mcpServer.toolNames[]?] | length) as $ntool
    | ($a.spec.declarative.modelConfig // "ABSENT") as $mc
    | select($rt != "go" or $nsrv < 1 or $ntool < 1 or $mc == "ABSENT")
    | "  \($a.metadata.name): runtime=\($rt) servers=\($nsrv) tools=\($ntool) modelConfig=\($mc)"')"

  if [ -n "$bad" ]; then
    echo "agents with an unusable declarative shape (of ${total}):"
    printf '%s\n' "$bad"
  fi
  [ -z "$bad" ]
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

# ═════════════════════════════════════════════════════════════════════════════
# Declared tools must exist on the tool server
#
# THE GAP THIS CLOSES. Every other assertion in this file reads a spec the repo
# itself wrote, so all of them pass whether or not a single named tool is real.
# The controller does not close the gap either: it reports
# kagent-chaos-prober as Accepted=True / Ready=True while every tool that agent
# binds is unknown to the server. "Ready" means compiled and running, not able
# to do anything, and until now nothing in the repo could tell those apart.
#
# Measured at the time of writing: the server offers 124 tools, and 3 of the 21
# (agent, tool) pairs our 8 agents request exist. Asserted per pair rather than
# per distinct name deliberately — k8s_get_resources is requested by two agents,
# so a name-wise count says 2 of 20 and hides that one of the satisfied names is
# doing double duty.
# ═════════════════════════════════════════════════════════════════════════════

@test "kagent-agents: every tool an Agent CR requests exists on the tool server" {
  # Connect in THIS shell, not inside $( ) — see the note on mcp_kagent_connect.
  mcp_kagent_connect "${KAGENT_NS}" || {
    echo "could not reach the tool server — this is a harness failure, not"
    echo "a verdict about the agents' tool bindings"
    return 1
  }
  server_tools="$(mcp_tools_list)" || {
    echo "$server_tools"
    return 1
  }
  n_server="$(printf '%s\n' "$server_tools" | grep -c .)"
  [ "${n_server:-0}" -gt 0 ]

  pairs="$(requested_tool_pairs)"
  [ -n "$pairs" ] || {
    echo "no Agent CR requests any tool — nothing was inspected"
    return 1
  }

  exempt="$(roadmap_agents)"

  missing=""
  skipped=""
  checked=0
  while IFS=$'\t' read -r agent tool; do
    [ -n "$agent" ] || continue

    is_exempt=0
    while IFS= read -r e; do
      [ -n "$e" ] && [ "$e" = "$agent" ] && is_exempt=1
    done <<<"$exempt"
    if [ "$is_exempt" -eq 1 ]; then
      skipped+="  ${agent} -> ${tool}"$'\n'
      continue
    fi

    checked=$((checked + 1))
    # Whole-line match: a substring test would let `k8s_get_resources_v2`
    # satisfy a request for `k8s_get_resources`.
    printf '%s\n' "$server_tools" | grep -qxF -- "$tool" ||
      missing+="  ${agent} -> ${tool}"$'\n'
  done <<<"$pairs"

  [ "$checked" -gt 0 ] || {
    echo "every agent is roadmap-exempt, so nothing was actually checked."
    echo "that is not a pass; remove an exemption or delete the agents."
    return 1
  }

  if [ -n "$missing" ]; then
    echo "Agent CRs request tools the server does not offer:"
    printf '%s' "$missing"
    echo
    echo "checked ${checked} (agent, tool) pairs against ${n_server} server tools"
    [ -n "$skipped" ] && { echo "roadmap-exempt, not checked:"; printf '%s' "$skipped"; }
    echo
    echo "the controller will still mark these agents Accepted/Ready — a bound"
    echo "tool that does not exist is not a startup error, it is an agent that"
    echo "silently cannot act."
  fi
  [ -z "$missing" ]
}

@test "kagent-agents: roadmap tool exemptions are declared with a reason" {
  # The exemption above is the only way to make the guard quiet, so it must not
  # be quiet itself. Every exempt agent has to say why, in the manifest, and the
  # full set is printed on every run so it cannot accumulate unnoticed.
  exempt="$(roadmap_agents)"
  if [ -z "$exempt" ]; then
    echo "no roadmap exemptions in effect — every declared tool is enforced"
    return 0
  fi

  echo "roadmap exemptions currently in effect:"
  bad=""
  while IFS= read -r agent; do
    [ -n "$agent" ] || continue
    reason="$(kubectl get agent "$agent" -n "${NS}" -o json |
      jq -r --arg k "$ROADMAP_ANNOTATION" '.metadata.annotations[$k] // ""')"
    echo "  ${agent}: ${reason:-<no reason given>}"
    # A bare "true" is not a reason. Require something a human wrote.
    case "$reason" in
      "" | "true" | "yes" | "1") bad+="$agent " ;;
    esac
  done <<<"$exempt"

  if [ -n "$bad" ]; then
    echo
    echo "these agents are exempt with no stated reason: $bad"
    echo "annotate ${ROADMAP_ANNOTATION} with why the tools do not exist yet,"
    echo "so the exemption reads as a decision rather than as an oversight"
  fi
  [ -z "$bad" ]
}
