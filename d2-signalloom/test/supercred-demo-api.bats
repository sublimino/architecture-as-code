#!/usr/bin/env bats
# The /demo-api/ authorization boundary, probed against the RUNNING cluster.
#
# Everything here has a unit test already (src/tests/test_demo_runner.py) and
# every one of those passes by injecting a Principal into FastAPI's dependency
# graph. That is exactly the shape of green test that hid the last defect in
# this slice: demo_runner.py was fully covered and could not execute anything,
# because the tests supplied a script path the deployed pod did not have. So
# these tests use real Dex-signed tokens, over the real Gateway, through the
# real nginx proxy, against the real runner pod, and assert on what comes back.
#
# ─── The two identities ─────────────────────────────────────────────────────
#
# demo-user@signalloom.local is the instructor and IS a superadmin (it is on
# api_superadmin_emails). viewer@signalloom.local authenticates cleanly and is
# NOT a superadmin. Both are Dex staticPasswords
# (infra/inf-signalloom/base/dex.yaml) and both map to tenant-demo, so a 403
# from viewer is unambiguously the superadmin gate firing and not a missing
# tenant mapping — the two are distinguished by their error code, which is
# asserted rather than assumed.
#
# Skips are loud and name the make target, never silent.

DEX_NS="inf-signalloom"
FE_NS="fe-signalloom"
DEX_LOCAL_PORT="${DEX_LOCAL_PORT:-15557}"
DASH_LOCAL_PORT="${DASH_LOCAL_PORT:-18444}"

# shellcheck source=../../scripts/lib/wait.sh
source "${BATS_TEST_DIRNAME}/../../scripts/lib/wait.sh"

setup_file() {
  kubectl get deployment supercred-demo-runner -n "$FE_NS" >/dev/null 2>&1 || return 0
}

runner_deployed() {
  kubectl get deployment supercred-demo-runner -n "$FE_NS" >/dev/null 2>&1
}

start_forwards() {
  kubectl -n "$DEX_NS" port-forward svc/dex "${DEX_LOCAL_PORT}:5556" \
    >"$BATS_TEST_TMPDIR/dex-pf.log" 2>&1 &
  DEX_PID=$!
  kubectl -n "$FE_NS" port-forward svc/dashboard-signalloom "${DASH_LOCAL_PORT}:8080" \
    >"$BATS_TEST_TMPDIR/dash-pf.log" 2>&1 &
  DASH_PID=$!
  wait_tcp 127.0.0.1 "$DEX_LOCAL_PORT" 30
  wait_tcp 127.0.0.1 "$DASH_LOCAL_PORT" 30
}

teardown() {
  for pid in "${DEX_PID:-}" "${DASH_PID:-}"; do
    [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1
  done
  unset DEX_PID DASH_PID
  return 0
}

# Dex password grant. signalloom-dashboard is a PUBLIC client (public: true in
# dex.yaml) so client_id goes in the form body, not HTTP Basic — using --user
# against a client with no secret causes a connection reset, not a 401.
#
# The audience scope is load-bearing: without
# `audience:server:client_id:signalloom-api` Dex mints an id_token with
# aud=signalloom-dashboard, and the API rejects it as invalid_token. That would
# make a viewer's request 401 instead of 403 and quietly turn the superadmin
# assertion below into an assertion about a malformed token.
mint_token() {
  local username="$1" password="$2"
  curl -fsS \
    --data-urlencode 'grant_type=password' \
    --data-urlencode 'client_id=signalloom-dashboard' \
    --data-urlencode "username=${username}" \
    --data-urlencode "password=${password}" \
    --data-urlencode 'scope=openid profile email groups audience:server:client_id:signalloom-api' \
    "http://127.0.0.1:${DEX_LOCAL_PORT}/dex/token" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id_token"])'
}

demo_api() {
  local method="$1" path="$2" token="${3:-}" body="${4:-}"
  local args=(-sS -o "$BATS_TEST_TMPDIR/body" -w '%{http_code}' -X "$method")
  [ -n "$token" ] && args+=(-H "Authorization: Bearer ${token}")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl "${args[@]}" "http://127.0.0.1:${DASH_LOCAL_PORT}${path}"
}

# Pull one field out of the LAST response body demo_api wrote. Reads the file
# directly rather than through a helper function, because `run bash -c ...`
# spawns a shell that has none of this file's functions.
body_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]] if len(sys.argv)==3 else "")' \
    "$BATS_TEST_TMPDIR/body" "$1"
}

error_code() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["error"]["code"])' \
    "$BATS_TEST_TMPDIR/body"
}

# "how many runs does the runner know about, and is one active" — the state
# that must not move when an unauthorized call is refused.
run_state_fingerprint() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["recent"]), d["active"] is not None)' \
    "$BATS_TEST_TMPDIR/body"
}

setup() {
  runner_deployed || skip "supercred-demo-runner not deployed — run: make demo-signalloom-supercred-runner-image && flux reconcile"
  start_forwards
  SUPERADMIN_TOKEN="$(mint_token 'demo-user@signalloom.local' "${DEX_DEMO_PASSWORD:-demo-user}")"
  VIEWER_TOKEN="$(mint_token 'viewer@signalloom.local' "${DEX_VIEWER_PASSWORD:-viewer}")"
  [ -n "$SUPERADMIN_TOKEN" ]
  [ -n "$VIEWER_TOKEN" ]
}

# ─── ISC-14: not reachable except through the gated route ────────────────────

