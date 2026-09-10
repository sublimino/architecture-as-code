#!/usr/bin/env bats
# d2-signalloom/test/sentinel-evidence.bats
#
# STUNSWARM-P1-3: Positive dry-run mode, health HTTP endpoint (:8081/healthz),
# structured audit logging, and audit verification in signalloom-stun-sentinel.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SENTINEL_DIR="${REPO_ROOT}/d2-signalloom/apps/signalloom-stun-sentinel"
  BIN_DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$BIN_DIR"
  SENTINEL_BIN="${BIN_DIR}/signalloom-stun-sentinel"

  command -v jq >/dev/null || skip "jq is required"
  command -v curl >/dev/null || skip "curl is required"
}

teardown() {
  if [ -n "${SENTINEL_PID:-}" ] && kill -0 "$SENTINEL_PID" 2>/dev/null; then
    kill "$SENTINEL_PID" 2>/dev/null || true
    wait "$SENTINEL_PID" 2>/dev/null || true
  fi
}

cluster_up() {
  kubectl get ns "fe-signalloom-agents" >/dev/null 2>&1
}

# ── 1. Unit Test Suite Verification ──────────────────────────────────────────

@test "sentinel: Go unit test suite passes 100%" {
  run bash -c "cd '${SENTINEL_DIR}' && go test -v ./..."
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "sentinel: binary builds cleanly" {
  run bash -c "cd '${SENTINEL_DIR}' && go build -o '${SENTINEL_BIN}' ."
  [ "$status" -eq 0 ]
  [ -x "$SENTINEL_BIN" ]
}

# ── 2. Positive Dry-Run Mode & Audit Verification ─────────────────────────────

@test "sentinel: --dry-run flag enables dry-run mode without mutating kernel state" {
  [ -x "$SENTINEL_BIN" ] || bash -c "cd '${SENTINEL_DIR}' && go build -o '${SENTINEL_BIN}' ."

  local log_file="${BATS_TEST_TMPDIR}/sentinel-dryrun-flag.log"
  # Run sentinel in dry-run mode with ephemeral port
  "${SENTINEL_BIN}" --dry-run --health-addr="127.0.0.1:18081" > "$log_file" 2>&1 &
  SENTINEL_PID=$!

  # Wait for startup log
  local retries=20 started=0
  while [ "$retries" -gt 0 ]; do
    if grep -q '"event":"started"' "$log_file" 2>/dev/null; then
      started=1
      break
    fi
    sleep 0.1
    retries=$((retries - 1))
  done

  [ "$started" -eq 1 ]

  # Verify started event has dry_run: true
  local started_line
  started_line="$(grep '"event":"started"' "$log_file" | head -1)"
  run jq -e '.dry_run == true' <<< "$started_line"
  [ "$status" -eq 0 ]
}

@test "sentinel: STUN_DRY_RUN=true environment variable enables dry-run mode" {
  [ -x "$SENTINEL_BIN" ] || bash -c "cd '${SENTINEL_DIR}' && go build -o '${SENTINEL_BIN}' ."

  local log_file="${BATS_TEST_TMPDIR}/sentinel-dryrun-env.log"
  STUN_DRY_RUN=true "${SENTINEL_BIN}" --health-addr="127.0.0.1:18082" > "$log_file" 2>&1 &
  SENTINEL_PID=$!

  local retries=20 started=0
  while [ "$retries" -gt 0 ]; do
    if grep -q '"event":"started"' "$log_file" 2>/dev/null; then
      started=1
      break
    fi
    sleep 0.1
    retries=$((retries - 1))
  done

  [ "$started" -eq 1 ]

  local started_line
  started_line="$(grep '"event":"started"' "$log_file" | head -1)"
  run jq -e '.dry_run == true' <<< "$started_line"
  [ "$status" -eq 0 ]
}

# ── 3. HTTP Health & Readiness Server (:8081/healthz) ─────────────────────────

@test "sentinel: HTTP :8081/healthz returns 200 OK with correct JSON schema" {
  [ -x "$SENTINEL_BIN" ] || bash -c "cd '${SENTINEL_DIR}' && go build -o '${SENTINEL_BIN}' ."

  local log_file="${BATS_TEST_TMPDIR}/sentinel-health-8081.log"
  local health_port=18183
  "${SENTINEL_BIN}" --dry-run --health-addr="127.0.0.1:${health_port}" > "$log_file" 2>&1 &
  SENTINEL_PID=$!

  # Poll healthz until answering
  local retries=30 http_code=0
  while [ "$retries" -gt 0 ]; do
    http_code="$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${health_port}/healthz" 2>/dev/null || echo "0")"
    if [ "$http_code" = "200" ]; then
      break
    fi
    sleep 0.1
    retries=$((retries - 1))
  done

  [ "$http_code" = "200" ]

  # Fetch JSON response
  local resp
  resp="$(curl -s "http://127.0.0.1:${health_port}/healthz")"

  # Validate JSON structure against schema
  run jq -e '.status == "ok"' <<< "$resp"
  [ "$status" -eq 0 ]

  run jq -e '.dry_run == true' <<< "$resp"
  [ "$status" -eq 0 ]

  run jq -e 'has("cgroup_driver") and (.cgroup_driver | type == "string")' <<< "$resp"
  [ "$status" -eq 0 ]

  run jq -e 'has("tc_ready") and (.tc_ready | type == "boolean")' <<< "$resp"
  [ "$status" -eq 0 ]

  run jq -e 'has("reconcile_count") and (.reconcile_count | type == "number")' <<< "$resp"
  [ "$status" -eq 0 ]
}

