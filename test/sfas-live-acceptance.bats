#!/usr/bin/env bats
#
# sfas-live-acceptance.bats — SFAS-P4-2. Live platform acceptance against the
# RUNNING signal-ingest: health, readiness and the authorization query for the
# claimed demo agents.
#
# @id      sfas-live-acceptance-bats
# @target  d2-signalloom/apps/signal-ingest
# @doc     docs/signalloom/sfas-p4-2-acceptance-evidence.md
#
# Every signal-ingest route is authenticated. This suite presents its own named
# static key, sldc-live-bats (cross-tenant read, health:read, actors:list), read
# from SLDC_LIVE_KEY_FILE or from the issuer Secret
# fe-signalloom/signal-ingest-key-sldc-live-bats, and hands it to curl only as a
# header FILE (-H @file): never argv, never printed. Mint it with
#   scripts/sldc-ingest-bearer.sh --context <ctx> --key sldc-live-bats
#
# What changed and why (2026-10-02): the earlier version asserted only curl's
# exit status, so once authentication was enforced every request "passed" with a
# 401 body. Each test now asserts the HTTP status and the body. Two tests named
# routes signal-ingest has never registered (GET /api/v1/delegations and
# POST /api/v1/stun/containment) and passed on any reply; they now pin that those
# routes are NOT served (403 unregistered_route), so the claim they made reads
# as the gap it is and the test goes red the day the route exists.

setup_file() {
  export INGEST_URL="${SIGNAL_INGEST_URL:-http://localhost:28082}"
  local key=""
  if [ -n "${SLDC_LIVE_KEY_FILE:-}" ]; then
    key="$(cat "$SLDC_LIVE_KEY_FILE")"
  else
    key="$(kubectl -n fe-signalloom get secret signal-ingest-key-sldc-live-bats \
      -o 'jsonpath={.data.token}' 2>/dev/null | base64 -d 2>/dev/null)" || key=""
  fi
  [ -n "$key" ] || {
    echo "no sldc-live-bats key: set SLDC_LIVE_KEY_FILE or run scripts/sldc-ingest-bearer.sh --key sldc-live-bats" >&2
    return 1
  }
  export AUTH_HEADER_FILE="$BATS_FILE_TMPDIR/auth-header"
  ( umask 077; printf 'Authorization: Bearer %s\n' "$key" >"$AUTH_HEADER_FILE" )
}

# ingest METHOD PATH [curl args...] -> "<status>" on line 1, body after.
ingest() {
  local method="$1" path="$2"; shift 2
  curl -sS -m 10 -X "$method" -H @"$AUTH_HEADER_FILE" -o "$BATS_TEST_TMPDIR/body" -w '%{http_code}' \
    "$@" "${INGEST_URL}${path}"
  printf '\n'
  cat "$BATS_TEST_TMPDIR/body"
}

@test "sfas-live: signal-ingest healthcheck responds HTTP 200 ok" {
  run ingest GET /healthz
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "200" ]
  [ "${lines[1]}" = '{"status":"ok"}' ]
}

@test "sfas-live: signal-ingest readiness responds HTTP 200 ready" {
  run ingest GET /readyz
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "200" ]
  [ "${lines[1]}" = '{"status":"ready"}' ]
}

@test "sfas-live: an anonymous request is refused 401" {
  run curl -sS -m 10 -o /dev/null -w '%{http_code}' "${INGEST_URL}/api/v1/authorization"
  [ "$status" -eq 0 ]
  [ "$output" = "401" ]
}

@test "sfas-live: the estate authorization query answers with a chain list" {
  # The old tests passed agent_id=<agent>; signal-ingest reads actor_id, so agent_id was always
  # ignored and every one of them was this estate-wide query. Asserted once, as what it is.
  run ingest GET /api/v1/authorization
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "200" ]
  echo "${lines[1]}" | jq -e '(.chains | type == "array") and (.total | type == "number")' >/dev/null
}

@test "sfas-live: GET /api/v1/delegations is not served by signal-ingest (known gap)" {
  run ingest GET "/api/v1/delegations?edge_id=expired-test-edge"
  [ "${lines[0]}" = "403" ]
  [ "${lines[1]}" = '{"error":"unregistered_route"}' ]
}

@test "sfas-live: POST /api/v1/stun/containment is not served by signal-ingest (known gap)" {
  run ingest POST /api/v1/stun/containment -H 'Content-Type: application/json' \
    -d '{"agent_id":"agent-compromised-demo","reason":"adversarial_drift","action":"stun"}'
  [ "${lines[0]}" = "403" ]
  [ "${lines[1]}" = '{"error":"unregistered_route"}' ]
}

@test "sfas-live: the committed red-team cascade record stays under the 25ms cycle ceiling" {
  run jq -e '.max_cycle_latency_us < 25000' d2-signalloom/apps/signal-ingest/correlation/redteam_cascade_ceiling.json
  [ "$status" -eq 0 ]
}
