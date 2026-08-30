# test/lib/mcp.bash — minimal MCP streamable-HTTP client for bats suites.
#
# Exists because "does this tool exist?" cannot be answered from the manifests.
# An Agent CR names tools in `toolNames`; nothing validates them against the
# server, and the kagent controller does not either — it will report an agent
# Accepted=True / Ready=True while every tool it binds is unknown to the tool
# server. Answering the question means speaking the protocol.
#
# THREE TRAPS, ALL OF WHICH RETURN SOMETHING THAT LOOKS LIKE AN ANSWER:
#
#   1. A bare `tools/list` POST returns HTTP 400. The handshake is mandatory:
#      initialize -> keep the `mcp-session-id` response header -> send
#      notifications/initialized -> then call tools/list.
#   2. The reply may be SSE-framed (`data: {...}`) or plain JSON, and it varies
#      by call. A parser that assumes either one reads ZERO tools from the
#      other and reports "no tools on the server", which is indistinguishable
#      from a server that genuinely offers none. Measured on kagent-tools
#      0.2.1: tools/list answers in plain JSON. Both are handled.
#   3. An empty tool list makes every "is this tool present?" check fail, so an
#      unreachable or mis-parsed server reads as "all 21 tools are missing" —
#      a true-looking verdict for an entirely wrong reason. mcp_tools_list
#      therefore fails loudly on an empty list rather than returning it.

# Start a port-forward to a Service and set MCP_PORT / MCP_PF_PID.
# The caller's teardown() is responsible for killing MCP_PF_PID.
mcp_pf_start() {
  local ns="$1" svc="$2" port="$3"
  local log="${BATS_TEST_TMPDIR:-/tmp}/mcp-pf-${svc}.log"
  : >"$log"
  kubectl port-forward -n "$ns" "svc/${svc}" ":${port}" >"$log" 2>&1 &
  MCP_PF_PID=$!
  MCP_PORT=""
  local i
  for i in $(seq 1 60); do
    MCP_PORT="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$log" | head -1)"
    [ -n "$MCP_PORT" ] && break
    if ! kill -0 "$MCP_PF_PID" 2>/dev/null; then
      echo "port-forward to ${ns}/${svc}:${port} died:"
      cat "$log"
      return 1
    fi
    sleep 0.25
  done
  [ -n "$MCP_PORT" ] || {
    echo "port-forward to ${ns}/${svc}:${port} never reported a local port:"
    cat "$log"
    return 1
  }
}

mcp_pf_stop() {
  if [ -n "${MCP_PF_PID:-}" ]; then
    kill "${MCP_PF_PID}" 2>/dev/null || true
    wait "${MCP_PF_PID}" 2>/dev/null || true
    MCP_PF_PID=""
  fi
}

# A reply may arrive SSE-framed or as plain JSON. Prefer the SSE payload when
# `data:` lines are present, fall back to the whole body otherwise.
mcp_unframe() {
  local raw="$1" body
  body="$(printf '%s' "$raw" | sed -n 's/^data: //p')"
  [ -n "$body" ] || body="$raw"
  printf '%s' "$body"
}

# Complete the MCP handshake. Sets MCP_SESSION.
mcp_handshake() {
  local url="http://127.0.0.1:${MCP_PORT}/mcp"
  local hdr="${BATS_TEST_TMPDIR:-/tmp}/mcp-init-headers.txt"
  local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"kagent-bats","version":"1"}}}'

  curl -sS --max-time 20 -D "$hdr" -o /dev/null -X POST \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    --data "$init" "$url" || {
    echo "MCP initialize failed against $url"
    return 1
  }

  MCP_SESSION="$(sed -n 's/^[Mm]cp-[Ss]ession-[Ii]d:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$hdr" | tr -d '\r' | head -1)"
  [ -n "$MCP_SESSION" ] || {
    echo "MCP initialize returned no mcp-session-id header; response headers were:"
    sed 's/^/  /' "$hdr"
    return 1
  }

  # Without this the server keeps the session in a pre-initialised state and
  # answers tools/list with HTTP 400.
  curl -sS --max-time 20 -X POST \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: ${MCP_SESSION}" \
    --data '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    "$url" >/dev/null 2>&1 || true
}

# Print the server's tool names, one per line, sorted. Fails loudly rather than
# printing nothing — see trap 3 in the header.
mcp_tools_list() {
  local url="http://127.0.0.1:${MCP_PORT}/mcp"
  local raw body names
  raw="$(curl -sS --max-time 30 -X POST \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: ${MCP_SESSION}" \
    --data '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}' \
    "$url")" || {
    echo "tools/list request failed"
    return 1
  }

  body="$(mcp_unframe "$raw")"

  local err
  err="$(printf '%s' "$body" | jq -r '.error.message // empty' 2>/dev/null || true)"
  [ -z "$err" ] || {
    echo "tools/list returned a JSON-RPC error: $err"
    return 1
  }

  names="$(printf '%s' "$body" | jq -r '.result.tools[]?.name' 2>/dev/null | sort -u)"
  [ -n "$names" ] || {
    echo "tools/list returned no tools."
    echo "This is reported as an error rather than as an empty set, because an"
    echo "empty set makes every 'is this tool present' check fail and so looks"
    echo "identical to a real wall of missing tools."
    echo "first 200 bytes of the reply:"
    printf '  %s\n' "$(printf '%s' "$raw" | head -c 200)"
    return 1
  }

  printf '%s\n' "$names"
}

# Connect to the kagent tool server: discover the Service by role, port-forward,
# and complete the handshake. Sets MCP_PORT / MCP_PF_PID / MCP_SESSION.
#
# CALL THIS DIRECTLY. NEVER INSIDE `$( )`.
# A command substitution runs in a subshell, so MCP_PF_PID would be set there
# and lost on return — leaving a port-forward that teardown cannot kill and bats
# will not exit while it lives. The first draft of this file combined connect
# and tools/list into one substitution-friendly helper and hung a suite for the
# full 10-minute timeout, having leaked a kubectl process still running 621s
# later. Split deliberately: connect mutates shell state and must run in the
# caller's shell; mcp_tools_list only reads, so it is safe to capture.
mcp_kagent_connect() {
  local ns="${1:-kagent}"
  local svcs svc port
  svcs="$(kubectl get svc -n "$ns" -o json)"
  # Exclude metrics/telemetry sidecar services, which also match "tool".
  svc="$(printf '%s' "$svcs" | jq -r '
      [ .items[]
        | select(.metadata.name | test("tool"; "i"))
        | select(.metadata.name | test("metric|telemetry"; "i") | not)
      ][0].metadata.name // empty')"
  [ -n "$svc" ] || {
    echo "no tool Service found in namespace ${ns}:"
    kubectl get svc -n "$ns"
    return 1
  }
  port="$(printf '%s' "$svcs" | jq -r --arg n "$svc" '
      .items[] | select(.metadata.name == $n) | .spec.ports[0].port')"

  mcp_pf_start "$ns" "$svc" "$port" || return 1
  mcp_handshake || return 1
}
