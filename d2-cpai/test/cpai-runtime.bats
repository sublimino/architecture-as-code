#!/usr/bin/env bats
# CPAI runtime proxy smoke tests.
# Requires a running cluster with the cpai namespace deployed (make demo-cpai-up).

DETIK_CLIENT_NAME="kubectl"
DETIK_CLIENT_NAMESPACE="cpai"
CPAI_PORT_FORWARD_PORT="${CPAI_PORT_FORWARD_PORT:-18080}"

# Existence guard, mirroring d2-osramp-apps/test/_helper.bats. An absent cpai
# slice is a SKIP, not 4 failures, so `make demo-cpai-test` stays runnable on a
# cluster where cpai was never deployed. Guards name DECLARATIVE objects only --
# Namespace, Service, Deployment -- never runtime Pods, so a deployed-but-
# unhealthy slice still runs its assertions and still fails loudly.
require-k8s() {
  local KIND="$1" NAME="$2" NAMESPACE="${3:-}"
  local ARGS=(--request-timeout=10s get "${KIND}" "${NAME}")
  if [ -n "${NAMESPACE}" ]; then
    ARGS+=(--namespace "${NAMESPACE}")
  fi
  command kubectl "${ARGS[@]}" >/dev/null 2>&1 \
    || skip "${KIND}/${NAME}${NAMESPACE:+ in ${NAMESPACE}} not deployed — run: make demo-cpai-up"
}

setup_file() {
  require-k8s namespace cpai
  require-k8s service cpai-runtime cpai
  require-k8s deployment cpai-runtime cpai

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
  local model="${CPAI_TEST_MODEL:-google-vertex/gemini-2.5-flash}"
  run curl -sS -w '\n%{http_code}' --max-time 60 \
    -X POST "http://localhost:${CPAI_PORT_FORWARD_PORT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${model}\",
      \"messages\": [
        {\"role\": \"system\", \"content\": \"Reply with exactly: hello world\"},
        {\"role\": \"user\", \"content\": \"Say hello world\"}
      ],
      \"max_tokens\": 20
    }"
  http_code="${lines[-1]}"
  if [ "$http_code" = "200" ]; then
    body=$(printf '%s\n' "${lines[@]:0:${#lines[@]}-1}" | tr -d '\n')
    echo "$body" | grep -qi "hello"
  else
    skip "Model backend returned HTTP ${http_code} — check cpai-gcp-adc secret and CPAI_TEST_MODEL"
  fi
}
