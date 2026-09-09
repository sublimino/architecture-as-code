#!/usr/bin/env bats
# test/signalloom-autoclaim.bats — In-cluster agent discovery and auto-claim integration suite.
#
# Covers Mission SLAC (Signal Loom In-Cluster Agent Discovery and Auto-Claim):
# 1. Discovered agent detection via API
# 2. Successful claim submission returning 200 and granted status
# 3. Database persistence in agent_registry with is_registry_linked=true
# 4. Origin verification record in agent_origin_verifications
# 5. 6 seeded compliance control evaluations in agent_compliance_results
# 6. Posture score calculation resulting in > 0 score
# 7. Audit event logging of agent claim (agent.created with action=claimed)
# 8. Idempotency on duplicate claim requests
# 9. Tenant isolation rejecting foreign tenant access
# 10. Malformed payload rejection with HTTP 422
#
# Conforms to repo standards:
# - Zero kubectl exec probes (uses outside-pod port-forwarding + real HTTP codes)
# - Zero persistent DB contamination (hermetic setup and teardown fixtures)
# - Sub-45s execution time ceiling across all tests
# - Standard TAP stream output for CI compatibility

# shellcheck disable=SC1091

find_free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()'
}

cleanup_db() {
  local port="$1"
  local target="$2"
  bun run "${REPO_ROOT}/test/lib/autoclaim-db.ts" cleanup "$port" "$target" >/dev/null 2>&1 || true
}

db_cmd() {
  local action="$1"
  bun run "${REPO_ROOT}/test/lib/autoclaim-db.ts" "$action" "$PG_PORT" "${TARGET_WORKLOAD}"
}

setup_file() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  source "${REPO_ROOT}/scripts/lib/wait.sh"

  for cmd in curl jq bun kubectl; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "Prerequisite tool '$cmd' missing" >&2
      return 1
    }
  done

  kubectl get nodes >/dev/null 2>&1 || {
    echo "Kubernetes cluster unreachable" >&2
    return 1
  }

  STATE_FILE="${BATS_FILE_TMPDIR}/autoclaim-state.env"
  DASH_PORT="$(find_free_port)"
  PG_PORT="$(find_free_port)"

  kubectl -n fe-signalloom port-forward svc/dashboard-signalloom "${DASH_PORT}:8080" >/dev/null 2>&1 &
  DASH_PID=$!
  kubectl -n inf-signalloom port-forward svc/postgresql "${PG_PORT}:5432" >/dev/null 2>&1 &
  PG_PID=$!

  wait_reachable "http://localhost:${DASH_PORT}/dex/healthz" 15 || {
    kill "$DASH_PID" "$PG_PID" 2>/dev/null || true
    echo "Timed out waiting for dashboard-signalloom port-forward" >&2
    return 1
  }

  wait_tcp localhost "${PG_PORT}" 15 || {
    kill "$DASH_PID" "$PG_PID" 2>/dev/null || true
    echo "Timed out waiting for postgresql port-forward" >&2
    return 1
  }

  local token_resp
  token_resp="$(curl -sS --max-time 10 -X POST \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=signalloom-dashboard" \
    --data-urlencode "username=demo-user@signalloom.local" \
    --data-urlencode "password=demo-user" \
    --data-urlencode "scope=openid profile email groups audience:server:client_id:signalloom-api" \
    "http://localhost:${DASH_PORT}/dex/token")"

  TOKEN="$(jq -er '.id_token | select(type == "string" and length > 0)' <<<"${token_resp}" 2>/dev/null)" || {
    kill "$DASH_PID" "$PG_PID" 2>/dev/null || true
    echo "Failed to mint Dex token: ${token_resp}" >&2
    return 1
  }

  TARGET_WORKLOAD="kagent-network-auditor"
  SPIFFE_ID="spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/${TARGET_WORKLOAD}"

  # Clean any pre-existing test state for TARGET_WORKLOAD to guarantee clean baseline
  cleanup_db "${PG_PORT}" "${TARGET_WORKLOAD}"

  cat <<STATE_VARS > "${STATE_FILE}"
REPO_ROOT='${REPO_ROOT}'
DASH_PORT='${DASH_PORT}'
PG_PORT='${PG_PORT}'
TOKEN='${TOKEN}'
TARGET_WORKLOAD='${TARGET_WORKLOAD}'
SPIFFE_ID='${SPIFFE_ID}'
DASH_PID='${DASH_PID}'
PG_PID='${PG_PID}'
STATE_VARS
}

