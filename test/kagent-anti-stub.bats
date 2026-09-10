#!/usr/bin/env bats
# test/kagent-anti-stub.bats — Anti-stub regression gate for the Kagent control plane.
#
# WHY THIS FILE EXISTS
# --------------------
# At commit f879ec4c the Kagent "control plane" was three placeholder workloads:
#   * kagent-controller   — python:3.12-alpine sleeping in a loop, readiness `echo ready`
#   * kagent-tool-server  — python:3.12-alpine whose do_POST returns ONE hardcoded
#                           literal for every request, whatever tool was named
#   * kagent-ui           — nginx:1.27-alpine serving a static index.html
# and all 36 Kagent assertions were green against it. Green tests over a fake
# stack are worse than no tests: they license the claim that the thing works.
#
# Every assertion below is chosen so that it FAILS against those placeholders
# and PASSES against the real upstream charts. If one of these ever passes on a
# stub, it has stopped doing its job.
#
# DESIGN RULES OBSERVED HERE
#   * No `! cmd` assertions — under errexit a bare `!` can never fail the test.
#     Offenders are collected into a variable and asserted empty.
#   * No `cmd | grep -q` — grep -q closes the pipe on first match, which can
#     hand the producer SIGPIPE and return 141 PRECISELY WHEN IT MATCHES.
#     Everything is read into a variable first and matched with bash builtins.
#   * Every scan asserts it actually scanned something, so an empty glob or a
#     renamed namespace cannot pass as "no offenders found".
#   * There is a layer below this suite that it cannot reach. Every assertion
#     here is about the tool layer — images, reconciliation, tool existence,
#     discrimination. An agent can pass all of it and still be wrong: an
#     invocation of kagent-incident-responder returned CORRECT tool data with
#     WRONG ARITHMETIC OVER IT, reporting "16 pods in Error state" directly
#     above a correct list of 18. Nothing mechanical can catch that, and this
#     suite does not try. It is recorded because it completes the family:
#     chaos-prober green with fictional tools, apiKeySecret silently pruned on
#     apply, and a confident summary over correct data — three failures that
#     differ only in which layer went quiet.
#   * Positive markers are preferred over absence-of-error. A component that
#     logged nothing at all also logged no errors; the stub controller even
#     prints "Reconciling Agent CRDs..." to stdout, so log greps are worthless
#     here by construction. Cluster state is asserted instead.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.kind/kubeconfig}"
  if [ -f "${KUBECONFIG_PATH}" ]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
  fi
  KAGENT_NS="${KAGENT_NS:-kagent}"
  AGENTS_NS="${AGENTS_NS:-fe-signalloom-agents}"

  # A self-sentinel used by the manifest-scan test to PROVE that the scan roots
  # cannot see this test file. The literal below must appear nowhere except in
  # this file. See "no kagent manifest hardcodes a mock model API key".
  SELF_SENTINEL="KAGENT_ANTI_STUB_SELF_SENTINEL_7f21c"
}

teardown() {
  if [ -n "${PF_PID:-}" ]; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
}

# ── helpers ──────────────────────────────────────────────────────────────────

# Fail loudly rather than skip. A skipped live test is indistinguishable from a
# passing one in a summary line, which is the exact failure mode this file is
# here to prevent.
require_cluster() {
  if ! kubectl get namespace "${KAGENT_NS}" >/dev/null 2>&1; then
    echo "no reachable cluster, or namespace '${KAGENT_NS}' is absent"
    echo "KUBECONFIG=${KUBECONFIG:-<unset>}"
    echo "this suite asserts live control-plane behaviour and must not be skipped"
    return 1
  fi
}

# Main-container images running in a namespace, one per line.
#
# initContainers are deliberately excluded: a legitimate chart may use a stock
# busybox to wait on a dependency, and flagging that would produce a false red
# against the real stack. The stub's placeholders are all main containers, which
# is the population these assertions are about.
images_in_ns() {
  kubectl get pods -n "$1" -o json |
    jq -r '.items[] | select(.metadata.deletionTimestamp == null) | select((.metadata.name // "") | startswith("npcheck-") | not) | .spec.containers[].image'
}