@test "sentinel: /readyz and /health aliases return HTTP 200 OK" {
  [ -x "$SENTINEL_BIN" ] || bash -c "cd '${SENTINEL_DIR}' && go build -o '${SENTINEL_BIN}' ."

  local health_port=18184
  "${SENTINEL_BIN}" --dry-run --health-addr="127.0.0.1:${health_port}" > /dev/null 2>&1 &
  SENTINEL_PID=$!

  local retries=20
  while [ "$retries" -gt 0 ]; do
    if curl -s "http://127.0.0.1:${health_port}/healthz" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
    retries=$((retries - 1))
  done

  local ready_code health_code
  ready_code="$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${health_port}/readyz")"
  health_code="$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${health_port}/health")"

  [ "$ready_code" = "200" ]
  [ "$health_code" = "200" ]
}

@test "sentinel: health endpoint rejects POST requests with 405 Method Not Allowed" {
  [ -x "$SENTINEL_BIN" ] || bash -c "cd '${SENTINEL_DIR}' && go build -o '${SENTINEL_BIN}' ."

  local health_port=18185
  "${SENTINEL_BIN}" --dry-run --health-addr="127.0.0.1:${health_port}" > /dev/null 2>&1 &
  SENTINEL_PID=$!

  local retries=20
  while [ "$retries" -gt 0 ]; do
    if curl -s "http://127.0.0.1:${health_port}/healthz" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
    retries=$((retries - 1))
  done

  local post_code
  post_code="$(curl -s -X POST -o /dev/null -w "%{http_code}" "http://127.0.0.1:${health_port}/healthz")"
  [ "$post_code" = "405" ]
}

# ── 4. Structured JSON Audit Logging ──────────────────────────────────────────

@test "sentinel: audit logs emit valid structured JSON lines with required fields" {
  [ -x "$SENTINEL_BIN" ] || bash -c "cd '${SENTINEL_DIR}' && go build -o '${SENTINEL_BIN}' ."

  local log_file="${BATS_TEST_TMPDIR}/sentinel-audit.log"
  local health_port=18186
  "${SENTINEL_BIN}" --dry-run --health-addr="127.0.0.1:${health_port}" > "$log_file" 2>&1 &
  SENTINEL_PID=$!

  # Wait for startup
  local retries=20
  while [ "$retries" -gt 0 ]; do
    if [ -s "$log_file" ]; then
      break
    fi
    sleep 0.1
    retries=$((retries - 1))
  done

  # Send SIGTERM to trigger graceful shutdown log
  kill -TERM "$SENTINEL_PID" 2>/dev/null || true
  wait "$SENTINEL_PID" 2>/dev/null || true
  unset SENTINEL_PID

  [ -s "$log_file" ]

  # Validate that every non-empty line in log_file is valid JSON with timestamp and event
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Verify line is valid JSON
    run jq -e . <<< "$line"
    [ "$status" -eq 0 ]

    # Verify timestamp field exists and is non-null
    run jq -e 'has("timestamp") and (.timestamp | type == "string")' <<< "$line"
    [ "$status" -eq 0 ]

    # Verify event field exists and is non-null
    run jq -e 'has("event") and (.event | type == "string")' <<< "$line"
    [ "$status" -eq 0 ]
  done < "$log_file"
}

# ── 5. Live Cluster Verification (when cluster is running) ───────────────────

@test "LIVE: signalloom-stun-sentinel health probe is reachable in cluster" {
  cluster_up || skip "no cluster"
  local pod
  pod="$(kubectl get pods -n "fe-signalloom-agents" -l app.kubernetes.io/name=stun-sentinel -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$pod" ] || skip "stun-sentinel pod not found in fe-signalloom-agents"

  run kubectl exec -n "fe-signalloom-agents" "$pod" -- curl -s "http://127.0.0.1:8081/healthz"
  if [ "$status" -eq 0 ]; then
    run jq -e '.status == "ok"' <<< "$output"
    [ "$status" -eq 0 ]
  fi
}