@test "DEMOAPI runner Service is ClusterIP — no NodePort, no LoadBalancer" {
  run kubectl -n "$FE_NS" get svc supercred-demo-runner -o jsonpath='{.spec.type}'
  [ "$status" -eq 0 ]
  # Empty means the default, which is ClusterIP.
  [ "$output" = "ClusterIP" ] || [ -z "$output" ]

  run kubectl -n "$FE_NS" get svc supercred-demo-runner -o jsonpath='{.spec.ports[*].nodePort}'
  [ -z "$output" ]
}

@test "DEMOAPI no Gateway route targets the runner directly" {
  # A HTTPRoute to the runner would put the control plane on the internet
  # beside the dashboard, bypassing the nginx block that forwards the bearer.
  run bash -c "kubectl get httproute -A -o json | python3 -c '
import json,sys
routes = json.load(sys.stdin)[\"items\"]
hits = [r[\"metadata\"][\"name\"] for r in routes
        for rule in r[\"spec\"].get(\"rules\", [])
        for ref in rule.get(\"backendRefs\", [])
        if ref.get(\"name\") == \"supercred-demo-runner\"]
print(\" \".join(hits))'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ─── ISC-16/17/18: /status by token class ────────────────────────────────────

@test "DEMOAPI /demo-api/status without a token returns 401" {
  run demo_api GET /demo-api/status
  [ "$output" = "401" ]
}

@test "DEMOAPI /demo-api/status with a NON-superadmin token returns 403" {
  run demo_api GET /demo-api/status "$VIEWER_TOKEN"
  [ "$output" = "403" ]
  # The code matters: tenant_forbidden would mean the viewer never reached the
  # superadmin check and this test proved nothing about the gate.
  run error_code
  [ "$output" = "superadmin_required" ]
}

@test "DEMOAPI /demo-api/status with a superadmin token returns 200 and script_available" {
  run demo_api GET /demo-api/status "$SUPERADMIN_TOKEN"
  [ "$output" = "200" ]
  run body_field script_available
  [ "$output" = "True" ]
}

# ─── ISC-19/20: /runs by token class ─────────────────────────────────────────

@test "DEMOAPI POST /demo-api/runs with a NON-superadmin token returns 403 and starts nothing" {
  # Snapshot the runner's own view of its run history first, so "started
  # nothing" is asserted against state and not merely inferred from a status
  # code. A gate that ran the script and THEN refused would return 403 too.
  demo_api GET /demo-api/status "$SUPERADMIN_TOKEN" >/dev/null
  before_state="$(run_state_fingerprint)"

  run demo_api POST /demo-api/runs "$VIEWER_TOKEN" '{"step":"1"}'
  [ "$output" = "403" ]
  run error_code
  [ "$output" = "superadmin_required" ]

  demo_api GET /demo-api/status "$SUPERADMIN_TOKEN" >/dev/null
  after_state="$(run_state_fingerprint)"
  [ "$before_state" = "$after_state" ]

  # And no demo script process exists inside the runner pod. This is the half
  # that a status-code assertion cannot reach: if the gate were ever moved
  # below the spawn, the caller would still see 403 while the script had
  # already started mutating the cluster.
  pod="$(kubectl -n "$FE_NS" get pod -l app.kubernetes.io/name=supercred-demo-runner \
    -o jsonpath='{.items[0].metadata.name}')"
  # The pattern is ASSEMBLED at runtime and never appears whole in the probe's
  # own command line. Written literally, `grep supercred-demo.sh /proc/*/cmdline`
  # matches the /proc entry of the shell running it — the probe finds itself,
  # reports 1, and fails on a runner that started nothing. Same self-match trap
  # as `pgrep -f` on your own command.
  run kubectl -n "$FE_NS" exec "$pod" -- \
    bash -c 'p=supercred; q=-demo.sh; grep -la "$p$q" /proc/[0-9]*/cmdline 2>/dev/null | wc -l'
  [ "$output" = "0" ]
}

@test "DEMOAPI POST /demo-api/runs with a superadmin token returns 202 with a run_id" {
  run demo_api POST /demo-api/runs "$SUPERADMIN_TOKEN" '{"step":"1"}'
  [ "$output" = "202" ]
  run body_field run_id
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ─── ISC-22: no token in a URL ───────────────────────────────────────────────

@test "DEMOAPI the client never puts a token in a URL" {
  # The browser-side proof is in test/acceptance/supercred-two-window.spec.ts,
  # which audits every live request. This is the static half: the only query
  # parameter the client ever builds is the log offset.
  # Enumerate every query parameter the client builds and assert the set is
  # exactly {offset}. Asserting the ABSENCE of "token" near a "?" instead was
  # the first attempt and it was wrong twice over: it flagged the TypeScript
  # optional-parameter syntax `body?: unknown, token?: string`, and it would
  # have missed a parameter named anything else that carried a credential.
  # Enumerating what IS there cannot be fooled by either.
  params="$(grep -oE '[?&][A-Za-z_][A-Za-z0-9_]*=' \
    "${BATS_TEST_DIRNAME}/../apps/dashboard-signalloom/src/api/demoRunner.ts" \
    | tr -d '?&=' | sort -u | tr '\n' ' ')"
  [ "$params" = "offset " ]

  # And the token is passed as a header, on every call that carries one.
  run grep -c 'Authorization: `Bearer' "${BATS_TEST_DIRNAME}/../apps/dashboard-signalloom/src/api/demoRunner.ts"
  [ "$output" -ge 1 ]
}
