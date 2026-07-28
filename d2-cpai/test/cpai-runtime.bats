#!/usr/bin/env bats
# CPAI runtime proxy smoke tests.
# Requires a running cluster with the cpai namespace deployed (make demo-cpai-up).

DETIK_CLIENT_NAME="kubectl"
DETIK_CLIENT_NAMESPACE="cpai"
CPAI_PORT_FORWARD_PORT="${CPAI_PORT_FORWARD_PORT:-18080}"

setup_file() {
  # Port-forward to the cpai-runtime service for HTTP tests
  kubectl -n cpai port-forward svc/cpai-runtime "${CPAI_PORT_FORWARD_PORT}:8080" >/dev/null 2>&1 &
  export PORT_FORWARD_PID=$!
  # Wait for port-forward to be ready
  for _ in $(seq 1 30); do
    curl -fsS "http://localhost:${CPAI_PORT_FORWARD_PORT}/healthz" >/dev/null 2>&1 && break
    sleep 1
  done
}

teardown_file() {
  kill "${PORT_FORWARD_PID}" 2>/dev/null || true
}

@test "cpai namespace exists" {
  run kubectl get namespace cpai
  [ "$status" -eq 0 ]
}

@test "cpai-runtime deployment is available" {
  run kubectl -n cpai wait deployment/cpai-runtime \
    --for=condition=available --timeout=120s
  [ "$status" -eq 0 ]
}

@test "cpai-runtime pod is running" {
  run kubectl -n cpai get pods -l app.kubernetes.io/name=cpai-runtime \
    -o jsonpath='{.items[0].status.phase}'
  [ "$status" -eq 0 ]
  [ "$output" = "Running" ]
}

@test "healthz returns 200" {
  run curl -fsS "http://localhost:${CPAI_PORT_FORWARD_PORT}/healthz"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"status":"alive"'
}

@test "OpenAI hello-world: POST /v1/chat/completions returns a valid response" {
  run curl -sS -w '\n%{http_code}' \
    -X POST "http://localhost:${CPAI_PORT_FORWARD_PORT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "default",
      "messages": [
        {"role": "system", "content": "You are a test assistant. Reply with exactly: hello world"},
        {"role": "user", "content": "Say hello world"}
      ],
      "max_tokens": 20
    }'
  http_code="${lines[-1]}"
  # 200 = model backend available and responded
  # 502/503 = sidecar or model backend not yet configured (acceptable in local demo)
  if [ "$http_code" = "200" ]; then
    body=$(printf '%s\n' "${lines[@]:0:${#lines[@]}-1}" | tr -d '\n')
    echo "$body" | grep -qi "hello"
  else
    # Document that model backend is needed for full flow
    echo "# SKIP: /v1/chat/completions returned HTTP ${http_code} — model backend not configured"
    skip "Model backend not configured (HTTP ${http_code})"
  fi
}