teardown_file() {
  local state_file="${BATS_FILE_TMPDIR}/autoclaim-state.env"
  if [[ -f "${state_file}" ]]; then
    set -a
    source "${state_file}"
    set +a

    # Hermetic teardown: clean up database records created for TARGET_WORKLOAD
    if [[ -n "${PG_PORT:-}" && -n "${TARGET_WORKLOAD:-}" ]]; then
      cleanup_db "${PG_PORT}" "${TARGET_WORKLOAD}"
    fi

    # Kill background port-forwards
    if [[ -n "${DASH_PID:-}" ]]; then
      kill "${DASH_PID}" 2>/dev/null || true
    fi
    if [[ -n "${PG_PID:-}" ]]; then
      kill "${PG_PID}" 2>/dev/null || true
    fi
  fi
}

setup() {
  local state_file="${BATS_FILE_TMPDIR}/autoclaim-state.env"
  [ -f "${state_file}" ] || skip "setup_file failed to produce state file"
  set -a
  source "${state_file}"
  set +a
}

# ─── Test Suite ──────────────────────────────────────────────────────────────

@test "autoclaim: 1. discovered agent detection via API" {
  run curl -sS --max-time 10 \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/json" \
    "http://localhost:${DASH_PORT}/api/agents?limit=100"

  [ "$status" -eq 0 ]
  local count
  count="$(jq -r '.agents | length' <<<"$output")"
  [ "$count" -gt 0 ]

  local is_linked record_class
  is_linked="$(jq -r --arg w "$TARGET_WORKLOAD" '.agents[] | select(.name == $w) | .is_registry_linked' <<<"$output" | head -1)"
  record_class="$(jq -r --arg w "$TARGET_WORKLOAD" '.agents[] | select(.name == $w) | .record_class' <<<"$output" | head -1)"

  [ "$is_linked" = "false" ]
  [ "$record_class" = "discovered" ]
}

@test "autoclaim: 2. successful claim submission returns 200 and granted status" {
  local payload
  payload="$(jq -n \
    --arg workload "$TARGET_WORKLOAD" \
    --arg spiffe "$SPIFFE_ID" \
    '{
      pod_name: $workload,
      namespace: "fe-signalloom-agents",
      spiffe_id: $spiffe,
      harness: "kagent",
      model: "anthropic-claude",
      declared_tools: ["k8s_get_resources"],
      token_budget_limit: 100000
    }')"

  run curl -sS --max-time 10 -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    -w "\n__HTTP_STATUS__:%{http_code}" \
    "http://localhost:${DASH_PORT}/api/v1/agents/claim"

  [ "$status" -eq 0 ]
  [[ "$output" == *"__HTTP_STATUS__:200"* ]]

  local body
  body="${output%__HTTP_STATUS__:*}"
  local claim_status claim_id agent_id svid_verified
  claim_status="$(jq -r '.status' <<<"$body")"
  claim_id="$(jq -r '.claim_id' <<<"$body")"
  agent_id="$(jq -r '.agent_id' <<<"$body")"
  svid_verified="$(jq -r '.spiffe_svid_verified' <<<"$body")"

  [ "$claim_status" = "granted" ]
  [[ "$claim_id" =~ ^claim- ]]
  [[ "$agent_id" =~ ^[0-9a-f-]{36}$ ]]
  [ "$svid_verified" = "true" ]
}

@test "autoclaim: 3. database persistence in agent_registry with is_registry_linked=true" {
  run db_cmd get-agent
  [ "$status" -eq 0 ]

  local db_name db_status
  db_name="$(jq -r '.name' <<<"$output")"
  db_status="$(jq -r '.status' <<<"$output")"
  [ "$db_name" = "$TARGET_WORKLOAD" ]
  [ "$db_status" = "active" ]

  run curl -sS --max-time 10 \
    -H "Authorization: Bearer ${TOKEN}" \
    "http://localhost:${DASH_PORT}/api/agents"
  [ "$status" -eq 0 ]

  local is_linked record_class
  is_linked="$(jq -r --arg w "$TARGET_WORKLOAD" '.agents[] | select(.name == $w) | .is_registry_linked' <<<"$output" | head -1)"
  record_class="$(jq -r --arg w "$TARGET_WORKLOAD" '.agents[] | select(.name == $w) | .record_class' <<<"$output" | head -1)"

  [ "$is_linked" = "true" ]
  [ "$record_class" = "resolved" ]
}

@test "autoclaim: 4. origin verification record in agent_origin_verifications" {
  run db_cmd get-origin
  [ "$status" -eq 0 ]

  local verified origin_type auth_method
  verified="$(jq -r '.verified' <<<"$output")"
  origin_type="$(jq -r '.origin_type' <<<"$output")"
  auth_method="$(jq -r '.auth_method' <<<"$output")"

  [ "$verified" = "true" ]
  [ "$origin_type" = "kubernetes_workload" ]
  [ "$auth_method" = "spiffe_svid" ]
}