# Strip a tag or digest, and normalise docker.io/library/foo -> foo.
image_repo() {
  local img="$1" repo
  repo="${img%%@*}"
  # only strip a tag if the last colon is not part of a registry:port
  case "${repo##*/}" in
    *:*) repo="${repo%:*}" ;;
  esac
  repo="${repo#docker.io/library/}"
  repo="${repo#docker.io/}"
  repo="${repo#index.docker.io/library/}"
  printf '%s' "$repo"
}

# Discover the MCP tool service by role rather than by name, so an upstream
# chart that renames kagent-tool-server -> kagent-tools still resolves.
# Prints "<name> <port>". Empty output means "not found", which callers treat
# as a failure — never as a pass.
find_tool_service() {
  local svcs
  svcs="$(kubectl get svc -n "${KAGENT_NS}" -o json)"
  local name
  name="$(printf '%s' "$svcs" | jq -r '
      [ .items[] | select(.metadata.name | test("tool"; "i")) ][0].metadata.name // empty')"
  if [ -z "$name" ]; then
    name="$(printf '%s' "$svcs" | jq -r '
        [ .items[] | select(.metadata.name | test("mcp"; "i")) ][0].metadata.name // empty')"
  fi
  [ -n "$name" ] || return 0
  local port
  port="$(printf '%s' "$svcs" | jq -r --arg n "$name" '
      .items[] | select(.metadata.name == $n) | .spec.ports[0].port')"
  printf '%s %s' "$name" "$port"
}

# Start a port-forward and set PF_PORT / PF_PID. teardown() kills it.
pf_start() {
  local svc="$1" port="$2"
  local log="${BATS_TEST_TMPDIR}/pf-${svc}.log"
  : >"$log"
  kubectl port-forward -n "${KAGENT_NS}" "svc/${svc}" ":${port}" >"$log" 2>&1 &
  PF_PID=$!
  local i
  PF_PORT=""
  for i in $(seq 1 60); do
    PF_PORT="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$log" | head -1)"
    [ -n "$PF_PORT" ] && break
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      echo "port-forward to svc/${svc}:${port} died:"
      cat "$log"
      return 1
    fi
    sleep 0.25
  done
  if [ -z "$PF_PORT" ]; then
    echo "port-forward to svc/${svc}:${port} never reported a local port:"
    cat "$log"
    return 1
  fi
}

# POST a JSON body and print "<http_status>\x1e<response body>". Failures of
# curl itself are rendered as a distinct string so they can never be mistaken
# for a successful-but-identical response.
mcp_post() {
  local body="$1"
  local args=(-sS --max-time 20 -X POST
    -H 'Content-Type: application/json'
    -H 'Accept: application/json, text/event-stream'
    --data "$body"
    -w '\n__STATUS__%{http_code}')
  if [ -n "${MCP_SESSION:-}" ]; then
    args+=(-H "Mcp-Session-Id: ${MCP_SESSION}")
  fi
  local raw status payload
  if ! raw="$(curl "${args[@]}" "http://127.0.0.1:${PF_PORT}${MCP_PATH}" 2>&1)"; then
    printf 'CURL_FAILED\x1e%s' "$raw"
    return 0
  fi
  status="${raw##*__STATUS__}"
  payload="${raw%$'\n'__STATUS__*}"
  printf '%s\x1e%s' "$status" "$payload"
}

# Bring up a port-forward to the tool server and perform an MCP initialize
# handshake if the server offers one. Sets PF_PORT, MCP_PATH, MCP_SESSION.
tool_server_connect() {
  local svc port
  read -r svc port <<<"$(find_tool_service)"
  if [ -z "${svc:-}" ]; then
    echo "no tool/mcp Service found in namespace ${KAGENT_NS}:"
    kubectl get svc -n "${KAGENT_NS}"
    return 1
  fi
  echo "# tool service: ${svc}:${port}" >&3 2>/dev/null || true
  pf_start "$svc" "$port" || return 1

  MCP_SESSION=""
  MCP_PATH="/mcp"
  local hdr="${BATS_TEST_TMPDIR}/init-headers.txt"
  local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"kagent-anti-stub","version":"1"}}}'
  curl -sS --max-time 20 -X POST -D "$hdr" -o /dev/null \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    --data "$init" \
    "http://127.0.0.1:${PF_PORT}${MCP_PATH}" >/dev/null 2>&1 || true
  if [ -f "$hdr" ]; then
    local sid
    sid="$(sed -n 's/^[Mm]cp-[Ss]ession-[Ii]d:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$hdr" | head -1)"
    MCP_SESSION="${sid}"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
