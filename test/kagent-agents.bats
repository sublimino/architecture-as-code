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

  # DEFERRED AGENTS — two sources, one preferred, and a path from one to the other.
  #
  # PREFERRED: an annotation on the Agent CR itself,
  #   signalloom.ai/tools-roadmap=<reason>
  # so the decision lives in the manifest it describes and cannot drift from it.
  #
  # TRANSITIONAL: the DEFERRED_AGENTS list below. It exists because the branches
  # that own those manifests asked for a by-name list and are not adding
  # annotations; an annotation-only mechanism would have kept this guard red on
  # a decision that had actually been made. Entries here should migrate to
  # annotations and the list should end up empty.
  #
  # A hardcoded list normally rots into a permanent hole. Two clauses stop that,
  # both in "deferred agents are still genuinely blocked" below:
  #   * the moment a deferred agent's tools DO appear on the server the deferral
  #     is stale and fails until removed, so the list can only shrink by itself;
  #   * an agent deferred by BOTH mechanisms is reported as redundant, so the
  #     migration to annotations finishes rather than leaving two sources of
  #     truth disagreeing quietly.
  ROADMAP_ANNOTATION="signalloom.ai/tools-roadmap"
  DEFERRED_AGENTS="kagent-chaos-prober kagent-commit-summariser"
  DEFERRED_REASON_kagent_chaos_prober="no chaos_* tool exists on the server"
  DEFERRED_REASON_kagent_commit_summariser="no github_* tool exists on the server; github-tool RemoteMCPServer is absent"
}

# Deferred by annotation (preferred) or by list (transitional).
deferred_by_annotation() {
  local v
  v="$(kubectl get agent "$1" -n "${NS}" -o json 2>/dev/null |
    jq -r --arg k "$ROADMAP_ANNOTATION" '.metadata.annotations[$k] // ""')"
  [ -n "$v" ]
}

deferred_by_list() {
  local a="$1" d
  for d in $DEFERRED_AGENTS; do
    [ "$d" = "$a" ] && return 0
  done
  return 1
}

is_deferred() {
  deferred_by_annotation "$1" || deferred_by_list "$1"
}

# The recorded justification, from whichever source declares it.
deferral_reason() {
  local a="$1" v var
  v="$(kubectl get agent "$a" -n "${NS}" -o json 2>/dev/null |
    jq -r --arg k "$ROADMAP_ANNOTATION" '.metadata.annotations[$k] // ""')"
  if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  var="DEFERRED_REASON_${a//-/_}"
  printf '%s' "${!var:-}"
}

# Every agent currently deferred, by either mechanism.
all_deferred_agents() {
  { printf '%s\n' $DEFERRED_AGENTS
    kubectl get agents -n "${NS}" -o json 2>/dev/null |
      jq -r --arg k "$ROADMAP_ANNOTATION" '
        .items[] | select((.metadata.annotations // {})[$k] != null) | .metadata.name'
  } | sed '/^$/d' | sort -u
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

  missing=""
  skipped=""
  checked=0
  while IFS=$'\t' read -r agent tool; do
    [ -n "$agent" ] || continue

    if is_deferred "$agent"; then
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
    echo "every agent is deferred, so nothing was actually checked."
    echo "that is not a pass; shorten DEFERRED_AGENTS or delete the agents."
    return 1
  }

  if [ -n "$missing" ]; then
    echo "Agent CRs request tools the server does not offer:"
    printf '%s' "$missing"
    echo
    echo "checked ${checked} (agent, tool) pairs against ${n_server} server tools"
    [ -n "$skipped" ] && { echo "deferred, not checked:"; printf '%s' "$skipped"; }
    echo
    echo "the controller will still mark these agents Accepted/Ready — a bound"
    echo "tool that does not exist is not a startup error, it is an agent that"
    echo "silently cannot act."
  fi
  [ -z "$missing" ]
}

@test "kagent-agents: deferred agents are still genuinely blocked" {
  # THE ANTI-ROT CLAUSE, and the reason a hardcoded list is acceptable at all.
  # A deferral is a claim that the tools do not exist. If they appear, the claim
  # is false and the agent must rejoin the enforced set. Without this, the list
  # is a permanent hole that outlives its reason and nobody notices — which is
  # the failure this whole suite exists to prevent, in miniature.
  deferred="$(all_deferred_agents)"
  if [ -z "$deferred" ]; then
    echo "no agents deferred — every declared tool is enforced"
    return 0
  fi

  mcp_kagent_connect "${KAGENT_NS}" || {
    echo "could not reach the tool server — harness failure, not a verdict"
    return 1
  }
  server_tools="$(mcp_tools_list)" || { echo "$server_tools"; return 1; }

  pairs="$(requested_tool_pairs)"
  now_available=""
  unknown_agents=""
  no_reason=""
  redundant=""

  while IFS= read -r d; do
    [ -n "$d" ] || continue
    # A deferral naming an agent that no longer exists is also stale.
    kubectl get agent "$d" -n "${NS}" >/dev/null 2>&1 || {
      unknown_agents+="$d "
      continue
    }
    reason="$(deferral_reason "$d")"
    src="list"
    deferred_by_annotation "$d" && src="annotation"
    if deferred_by_annotation "$d" && deferred_by_list "$d"; then
      src="annotation+list"
      redundant+="$d "
    fi
    echo "deferred [$src]: $d — ${reason:-<no reason recorded>}"
    case "$reason" in
      "" | true | yes | 1) no_reason+="$d " ;;
    esac
  done <<<"$deferred"

  while IFS=$'\t' read -r agent tool; do
    [ -n "$agent" ] || continue
    is_deferred "$agent" || continue
    if printf '%s\n' "$server_tools" | grep -qxF -- "$tool"; then
      now_available+="  ${agent} -> ${tool}"$'\n'
    fi
  done <<<"$pairs"

  [ -z "$unknown_agents" ] || echo "deferral names agents that do not exist: $unknown_agents"
  [ -z "$no_reason" ] || {
    echo "deferred with no stated reason: $no_reason"
    echo "a deferral must say why, or it reads as an oversight rather than a decision"
  }
  [ -z "$redundant" ] || {
    echo "deferred twice (annotation AND DEFERRED_AGENTS): $redundant"
    echo "the annotation is the preferred home — drop these from DEFERRED_AGENTS"
    echo "so there is one source of truth rather than two that can disagree"
  }
  if [ -n "$now_available" ]; then
    echo "these deferred tools now EXIST on the server:"
    printf '%s' "$now_available"
    echo "the deferral is stale — un-defer the agent so the tool-existence guard"
    echo "starts enforcing it again"
  fi

  [ -z "$unknown_agents" ]
  [ -z "$no_reason" ]
  [ -z "$redundant" ]
  [ -z "$now_available" ]
}
