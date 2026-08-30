#!/usr/bin/env bats
# d2-signalloom/test/kagent-invoke.bats — Human-triggered agent invocation (A2A)
#
# Before this script there was no way to invoke a kagent agent at all.
# `make demo-kagent-demo` is a sequence of `kubectl get`; kagent-harness-exec.sh
# writes a proof file. Both report on agents that have never run.
#
# The mechanism here is upstream's, not ours: every kagent agent implements A2A
# and the controller exposes it at /api/a2a/{namespace}/{agent}/ on port 8083,
# with the agent card at .well-known/agent.json under the same prefix. Nothing
# bespoke is invented.
#
# Tier 1: the HTTP boundary is injected via $CURL. The stub records argv, so URL
# construction and method are asserted for real, and replays a canned body, so
# every response shape — success, JSON-RPC error, failed task, malformed — is
# exercised deterministically. Tier 2 is the live run against a real controller,
# which cannot be done until the upstream chart lands.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/kagent-invoke.sh"

  STUB_DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_DIR"
  export CURL_ARGV_LOG="${BATS_TEST_TMPDIR}/curl.argv"
  export CURL_BODY_LOG="${BATS_TEST_TMPDIR}/curl.body"

  # Answers with whatever the test staged, and records what it was asked.
  # It honours -o so the script's real output-file contract is exercised.
  cat >"${STUB_DIR}/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_ARGV_LOG"
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  case "$a" in
    --data-binary@*|@*) f="${a#*@}"; [ -f "$f" ] && cat "$f" >>"$CURL_BODY_LOG" ;;
  esac
  prev="$a"
done
case " $* " in
  *".well-known/agent.json"*)
    [ -n "$out" ] && printf '%s' "${CURL_STUB_CARD:-{\"name\":\"kagent_k8s_reader\"\}}" >"$out"
    printf '%s' "${CURL_STUB_CARD_CODE:-200}" ;;
  *)
    [ -n "$out" ] && printf '%s' "${CURL_STUB_REPLY:-}" >"$out"
    printf '%s' "${CURL_STUB_REPLY_CODE:-200}" ;;
esac
exit 0
STUB
  chmod +x "${STUB_DIR}/curl"

  cat >"${STUB_DIR}/kubectl" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *"get agent"*) [ "${KUBECTL_STUB_AGENT_MISSING:-0}" = "1" ] && exit 1; echo "kagent-k8s-reader" ;;
  *) : ;;
esac
exit 0
STUB
  chmod +x "${STUB_DIR}/kubectl"

  export CURL="${STUB_DIR}/curl"
  export KUBECTL="${STUB_DIR}/kubectl"
  # Set, so no port-forward is attempted and the test never touches the network.
  export KAGENT_A2A_BASE="http://127.0.0.1:8083"

  OK_REPLY='{"jsonrpc":"2.0","id":"1","result":{"status":{"state":"completed"},"artifacts":[{"artifactId":"a1","parts":[{"kind":"text","text":"There are 21 namespaces in the cluster."}]}]}}'
}

@test "kagent-invoke: script exists and is executable" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
}

@test "kagent-invoke: refuses to run with no agent named" {
  run "$SCRIPT" --prompt "list namespaces"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--agent"* ]]
}

@test "kagent-invoke: refuses to run with no prompt" {
  run "$SCRIPT" --agent kagent-k8s-reader
  [ "$status" -ne 0 ]
  [[ "$output" == *"--prompt"* ]]
}

@test "kagent-invoke: refuses an agent that has no Agent CR in the cluster" {
  # Naming a non-existent agent must fail here, not as an opaque 404 from a URL
  # the operator has to decode.
  export KUBECTL_STUB_AGENT_MISSING=1
  export CURL_STUB_REPLY="$OK_REPLY"
  run "$SCRIPT" --agent kagent-nope --prompt "hello"
  [ "$status" -ne 0 ]
  [[ "$output" == *"kagent-nope"* ]]
}

# ─── URL construction, against the upstream documented shape ──────────────────

@test "kagent-invoke: fetches the agent card at the upstream .well-known path" {
  export CURL_STUB_REPLY="$OK_REPLY"
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "list namespaces"
  [ "$status" -eq 0 ]
  hit="$(grep -F 'http://127.0.0.1:8083/api/a2a/fe-signalloom-agents/kagent-k8s-reader/.well-known/agent.json' \
           "$CURL_ARGV_LOG" || true)"
  [ -n "$hit" ]
}

@test "kagent-invoke: posts to the upstream A2A agent endpoint" {
  export CURL_STUB_REPLY="$OK_REPLY"
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "list namespaces"
  [ "$status" -eq 0 ]
  hit="$(grep -F 'http://127.0.0.1:8083/api/a2a/fe-signalloom-agents/kagent-k8s-reader/' \
           "$CURL_ARGV_LOG" | grep -F 'POST' || true)"
  [ -n "$hit" ]
}