# 1. Images: the control plane must be the real thing, not a base image
# ═════════════════════════════════════════════════════════════════════════════

@test "kagent-anti-stub: no kagent workload runs a generic public base image" {
  require_cluster

  local imgs
  imgs="$(images_in_ns "${KAGENT_NS}")"
  [ -n "$imgs" ] || {
    echo "no pods found in namespace ${KAGENT_NS} — nothing was inspected"
    return 1
  }

  # Bare official images. A real Kagent component is never one of these; a
  # stub always is. postgres is deliberately absent: the upstream chart also
  # ships a stock postgres as its state store, so it is not evidence of a stub.
  local offenders=""
  local img repo
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    repo="$(image_repo "$img")"
    case "$repo" in
      python | nginx | busybox | alpine | debian | ubuntu | httpd | node | golang)
        offenders+="${img}"$'\n'
        ;;
    esac
  done <<<"$imgs"

  if [ -n "$offenders" ]; then
    echo "kagent workloads are running placeholder base images:"
    printf '%s' "$offenders"
    echo "a base image cannot implement a controller, an MCP tool server or a UI"
    echo "all images seen in ${KAGENT_NS}:"
    printf '%s\n' "$imgs"
  fi
  [ -z "$offenders" ]
}

@test "kagent-anti-stub: kagent control-plane images are published by the kagent project" {
  require_cluster

  local imgs
  imgs="$(images_in_ns "${KAGENT_NS}")"
  [ -n "$imgs" ] || {
    echo "no pods found in namespace ${KAGENT_NS} — nothing was inspected"
    return 1
  }

  # Positive provenance marker. The real controller, UI and tools images are all
  # published under a kagent-owned path (cr.kagent.dev/kagent-dev/... and
  # ghcr.io/kagent-dev/...). Two is the floor: controller + UI.
  local kagent_images="" img
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    case "$img" in
      *kagent*) kagent_images+="${img}"$'\n' ;;
    esac
  done <<<"$imgs"

  local n
  n="$(printf '%s' "$kagent_images" | grep -c . || true)"
  if [ "${n:-0}" -lt 2 ]; then
    echo "expected >=2 kagent-published images in ${KAGENT_NS}, found ${n:-0}"
    echo "images present:"
    printf '%s\n' "$imgs"
  fi
  [ "${n:-0}" -ge 2 ]
}

