#!/usr/bin/env bats
# d2-signalloom/test/kagent-invoke-http.bats — invoke over real HTTP
#
# kagent-invoke.bats stubs the curl binary. That proves the script's logic and
# its URL construction, but a stub is not HTTP: it cannot show that the script
# actually speaks the protocol, handles real status codes, or survives a real
# socket. This file runs the unmodified script against a real server on a real
# port with real curl.
#
# What it still cannot prove is that kagent's controller behaves this way. The
# response shapes in the fixture are transcribed from upstream's own documented
# output, not invented — but the only thing that closes that last gap is an
# invocation against the real controller, which needs the upstream Helm chart.
# That step is named explicitly in the report rather than simulated here.
#
# Skips rather than fails when bun is absent: an environment without bun should
# not turn a green suite red, but it must also not silently claim a pass.

setup() {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/kagent-invoke.sh"
  SERVER="${BATS_TEST_DIRNAME}/fixtures/a2a-conformance-server.ts"
  [ -f "$SERVER" ]

  # A distinct port per test, so a leaked server from a previous test cannot
  # answer this one's requests and manufacture a pass.
  PORT=$(( 18200 + (RANDOM % 400) ))
  export KAGENT_A2A_BASE="http://127.0.0.1:${PORT}"

  STUB_DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_DIR"
  # Only kubectl is stubbed: the Agent CR precondition is not what this file
  # tests, and requiring a live cluster would make these tier 2.
  printf '#!/usr/bin/env bash\ncase " $* " in *"get agent"*) echo kagent-k8s-reader ;; esac\nexit 0\n' \
    >"${STUB_DIR}/kubectl"
  chmod +x "${STUB_DIR}/kubectl"
  export KUBECTL="${STUB_DIR}/kubectl"

  # These suites test the A2A client, not the credential precondition. Set here
  # rather than inherited from the caller's shell: a test that only passes
  # because of an exported variable is a test that passes on my machine.
  export KAGENT_SKIP_CREDENTIAL_CHECK=1

  SERVER_PID=""
}

teardown() {
  if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}

start_server() {
  A2A_SCENARIO="$1" A2A_PORT="$PORT" \
    bun "$SERVER" >"${BATS_TEST_TMPDIR}/server.log" 2>&1 &
  SERVER_PID=$!
  # Poll for the listener. A fixed sleep is either flaky or wasted, and it hides
  # the case where the server died on startup.
  for _ in $(seq 1 60); do
    if curl -sS -o /dev/null -m 1 "http://127.0.0.1:${PORT}/" 2>/dev/null; then return 0; fi
    kill -0 "$SERVER_PID" 2>/dev/null || {
      echo "server exited during startup:"; cat "${BATS_TEST_TMPDIR}/server.log"; return 1
    }
    sleep 0.1
  done
  echo "server never listened on ${PORT}"; cat "${BATS_TEST_TMPDIR}/server.log"; return 1
}

@test "kagent-invoke-http: real HTTP round trip returns the agent's text and exits zero" {
  start_server ok
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "how many namespaces exist"
  [ "$status" -eq 0 ]
  # The server echoes the prompt back, so this proves the prompt survived JSON
  # encoding, the wire, and decoding — not merely that some text was printed.
  [[ "$output" == *"ECHO:how many namespaces exist"* ]]
}

@test "kagent-invoke-http: a prompt containing quotes, newlines and backslashes survives the wire" {
  # The shape that breaks hand-rolled JSON string building. jq does the escaping
  # in the script; this is the test that would catch it if that ever changed.
  start_server ok
  run "$SCRIPT" --agent kagent-k8s-reader --prompt 'say "hi" \ and
then stop'
  [ "$status" -eq 0 ]
  [[ "$output" == *'say "hi" \ and'* ]]
}

@test "kagent-invoke-http: the server rejects a non-A2A envelope, so the envelope assertion is real" {
  # Guards the fixture itself. If the server answered any POST body, every test
  # above would pass even if the script sent something that is not A2A at all.
  start_server ok
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
            -H 'Content-Type: application/json' \
            -d '{"not":"an a2a envelope"}' \
            "http://127.0.0.1:${PORT}/api/a2a/fe-signalloom-agents/kagent-k8s-reader/")"
  [ "$code" = "200" ]
  body="$(curl -sS -X POST -H 'Content-Type: application/json' \
            -d '{"not":"an a2a envelope"}' \
            "http://127.0.0.1:${PORT}/api/a2a/fe-signalloom-agents/kagent-k8s-reader/")"
  [[ "$body" == *"invalid A2A envelope"* ]]
}

@test "kagent-invoke-http: text carried in status.message is found over real HTTP" {
  start_server status-message
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "hello"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ECHO:hello"* ]]
}

@test "kagent-invoke-http: a JSON-RPC error exits non-zero over real HTTP" {
  start_server rpc-error
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "hello"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid x-api-key"* ]]
}

@test "kagent-invoke-http: a failed task state exits non-zero over real HTTP" {
  start_server task-failed
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "hello"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed"* ]]
}

@test "kagent-invoke-http: a 200 carrying HTML exits non-zero over real HTTP" {
  start_server html-200
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "hello"
  [ "$status" -ne 0 ]
}

@test "kagent-invoke-http: an empty completed task exits non-zero over real HTTP" {
  start_server empty-completed
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "hello"
  [ "$status" -ne 0 ]
}

@test "kagent-invoke-http: a real 503 exits non-zero" {
  start_server http-503
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "hello"
  [ "$status" -ne 0 ]
  [[ "$output" == *"503"* ]]
}

@test "kagent-invoke-http: a missing agent card stops the run before invoking" {
  start_server no-card
  run "$SCRIPT" --agent kagent-k8s-reader --prompt "hello"
  [ "$status" -ne 0 ]
  [[ "$output" == *"404"* ]]
}