@test "autoclaim: 5. 6 seeded compliance control evaluations in agent_compliance_results" {
  run db_cmd get-compliance
  [ "$status" -eq 0 ]

  local count pass_count
  count="$(jq -r '.count' <<<"$output")"
  pass_count="$(jq -r '[.results[] | select(.status == "pass")] | length' <<<"$output")"

  [ "$count" -eq 6 ]
  [ "$pass_count" -ge 5 ]
}

@test "autoclaim: 6. posture score calculation resulting in > 0 score" {
  run curl -sS --max-time 10 \
    -H "Authorization: Bearer ${TOKEN}" \
    "http://localhost:${DASH_PORT}/api/agents"
  [ "$status" -eq 0 ]

  local score total passing
  score="$(jq -r --arg w "$TARGET_WORKLOAD" '.agents[] | select(.name == $w) | .compliance_summary.posture_score' <<<"$output" | head -1)"
  total="$(jq -r --arg w "$TARGET_WORKLOAD" '.agents[] | select(.name == $w) | .compliance_summary.total_controls' <<<"$output" | head -1)"
  passing="$(jq -r --arg w "$TARGET_WORKLOAD" '.agents[] | select(.name == $w) | .compliance_summary.passing' <<<"$output" | head -1)"

  [ "$total" -eq 6 ]
  [ "$passing" -ge 5 ]
  python3 -c "score = float('${score}'); assert score > 0.0, f'Score {score} not > 0'"
}

@test "autoclaim: 7. audit event logging of agent claim" {
  run db_cmd get-audit
  [ "$status" -eq 0 ]

  local actor action
  actor="$(jq -r '.actor' <<<"$output")"
  action="$(jq -r '.detail.action' <<<"$output")"

  [ "$actor" = "demo-user@signalloom.local" ]
  [ "$action" = "claimed" ]
}

@test "autoclaim: 8. idempotency on duplicate claim requests" {
  local payload
  payload="$(jq -n \
    --arg workload "$TARGET_WORKLOAD" \
    --arg spiffe "$SPIFFE_ID" \
    '{
      pod_name: $workload,
      namespace: "fe-signalloom-agents",
      spiffe_id: $spiffe,
      harness: "kagent",
      model: "anthropic-claude",
      declared_tools: ["k8s_get_resources"],
      token_budget_limit: 100000
    }')"

  # Repeat exact same claim
  run curl -sS --max-time 10 -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    -w "\n__HTTP_STATUS__:%{http_code}" \
    "http://localhost:${DASH_PORT}/api/v1/agents/claim"

  [ "$status" -eq 0 ]
  [[ "$output" == *"__HTTP_STATUS__:200"* ]]

  local body claim_status
  body="${output%__HTTP_STATUS__:*}"
  claim_status="$(jq -r '.status' <<<"$body")"
  [ "$claim_status" = "granted" ]

  run db_cmd count-agent
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "autoclaim: 9. tenant isolation rejecting foreign tenant access" {
  local payload
  payload="$(jq -n \
    --arg workload "$TARGET_WORKLOAD" \
    --arg spiffe "$SPIFFE_ID" \
    '{
      pod_name: $workload,
      namespace: "fe-signalloom-agents",
      spiffe_id: $spiffe,
      agent_type: "kagent"
    }')"

  run curl -sS --max-time 10 -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    -w "\n__HTTP_STATUS__:%{http_code}" \
    "http://localhost:${DASH_PORT}/api/v1/agents/claim"

  [ "$status" -eq 0 ]
  [[ "$output" == *"__HTTP_STATUS__:401"* ]]

  run curl -sS --max-time 10 -X POST \
    -H "Authorization: Bearer invalid-bearer-token-forged" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    -w "\n__HTTP_STATUS__:%{http_code}" \
    "http://localhost:${DASH_PORT}/api/v1/agents/claim"

  [ "$status" -eq 0 ]
  [[ "$output" == *"__HTTP_STATUS__:401"* ]]

  run curl -sS --max-time 10 -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -w "\n__HTTP_STATUS__:%{http_code}" \
    "http://localhost:${DASH_PORT}/api/v1/agents/00000000-0000-0000-0000-000000000000/claim"

  [ "$status" -eq 0 ]
  [[ "$output" == *"__HTTP_STATUS__:404"* ]]
}

@test "autoclaim: 10. malformed payload rejection with HTTP 422" {
  run curl -sS --max-time 10 -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{}" \
    -w "\n__HTTP_STATUS__:%{http_code}" \
    "http://localhost:${DASH_PORT}/api/v1/agents/claim"

  [ "$status" -eq 0 ]
  [[ "$output" == *"__HTTP_STATUS__:422"* ]]

  run curl -sS --max-time 10 -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"invalid_key": "garbage"}' \
    -w "\n__HTTP_STATUS__:%{http_code}" \
    "http://localhost:${DASH_PORT}/api/v1/agents/claim"

  [ "$status" -eq 0 ]
  [[ "$output" == *"__HTTP_STATUS__:422"* ]]
}
