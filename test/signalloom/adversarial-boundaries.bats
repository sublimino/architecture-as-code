#!/usr/bin/env bats
#
# test/signalloom/adversarial-boundaries.bats — SLON-P3-2
#
# Adversarial boundary probes against a REAL running Signal Loom API.
#
# WHY THIS BOOTS A SERVER
# =======================
# The card declares two curl probes against http://localhost:8080.  Nothing
# listens there:
#
#     $ curl -sS -X POST http://localhost:8080/api/onboarding/state \
#         -H 'Authorization: Bearer invalid-token' -o /dev/null -w '%{http_code}'
#     curl: (7) Failed to connect to localhost port 8080 ... exit 7, %{http_code}=000
#
# A suite that recorded that as a pass would be recording the absence of a
# server as the presence of a boundary.  So setup_file starts the actual
# FastAPI application under uvicorn on an ephemeral port and the probes run
# against it for real.  If the server does not come up, every test FAILS --
# it does not skip.  A skipped security test reads as a passing one.
#
# WHAT THE CURL PROBES ACTUALLY RETURN
# ====================================
# The card names `POST /api/onboarding/state`.  That route is PUT-only, so the
# honest answer is 405 (routing is resolved before authentication).  Both the
# card's literal verb and the real one are asserted below, because "405" and
# "401" are different claims and only one of them is about the auth boundary.
#
# Deep assertions -- tenant partitioning, hash-chain tampering, claim conflict
# -- live in the pytest suite, which can drive a database fake.  This file
# covers what only a live socket can show: that the wire-level refusals are
# real, and that they happen before the request body is ever parsed.

setup_file() {
  export PATH="/home/linuxbrew/.linuxbrew/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.bun/bin:$PATH"

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  export API_SRC="$REPO_ROOT/d2-signalloom/apps/fe-signalloom/src"
  export PYTEST_SUITE="$API_SRC/tests/test_adversarial_onboarding.py"
  export MUTATION_PROBE="$API_SRC/tests/mutation_probe.sh"
  export EVIDENCE_DOC="$REPO_ROOT/docs/signalloom/slon-p3-2-evidence.md"
  export UV_CACHE_DIR="${UV_CACHE_DIR:-/home/andy/src/.worktrees/.uvcache}"

  # The system under test must be present.  Missing tooling is a failure, not
  # a reason to skip: a suite that skips its way to green is indistinguishable
  # from one that passed.
  for cmd in curl uv python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "required tool '$cmd' is missing — refusing to skip a security suite" >&2
      return 1
    fi
  done

  API_PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  export API_PORT
  export API="http://127.0.0.1:$API_PORT"
  export API_LOG="$BATS_FILE_TMPDIR/uvicorn.log"

  # setsid + all three fds redirected.  Without setsid the child dies with the
  # harness session; without the fd redirection it keeps writing into the
  # caller's output stream and the task never settles.
  # adversarial_boot re-exports main:app after using the documented
  # set_pool_for_testing seam.  Serving main:app directly raises
  # KeyError: 'DATABASE_URL' from the lifespan, and pointing a fake DSN at it
  # would make asyncpg attempt a real connection instead.
  setsid env UV_CACHE_DIR="$UV_CACHE_DIR" PYTHONPATH="$API_SRC:$BATS_TEST_DIRNAME" \
    uv run --python 3.12 --with uvicorn --with-requirements "$API_SRC/requirements.txt" \
    python -m uvicorn adversarial_boot:app --host 127.0.0.1 --port "$API_PORT" \
    </dev/null >"$API_LOG" 2>&1 &
  API_PID=$!
  export API_PID
  echo "$API_PID" > "$BATS_FILE_TMPDIR/api.pid"

  # Poll for readiness rather than sleeping: a fixed sleep is either wasted
  # time or a flake, and usually both on different machines.
  local waited=0
  until curl -fsS -m 2 "$API/health" >/dev/null 2>&1; do
    if ! kill -0 "$API_PID" 2>/dev/null; then
      echo "uvicorn exited during startup; log follows:" >&2
      cat "$API_LOG" >&2
      return 1
    fi
    waited=$((waited + 1))
    if [ "$waited" -gt 120 ]; then
      echo "uvicorn did not become ready within 60s; log follows:" >&2
      cat "$API_LOG" >&2
      return 1
    fi
    sleep 0.5
  done
}