@test "kagent-anti-stub: no kagent container is an inline interpreter script" {
  require_cluster

  local specs
  specs="$(kubectl get deploy,statefulset,daemonset -n "${KAGENT_NS}" -o json)"
  local n_workloads
  n_workloads="$(printf '%s' "$specs" | jq '.items | length')"
  [ "${n_workloads:-0}" -gt 0 ] || {
    echo "no workloads found in ${KAGENT_NS} — nothing was inspected"
    return 1
  }

  # A stub is delivered as `command: [python3, -c, "<the whole server>"]`.
  # Real images ship an entrypoint; they do not carry their implementation in
  # the manifest. Flag any container whose command starts an interpreter with
  # an inline program.
  local offenders
  offenders="$(printf '%s' "$specs" | jq -r '
    .items[] as $w
    | $w.spec.template.spec.containers[]
    | select((.command // []) | length > 0)
    | . as $c
    | ($c.command | join(" ")) as $cmd
    | select($cmd | test("(python[0-9.]*|node|ruby|perl|sh|bash)[[:space:]]+(-c|-e)\\b"))
    | "\($w.kind)/\($w.metadata.name) container=\($c.name) command=\($cmd[0:80])"')"

  if [ -n "$offenders" ]; then
    echo "kagent workloads carry their implementation inline in the manifest:"
    printf '%s\n' "$offenders"
    echo "(inspected ${n_workloads} workloads in ${KAGENT_NS})"
  fi
  [ -z "$offenders" ]
}

@test "kagent-anti-stub: no kagent readiness probe is a shell echo" {
  require_cluster

  local specs
  specs="$(kubectl get deploy,statefulset,daemonset -n "${KAGENT_NS}" -o json)"
  local n_workloads
  n_workloads="$(printf '%s' "$specs" | jq '.items | length')"
  [ "${n_workloads:-0}" -gt 0 ] || {
    echo "no workloads found in ${KAGENT_NS} — nothing was inspected"
    return 1
  }

  # `readinessProbe: exec: [sh, -c, "echo ready"]` reports Ready for a process
  # that has never served a request. It is the single assertion that let a
  # sleeping container satisfy every rollout gate in this repo.
  local offenders
  offenders="$(printf '%s' "$specs" | jq -r '
    .items[] as $w
    | $w.spec.template.spec.containers[]
    | select(.readinessProbe.exec != null)
    | . as $c
    | ($c.readinessProbe.exec.command | join(" ")) as $probe
    | select($probe | test("\\becho\\b|\\btrue\\b|^/bin/true"))
    | "\($w.kind)/\($w.metadata.name) container=\($c.name) probe=\($probe)"')"

  if [ -n "$offenders" ]; then
    echo "readiness is being faked by a shell builtin:"
    printf '%s\n' "$offenders"
    echo "(inspected ${n_workloads} workloads in ${KAGENT_NS})"
  fi
  [ -z "$offenders" ]
}

# ═════════════════════════════════════════════════════════════════════════════
# 2. The tool server must discriminate its input
#
# This is the highest-value assertion in the repository. The stub's do_POST
# ignored the request body entirely and wrote one literal, so a call naming
# `k8s_get_resources` and a call naming a tool that has never existed came back
# byte-identical. Nothing else in the suite could tell those two apart.
# ═════════════════════════════════════════════════════════════════════════════

@test "kagent-anti-stub: tool server returns different responses for different tool names" {
  require_cluster
  tool_server_connect

  local real_tool='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"k8s_get_resources","arguments":{"resource_type":"pods"}}}'
  local fake_tool='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"totally_made_up_xyz_9f3a","arguments":{}}}'

  local r_real r_fake
  r_real="$(mcp_post "$real_tool")"
  r_fake="$(mcp_post "$fake_tool")"

  if [ "$r_real" = "$r_fake" ]; then
    echo "the tool server does not read the tool name it is given."
    echo "a call to 'k8s_get_resources' and a call to 'totally_made_up_xyz_9f3a'"
    echo "produced a byte-identical status+body:"
    printf '  %s\n' "${r_real//$'\x1e'/ | body: }"
    echo "this is the defining behaviour of a hardcoded stub: whatever you ask,"
    echo "you get the same answer, and every downstream test still passes."
  fi
  [ "$r_real" != "$r_fake" ]
}

@test "kagent-anti-stub: tool server responses are not one hardcoded literal" {
  require_cluster
  tool_server_connect

  # Three probes that differ in method as well as in arguments. Any server that
  # actually parses JSON-RPC must distinguish at least two of them; a server
  # that returns a constant cannot distinguish any.
  local p1='{"jsonrpc":"2.0","id":10,"method":"tools/list","params":{}}'
  local p2='{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"k8s_get_resources","arguments":{}}}'
  local p3='{"jsonrpc":"2.0","id":12,"method":"nonexistent/method","params":{}}'

  local a b c
  a="$(mcp_post "$p1")"
  b="$(mcp_post "$p2")"
  c="$(mcp_post "$p3")"

  local distinct
  distinct="$(printf '%s\n%s\n%s\n' "$a" "$b" "$c" | sort -u | grep -c . || true)"

  if [ "${distinct:-0}" -lt 2 ]; then
    echo "three structurally different MCP requests produced ${distinct} distinct response(s)."
    echo "tools/list, a tools/call and an unknown method are indistinguishable to this server."
    printf '  tools/list      -> %s\n' "${a//$'\x1e'/ | }"
    printf '  tools/call      -> %s\n' "${b//$'\x1e'/ | }"
    printf '  unknown method  -> %s\n' "${c//$'\x1e'/ | }"
  fi
  [ "${distinct:-0}" -ge 2 ]
}

@test "kagent-anti-stub: tool server names its tools in a tools/list response" {
  require_cluster
  tool_server_connect

  local resp body
  resp="$(mcp_post '{"jsonrpc":"2.0","id":20,"method":"tools/list","params":{}}')"
  body="${resp#*$'\x1e'}"

  # Positive marker: a real MCP server enumerates named tools. The stub's POST
  # handler returns {"result": {"resources": [...], "count": 3}} — a payload
  # with no tool name anywhere in it, for every request it ever receives.
  local has_name=0
  case "$body" in
    *'"name"'*) has_name=1 ;;
  esac
  local has_tools=0
  case "$body" in
    *'"tools"'*) has_tools=1 ;;
  esac

  if [ "$has_name" -ne 1 ] || [ "$has_tools" -ne 1 ]; then
    echo "tools/list did not return a named tool list."
    echo "status+body: ${resp//$'\x1e'/ | }"
    echo "expected a JSON-RPC result containing a \"tools\" array of objects with \"name\""
  fi
  [ "$has_name" -eq 1 ]
  [ "$has_tools" -eq 1 ]
}

