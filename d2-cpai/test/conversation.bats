#!/usr/bin/env bats
# CPAI runtime end-to-end conversation test.
#
# Verifies the CPAI runtime proxy handles a multi-turn conversation via aichat,
# proving the OpenAI-compatible API maintains context across turns.
#
# Prerequisites:
#   - Running cluster with cpai namespace deployed (make demo-cpai-up)
#   - cpai-gcp-adc secret created
#   - aichat installed

CPAI_PORT="${CPAI_PORT_FORWARD_PORT:-18080}"
SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"

setup_file() {
  export AICHAT_CONFIG_DIR
  AICHAT_CONFIG_DIR="$(mktemp -d)"

  export SESSION_NAME="cpai-e2e-$(date +%s)"

  local port="${CPAI_PORT}"
  sed "s|http://127.0.0.1:18080/v1|http://127.0.0.1:${port}/v1|" \
    "${SCRIPT_DIR}/aichat/config.yaml" > "${AICHAT_CONFIG_DIR}/config.yaml"
  mkdir -p "${AICHAT_CONFIG_DIR}/sessions"

  fuser -k "${port}/tcp" 2>/dev/null || true
  sleep 1

  kubectl -n cpai port-forward svc/cpai-runtime "${port}:8080" >/dev/null 2>&1 &
  export PORT_FORWARD_PID=$!

  for _ in $(seq 1 60); do
    curl -fsS "http://localhost:${port}/healthz" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS "http://localhost:${port}/healthz" >/dev/null 2>&1
}

teardown_file() {
  kill "${PORT_FORWARD_PID}" 2>/dev/null || true
  rm -rf "${AICHAT_CONFIG_DIR}"
}

@test "aichat can list the cpai-test model" {
  run aichat --list-models
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "cpai-test"
}

@test "turn 1: establish context — tell the model a secret number" {
  run aichat -S -s "${SESSION_NAME}" --save-session \
    "I am telling you a secret number. The secret number is 7742. Just acknowledge by saying OK and the number."
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "7742"
}

@test "turn 2: unrelated question — verify the model responds normally" {
  run aichat -S -s "${SESSION_NAME}" --save-session \
    "What is the capital of France? Answer in one word."
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "paris"
}

@test "turn 3: recall context — ask for the secret number" {
  run aichat -S -s "${SESSION_NAME}" --save-session \
    "What was the secret number I told you earlier? Reply with just the number."
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "7742"
}