teardown_file() {
  # Kill by explicit PID.  A pattern kill would match this harness's own
  # `bash -c` wrapper, which is a silent way to lose the rest of the run.
  if [ -f "$BATS_FILE_TMPDIR/api.pid" ]; then
    local pid
    pid="$(cat "$BATS_FILE_TMPDIR/api.pid")"
    if [ -n "$pid" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    fi
  fi
}

# Status code only, so a response body can never be mistaken for one.
http_code() {
  curl -sS -o /dev/null -w '%{http_code}' -m 10 "$@"
}

body() {
  curl -sS -m 10 "$@"
}

# ---------------------------------------------------------------------------
# The server is genuinely up.  Everything below is meaningless otherwise.
# ---------------------------------------------------------------------------

@test "1. the API under test is live and answering (not a connection refusal)" {
  run http_code "$API/health"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  # 000 is what the card's original probes returned against a dead port.  If it
  # ever appears again, every refusal below is a connection error wearing a
  # security assertion's clothes.
  [ "$output" != "000" ]
}

# ---------------------------------------------------------------------------
# The two probes the card declared, executed for real.
# ---------------------------------------------------------------------------

@test "2. card probe: POST /api/onboarding/state with an invalid bearer is refused" {
  run http_code -X POST "$API/api/onboarding/state" -H 'Authorization: Bearer invalid-token'
  [ "$status" -eq 0 ]

  # 405, not 401: the route is PUT-only and routing resolves before the auth
  # dependency runs.  Asserted exactly rather than as "4xx", because a change
  # from 405 to 200 and a change from 405 to 401 mean very different things.
  [ "$output" = "405" ]

  run body -X POST "$API/api/onboarding/state" -H 'Authorization: Bearer invalid-token'
  [[ "$output" == *"method_not_allowed"* ]]
}

@test "3. the same route on its real verb refuses an invalid bearer with 401" {
  run http_code -X PUT "$API/api/onboarding/state" \
    -H 'Authorization: Bearer invalid-token' -H 'Content-Type: application/json' \
    -d '{"step_index": 4, "selected_provider_ids": [], "provider_run_state": {}}'
  [ "$status" -eq 0 ]
  [ "$output" = "401" ]
}

@test "4. card probe: POST /api/audit/sessions with a corrupted body and no auth returns 401" {
  run http_code -X POST "$API/api/audit/sessions" \
    -H 'Content-Type: application/json' -d '{"corrupted": true}'
  [ "$status" -eq 0 ]
  [ "$output" = "401" ]
}

@test "5. authentication precedes body validation — the 401 leaks no schema" {
  # A 422 here would be an oracle: an unauthenticated attacker could map the
  # request schema one field at a time by watching validation errors.
  run body -X POST "$API/api/audit/sessions" \
    -H 'Content-Type: application/json' -d '{"corrupted": true}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"authentication_required"* ]]
  [[ "$output" != *"session_id"* ]]
  [[ "$output" != *"root_hash"* ]]
  [[ "$output" != *"field required"* ]]
}

# ---------------------------------------------------------------------------
# Unauthenticated access to every protected surface.
# ---------------------------------------------------------------------------

@test "6. every protected read refuses an anonymous caller with 401" {
  local path
  for path in /api/onboarding/status /api/onboarding/state /api/agents/claims /api/audit/sessions; do
    run http_code "$API$path"
    [ "$status" -eq 0 ]
    [ "$output" = "401" ] || {
      echo "GET $path returned $output, expected 401" >&2
      return 1
    }
  done
}

@test "7. every protected mutation refuses an anonymous caller with 401" {
  run http_code -X POST "$API/api/onboarding/skip"
  [ "$output" = "401" ]

  run http_code -X POST "$API/api/onboarding/complete"
  [ "$output" = "401" ]

  run http_code -X POST "$API/api/agents/claim" -H 'Content-Type: application/json' \
    -d '{"pod_name":"probe","spiffe_id":"spiffe://cluster.local/ns/x/sa/probe"}'
  [ "$output" = "401" ]

  run http_code -X POST "$API/api/audit/sessions/verify" -H 'Content-Type: application/json' -d '{}'
  [ "$output" = "401" ]
}

@test "8. malformed Authorization headers are refused, not parsed generously" {
  local header
  while IFS= read -r header; do
    [ -n "$header" ] || continue
    run http_code "$API/api/onboarding/status" -H "Authorization: $header"
    [ "$status" -eq 0 ]
    [ "$output" = "401" ] || {
      echo "header '$header' returned $output, expected 401" >&2
      return 1
    }
  done <<'HEADERS'
Basic YWxpY2U6cGFzcw==
Bearer
Bearer token with spaces
Token abc123
bearer
HEADERS
}

@test "9. an unsigned alg:none token is refused" {
  local token
  token="$(python3 - <<'PY'
import base64, json, time
def seg(d): return base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
now = int(time.time())
h = seg({"alg": "none", "typ": "JWT", "kid": "test-key"})
p = seg({"iss": "https://issuer.test/dex", "aud": "signalloom-api", "sub": "alice",
         "iat": now, "nbf": now, "exp": now + 300, "azp": "signalloom-dashboard"})
print(f"{h}.{p}.")
PY
)"
  [ -n "$token" ]
  run http_code "$API/api/onboarding/status" -H "Authorization: Bearer $token"
  [ "$status" -eq 0 ]
  [ "$output" = "401" ]
}