# ═════════════════════════════════════════════════════════════════════════════
# 3. The UI must be the Kagent UI, not a hand-written placeholder
# ═════════════════════════════════════════════════════════════════════════════

@test "kagent-anti-stub: UI is an application, not a static nginx page" {
  require_cluster

  local svc port
  svc="$(kubectl get svc -n "${KAGENT_NS}" -o json |
    jq -r '[ .items[] | select(.metadata.name | test("ui|dashboard"; "i")) ][0].metadata.name // empty')"
  [ -n "$svc" ] || {
    echo "no UI Service found in ${KAGENT_NS}:"
    kubectl get svc -n "${KAGENT_NS}"
    return 1
  }
  port="$(kubectl get svc -n "${KAGENT_NS}" "$svc" -o jsonpath='{.spec.ports[0].port}')"
  pf_start "$svc" "$port"

  local hdr="${BATS_TEST_TMPDIR}/ui-headers.txt"
  local body
  body="$(curl -sSL --max-time 20 -D "$hdr" "http://127.0.0.1:${PF_PORT}/" 2>&1 || true)"

  local server_hdr
  server_hdr="$(sed -n 's/^[Ss]erver:[[:space:]]*\(.*\)/\1/p' "$hdr" | tr -d '\r' | head -1)"

  # NOT a Server-header check. An earlier revision of this test asserted
  # `Server:` was not nginx, which failed against the REAL kagent UI 0.9.9 —
  # it serves its built bundle through nginx (Server: nginx/1.31.1) and is a
  # perfectly real application. "nginx is present" and "nothing was built" are
  # different claims; only the second one matters here. Assert the payload.
  #
  # Measured: the placeholder served 496 bytes with zero <script> tags; the
  # real UI serves ~15.9 KB with script tags. The two properties together
  # separate them without depending on how the bytes are fronted.
  local has_script=0
  case "$body" in
    *'<script'*) has_script=1 ;;
  esac

  if [ "$has_script" -ne 1 ] || [ "${#body}" -lt 2000 ]; then
    echo "the Kagent UI endpoint is not serving an application."
    echo "  Server header    : ${server_hdr:-<none>}"
    echo "  body bytes       : ${#body} (expected >= 2000)"
    echo "  contains <script : ${has_script} (expected 1)"
    echo "a hand-written index.html satisfies every deployment-readiness"
    echo "assertion in this repo while shipping no product."
  fi
  [ "$has_script" -eq 1 ]
  [ "${#body}" -ge 2000 ]
}

# ═════════════════════════════════════════════════════════════════════════════
# 4. The controller must actually reconcile
#
# `kubectl get deployment kagent-controller` being Ready proves a process is
# alive, not that it does anything. A controller is defined by the writes it
# makes. These assert the writes.
# ═════════════════════════════════════════════════════════════════════════════

@test "kagent-anti-stub: every Agent CR has been reconciled to a non-null status" {
  require_cluster

  local agents
  agents="$(kubectl get agents -n "${AGENTS_NS}" -o json)"
  local total
  total="$(printf '%s' "$agents" | jq '.items | length')"
  [ "${total:-0}" -gt 0 ] || {
    echo "no Agent CRs found in ${AGENTS_NS} — nothing was inspected"
    return 1
  }

  local unreconciled
  unreconciled="$(printf '%s' "$agents" | jq -r '
    .items[] | select(.status == null or (.status | length) == 0) | .metadata.name')"

  if [ -n "$unreconciled" ]; then
    echo "${total} Agent CRs exist; these have never been written to by a controller:"
    printf '  %s\n' $unreconciled
    echo "an Agent CR with status: null has been accepted by the API server and"
    echo "then ignored. Applying YAML is not the same as running an agent."
  fi
  [ -z "$unreconciled" ]
}

