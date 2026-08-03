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

# How many demo-script processes exist inside the runner pod right now.
#
# Two self-match traps here, and the obvious spelling falls into both. Written
# as `grep -la supercred-demo.sh /proc/[0-9]*/cmdline`, the pattern appears
# verbatim in the argv of the shell AND of grep itself, so both show up in
# /proc and the probe finds only itself — reporting a running demo script on a
# runner that started nothing. The bracket expression `[.]` matches the same
# text while never containing the literal string it searches for, so neither
# process can match.
#
# The count is compared BEFORE and AFTER rather than asserted to be zero: a
# legitimate superadmin run may be in flight (the demo is often mid-rehearsal),
# and "the refused call started nothing" is a statement about the delta.
runner_script_processes() {
  local pod
  pod="$(kubectl -n "$FE_NS" get pod -l app.kubernetes.io/name=supercred-demo-runner \
    -o jsonpath='{.items[0].metadata.name}')"
  kubectl -n "$FE_NS" exec "$pod" -- \
    bash -c 'grep -la "supercred-demo[.]sh" /proc/[0-9]*/cmdline 2>/dev/null | wc -l' 2>/dev/null \
    || echo unavailable
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

# ─── The runner's EFFECTIVE permissions ──────────────────────────────────────
#
# Not "do the RBAC objects exist" — they all did, with correct verbs and correct
# names, while the runner had no permissions whatsoever. The subject namespace
# on every binding named a ServiceAccount that does not exist, because the
# block sits in a ResourceSet whose << inputs.tenant >> is never the runner's
# tenant. Flux said Ready, the pod said script_available: true, and the first
# real run died in 92ms reporting "agent-cardvault pod not found" — because
# `kubectl get pod` exits non-zero on Forbidden exactly as it does on absent.
#
# `kubectl auth can-i --as` asks the API server the only question that matters:
# can THIS subject do THIS thing HERE. A binding pointed at the wrong subject
# answers "no" and names itself.

RUNNER_SA="system:serviceaccount:fe-signalloom:supercred-demo-runner"

@test "DEMOAPI the runner ServiceAccount can actually do what the demo script does" {
  # namespace|verb|resource|subresource — each derived from a kubectl call in
  # scripts/supercred-demo.sh, the same derivation the Roles document.
  #
  # Subresources go in the fourth field, NOT as "pods/exec" in the third.
  # `kubectl auth can-i create pods/exec` answers "no" against a Role that
  # plainly grants create on pods/exec, because the slash form is not how the
  # SelfSubjectAccessReview is built — it needs --subresource. Written the
  # obvious way this test reports a permissions gap that does not exist, which
  # is worse than not having it.
  local checks=(
    "fe-signalloom-agents|get|pods|"
    "fe-signalloom-agents|patch|pods|"
    "fe-signalloom-agents|create|jobs.batch|"
    "fe-signalloom|get|pods|"
    "fe-signalloom|patch|pods|"
    "inf-signalloom|get|deployments.apps|"
    "inf-signalloom|create|pods|portforward"
    "inf-bao|create|pods|exec"
    "kube-system|list|services|"
  )
  local failures=()
  local entry ns verb res sub answer args
  for entry in "${checks[@]}"; do
    IFS='|' read -r ns verb res sub <<< "$entry"
    args=("auth" "can-i" "$verb" "$res" "-n" "$ns" "--as=$RUNNER_SA")
    [ -n "$sub" ] && args+=("--subresource=$sub")
    answer="$(kubectl "${args[@]}" 2>/dev/null || true)"
    [ "$answer" = "yes" ] || failures+=("$verb $res${sub:+/$sub} in $ns -> ${answer:-error}")
  done
  # Report every gap at once; one at a time turns an RBAC audit into nine runs.
  [ "${#failures[@]}" -eq 0 ] || {
    printf 'runner SA cannot: %s\n' "${failures[@]}" >&2
    return 1
  }
}

@test "DEMOAPI every runner RoleBinding names a ServiceAccount that exists" {
  # The generalised form of the defect: a binding whose subject resolves to
  # nothing is silently inert. This catches it for any future binding, in any
  # namespace, without enumerating verbs.
  run bash -c "kubectl get rolebinding,clusterrolebinding -A -o json | python3 -c '
import json, subprocess, sys
missing = []
for item in json.load(sys.stdin)[\"items\"]:
    for subject in item.get(\"subjects\") or []:
        if subject.get(\"name\") != \"supercred-demo-runner\":
            continue
        ns = subject.get(\"namespace\", \"\")
        rc = subprocess.run([\"kubectl\", \"get\", \"sa\", \"supercred-demo-runner\", \"-n\", ns],
                            capture_output=True).returncode
        if rc != 0:
            missing.append(f\"{item[\\\"kind\\\"]}/{item[\\\"metadata\\\"][\\\"name\\\"]} -> serviceaccount {ns}/supercred-demo-runner\")
print(\"\n\".join(missing))'"
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
  before_procs="$(runner_script_processes)"

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
  after_procs="$(runner_script_processes)"
  [ "$after_procs" = "$before_procs" ]
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