@test "10. no refusal leaks a stack trace, SQL, or a filesystem path" {
  local path
  for path in /api/onboarding/status /api/audit/sessions /api/agents/claims; do
    run body "$API$path" -H 'Authorization: Bearer garbage.token.here'
    [ "$status" -eq 0 ]
    [[ "$output" != *"Traceback"* ]]
    [[ "$output" != *"site-packages"* ]]
    [[ "$output" != *"asyncpg"* ]]
    [[ "$output" != *"postgresql://"* ]]
    [[ "$output" != *"SELECT "* ]]
    [[ "$output" != *"/app/"* ]]
  done
}

@test "11. the health surface is reachable without a token, and exposes nothing else" {
  run body "$API/health"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
  [[ "$output" != *"postgresql://"* ]]
  [[ "$output" != *"password"* ]]
}

# ---------------------------------------------------------------------------
# Static guards over the deliverables themselves.
# ---------------------------------------------------------------------------

@test "12. the pytest adversarial suite exists and declares its falsifying mutations" {
  [ -f "$PYTEST_SUITE" ]
  run grep -c 'mutation_probe.sh' "$PYTEST_SUITE"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "13. every mutation named in the pytest suite is registered in mutation_probe.sh" {
  [ -f "$MUTATION_PROBE" ]
  local missing=""
  local m
  # Derived from the suite, not hand-copied: a hand-maintained list goes stale
  # silently and then vouches for mutations that no longer exist.
  for m in $(grep -oE 'mutation ``[a-z_]+``' "$PYTEST_SUITE" | grep -oE '[a-z_]+$' | sort -u); do
    grep -q "\[$m\]=" "$MUTATION_PROBE" || missing="$missing $m"
  done
  [ -z "$missing" ] || {
    echo "mutations referenced by the suite but not registered:$missing" >&2
    return 1
  }
}

@test "14. the wizard payloads use the model's real field names" {
  # OnboardingWizardState is step_index / selected_provider_ids /
  # provider_run_state, and pydantic drops unknown keys in silence.  A
  # camelCase payload round-trips as an empty state, which made the first draft
  # of the cross-tenant leak test vacuously true.
  run grep -c 'currentStep\|completedSteps' "$PYTEST_SUITE"
  [ "$output" = "0" ]
  run grep -c 'step_index' "$PYTEST_SUITE"
  [ "$output" -ge 1 ]
}

@test "15. the claim conflict message does not interpolate the owning tenant" {
  local api_compat="$API_SRC/api_compat.py"
  [ -f "$api_compat" ]

  # No raise site interpolates a tenant into the message.
  run grep -c "already claimed by tenant '" "$api_compat"
  [ "$output" = "0" ]

  # Both raise sites carry the safe message.  Anchored on the f-string, NOT on
  # the prose: a pre-existing comment two lines above the first raise reads
  # "Check cross-tenant conflict: if already claimed by another tenant", and a
  # prose-matching guard counts it as a third code site.  It would also stay
  # green if a raise site were deleted and only the comment remained -- a guard
  # satisfied by a comment is not a guard.
  run grep -cF "f\"Agent '{body.pod_name}' is already claimed by another tenant\"" "$api_compat"
  [ "$output" = "2" ]
}

@test "16. the evidence report exists and records the probe results" {
  [ -f "$EVIDENCE_DOC" ]
  run grep -c 'SLON-P3-2' "$EVIDENCE_DOC"
  [ "$output" -ge 1 ]
  grep -q 'mutation' "$EVIDENCE_DOC"
  grep -q 'tree hash' "$EVIDENCE_DOC"
}