@test "kagent-anti-stub: Agent CR status carries a typed condition" {
  require_cluster

  local agents
  agents="$(kubectl get agents -n "${AGENTS_NS}" -o json)"
  local total
  total="$(printf '%s' "$agents" | jq '.items | length')"
  [ "${total:-0}" -gt 0 ] || {
    echo "no Agent CRs found in ${AGENTS_NS} — nothing was inspected"
    return 1
  }

  # Positive marker with a name attached: a condition type such as Accepted or
  # Ready. `status: {}` would satisfy a bare non-null check; this will not.
  local with_conditions
  with_conditions="$(printf '%s' "$agents" | jq -r '
    [ .items[]
      | select((.status.conditions // []) | map(select((.type // "") != "")) | length > 0)
    ] | length')"

  if [ "${with_conditions:-0}" -lt "$total" ]; then
    echo "only ${with_conditions:-0} of ${total} Agent CRs report a typed status condition"
    printf '%s' "$agents" | jq -r '.items[] | "  \(.metadata.name): conditions=\((.status.conditions // []) | length)"'
  fi
  [ "${with_conditions:-0}" -eq "$total" ]
}

@test "kagent-anti-stub: the controller owns resources it created for the Agent CRs" {
  require_cluster

  # Reconciliation is observable as ownership: the controller materialises each
  # Agent CR into workloads it stamps with an ownerReference back to the CR.
  # Nothing in the namespace carried such a reference under the stub.
  local owned
  owned="$(kubectl get deploy,statefulset,service,configmap -n "${AGENTS_NS}" -o json |
    jq -r '.items[]
           | select((.metadata.ownerReferences // []) | map(.kind) | index("Agent"))
           | "\(.kind)/\(.metadata.name) <- Agent/\((.metadata.ownerReferences[] | select(.kind == "Agent") | .name))"')"

  if [ -z "$owned" ]; then
    echo "no resource in ${AGENTS_NS} is owned by an Agent CR."
    echo "the Agent CRs present are:"
    kubectl get agents -n "${AGENTS_NS}" --no-headers 2>&1 | sed 's/^/  /'
    echo "a controller that reconciles produces resources; this one produced none."
  fi
  [ -n "$owned" ]
}

# ═════════════════════════════════════════════════════════════════════════════
# 5. Credentials must be real
#
# Owned here as a *test*; the wiring that satisfies it is owned by the
# credentials work. The mock literal is what makes agent execution impossible,
# so a suite that does not assert against it cannot claim the agents run.
# ═════════════════════════════════════════════════════════════════════════════

@test "kagent-anti-stub: the model API key secret is not a demo placeholder" {
  require_cluster

  local secret_json
  secret_json="$(kubectl get secret -n "${KAGENT_NS}" -o json |
    jq -r '[ .items[] | select(.metadata.name | test("anthropic|openai|model|llm"; "i")) ][0] // empty')"
  [ -n "$secret_json" ] || {
    echo "no model-provider API key Secret found in ${KAGENT_NS}:"
    kubectl get secret -n "${KAGENT_NS}"
    echo "the agents cannot call a model without one"
    return 1
  }

  local name keys
  name="$(printf '%s' "$secret_json" | jq -r '.metadata.name')"
  keys="$(printf '%s' "$secret_json" | jq -r '.data | keys[]')"
  [ -n "$keys" ] || {
    echo "Secret ${name} has no data keys"
    return 1
  }

  # EVERY key, not the first one. An earlier revision read
  # `.data | to_entries[0].value` and passed on this cluster while the
  # credential in use was still the mock: the Secret had grown a second key,
  # jq sorts keys, and ANTHROPIC_API_KEY (real, 53 chars) sorted ahead of
  # api-key (the 33-char placeholder that d2-signalloom/infra/agent-swarm/
  # kagent-k8s-reader/modelconfig.yaml actually names via apiKeySecret).
  # The assertion was true — of the wrong key.
  local offenders="" checked=0
  local k value lower
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    checked=$((checked + 1))
    value="$(printf '%s' "$secret_json" | jq -r --arg k "$k" '.data[$k]' | base64 -d 2>/dev/null || true)"

    if [ -z "$value" ] || [ "${#value}" -lt 20 ]; then
      offenders+="${k} (length ${#value}, expected >= 20)"$'\n'
      continue
    fi
    lower="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
      *mock* | *placeholder* | *dummy* | *fake* | *changeme* | *example* | *for-local-demo*)
        # Never echo the value; report the key and the shape only.
        offenders+="${k} (length ${#value}, matched a placeholder marker)"$'\n'
        ;;
    esac
  done <<<"$keys"

  [ "$checked" -gt 0 ]

  if [ -n "$offenders" ]; then
    echo "Secret ${name} holds placeholders, not usable credentials (checked ${checked} keys):"
    printf '  %s' "$offenders"
    echo "no agent can complete a model call with these, so every 'agent is"
    echo "deployed' assertion in this repo is about YAML, not behaviour."
  fi
  [ -z "$offenders" ]
}

@test "kagent-anti-stub: no kagent manifest hardcodes a mock model API key" {
  local roots=(
    "${REPO_ROOT}/d2-signalloom/infra/kagent"
    "${REPO_ROOT}/d2-signalloom/infra/agent-swarm"
  )
  for r in "${roots[@]}"; do
    [ -d "$r" ] || {
      echo "scan root missing: $r"
      return 1
    }
  done

  # Prove the scan actually reads files. An empty or mis-rooted glob would
  # otherwise report "no offenders" and pass forever.
  local scanned
  scanned="$(find "${roots[@]}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) | wc -l)"
  [ "${scanned:-0}" -gt 0 ] || {
    echo "scan roots contain no manifests — the scan is vacuous"
    return 1
  }

  # PROOF OF SELF-EXCLUSION. This test file contains both the forbidden literal
  # below and $SELF_SENTINEL. If the scan roots could see this file, the
  # sentinel search would find it. That the sentinel search comes back empty is
  # a positive demonstration that the guard is not matching its own source —
  # and it keeps demonstrating it if the tests are ever relocated.
  local self_hit
  self_hit="$(grep -rl -- "${SELF_SENTINEL}" "${roots[@]}" 2>/dev/null || true)"
  [ -z "$self_hit" ] || {
    echo "the scan roots now contain this test file (sentinel found in): $self_hit"
    echo "the guard would match its own source and can no longer be trusted"
    return 1
  }
  # And the sentinel must genuinely exist in this file, or the proof above is
  # satisfied by a typo rather than by exclusion: an empty result from grepping
  # for a string that exists nowhere proves nothing about the scan roots.
  local sentinel_here
  sentinel_here="$(grep -c -- "${SELF_SENTINEL}" "$BATS_TEST_FILENAME" || true)"
  [ "${sentinel_here:-0}" -ge 1 ]

  # COMMENT LINES ARE EXCLUDED. A guard that greps for a forbidden token also
  # matches the comment explaining why the token is gone — so the moment someone
  # removes the literal and writes "# was mock-anthropic-key-…, now sourced from
  # OpenBao", this test keeps failing and reports the defect it was just told had
  # been fixed. The guard would then be the only thing standing between the repo
  # and a green run, and the obvious way to make it pass is to delete the
  # comment, which loses the explanation. Strip whole-line comments first.
  #
  # Deliberately only whole-line comments: a trailing `# …` after a real value
  # must NOT rescue a line that still assigns the placeholder.
  local hits
  hits="$(grep -rn -- 'mock-anthropic-key\|mock-openai-key\|mock-api-key' "${roots[@]}" 2>/dev/null |
    grep -v -E '^[^:]*:[0-9]+:[[:space:]]*#' || true)"

  if [ -n "$hits" ]; then
    echo "manifests ship a hardcoded placeholder model key (scanned ${scanned} files):"
    printf '%s\n' "$hits"
    echo "(whole-line comments are excluded, so this is a real assignment)"
  fi
  [ -z "$hits" ]
}