@test "kagent-invoke: sends an A2A message/send JSON-RPC envelope" {
  export CURL_STUB_REPLY="$OK_REPLY"
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "list namespaces"
  [ -f "$CURL_BODY_LOG" ]
  jsonrpc="$(grep -F '"jsonrpc"' "$CURL_BODY_LOG" || true)"
  method="$(grep -F '"message/send"' "$CURL_BODY_LOG" || true)"
  [ -n "$jsonrpc" ]
  [ -n "$method" ]
}

@test "kagent-invoke: carries the operator's prompt through to the request body" {
  export CURL_STUB_REPLY="$OK_REPLY"
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "how many namespaces exist"
  carried="$(grep -F 'how many namespaces exist' "$CURL_BODY_LOG" || true)"
  [ -n "$carried" ]
}

@test "kagent-invoke: the prompt travels by file, not argv" {
  # argv is world-readable in /proc and lands in shell history. A prompt is not
  # a credential, but the same body carries session identifiers, and a 128KiB
  # single-argument kernel cap makes argv the wrong transport regardless.
  export CURL_STUB_REPLY="$OK_REPLY"
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "how many namespaces exist"
  leaked="$(grep -F 'how many namespaces exist' "$CURL_ARGV_LOG" || true)"
  [ -z "$leaked" ]
}

# ─── Response handling: every shape, because they fail differently ────────────

@test "kagent-invoke: prints the agent's actual response text" {
  export CURL_STUB_REPLY="$OK_REPLY"
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "list namespaces"
  [ "$status" -eq 0 ]
  [[ "$output" == *"There are 21 namespaces in the cluster."* ]]
}

@test "kagent-invoke: reads response text from status.message when there are no artifacts" {
  # Both shapes appear in upstream's own documented output. Handling only the
  # artifacts one produces a silent empty success on the other.
  export CURL_STUB_REPLY='{"jsonrpc":"2.0","id":"1","result":{"status":{"state":"completed","message":{"role":"agent","parts":[{"kind":"text","text":"Twenty-one namespaces."}]}}}}'
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "list namespaces"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Twenty-one namespaces."* ]]
}

@test "kagent-invoke: exits non-zero on a JSON-RPC error object" {
  export CURL_STUB_REPLY='{"jsonrpc":"2.0","id":"1","error":{"code":-32603,"message":"model call failed: invalid x-api-key"}}'
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "list namespaces"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid x-api-key"* ]]
}

@test "kagent-invoke: exits non-zero when the task state is failed" {
  # The trap: HTTP 200, valid JSON-RPC, no error object, and the task failed.
  # Checking only .error reports this as success.
  export CURL_STUB_REPLY='{"jsonrpc":"2.0","id":"1","result":{"status":{"state":"failed","message":{"role":"agent","parts":[{"kind":"text","text":"authentication_error"}]}}}}'
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "list namespaces"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed"* ]]
}

@test "kagent-invoke: exits non-zero on a non-200 from the agent endpoint" {
  export CURL_STUB_REPLY_CODE="503"
  export CURL_STUB_REPLY='upstream connect error'
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "list namespaces"
  [ "$status" -ne 0 ]
  [[ "$output" == *"503"* ]]
}

@test "kagent-invoke: exits non-zero when the agent card is not served" {
  export CURL_STUB_CARD_CODE="404"
  export CURL_STUB_CARD='404 page not found'
  export CURL_STUB_REPLY="$OK_REPLY"
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "list namespaces"
  [ "$status" -ne 0 ]
  [[ "$output" == *"404"* ]] || [[ "$output" == *"agent card"* ]]
}

@test "kagent-invoke: exits non-zero on a 200 that is not JSON" {
  # A proxy error page returned with a 200 is the one that reads as success.
  export CURL_STUB_REPLY='<html><body>Gateway</body></html>'
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "list namespaces"
  [ "$status" -ne 0 ]
}

@test "kagent-invoke: exits non-zero on valid JSON carrying no response text" {
  # An empty completed task must not print nothing and exit 0. That is
  # indistinguishable from a working agent with nothing to say, and it is the
  # shape a half-wired controller produces.
  export CURL_STUB_REPLY='{"jsonrpc":"2.0","id":"1","result":{"status":{"state":"completed"}}}'
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "list namespaces"
  [ "$status" -ne 0 ]
}

# ─── Operator affordance ──────────────────────────────────────────────────────

@test "kagent-invoke: tells the operator where to watch the run" {
  export CURL_STUB_REPLY="$OK_REPLY"
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "list namespaces"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kagent-ui"* ]] || [[ "$output" == *"dashboard"* ]]
}

@test "kagent-invoke: --help exits zero and documents both required flags" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--agent"* ]]
  [[ "$output" == *"--prompt"* ]]
}
