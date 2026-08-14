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

# Block until the runner has no active run, so a POST that expects 202 is not
# racing one.
#
# The runner serialises runs: POST /demo-api/runs answers 409
# demo_run_in_progress while another is in flight. Any test that starts a run
# and does not wait for it therefore arms the next one to fail, and the failure
# names a status code rather than the collision — which is exactly how this
# read as a product bug when it was only test ordering. The same race hits a
# clean single test if the demo is mid-rehearsal, which the note above
# explicitly allows for.
#
# Returns non-zero on timeout rather than looping forever, so a genuinely stuck
# runner still surfaces as a failure instead of a hang.
wait_for_idle() {
  local deadline=$((SECONDS + ${1:-60}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    demo_api GET /demo-api/status "$SUPERADMIN_TOKEN" >/dev/null
    python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["active"] is None else 1)' \
      "$BATS_TEST_TMPDIR/body" 2>/dev/null && return 0
    sleep 2
  done
  echo "runner still busy after ${1:-60}s" >&2
  return 1
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
  # Plain bash and jq. An earlier version embedded Python inside `run bash -c
  # "..."`, where bats' own quoting, the shell's, and Python's string literals
  # all had to survive four levels of escaping — it reported a failure that a
  # hand-run of the same logic could not reproduce. The test harness must not
  # be harder to read than the thing it tests.
  local bindings failures=()
  bindings="$(kubectl get rolebinding,clusterrolebinding -A -o json \
    | jq -r '.items[]
             | . as $b
             | (.subjects // [])[]
             | select(.name == "supercred-demo-runner")
             | "\($b.kind)/\($b.metadata.namespace // "-")/\($b.metadata.name)\t\(.namespace // "")"')"

  local line ref subject_ns
  while IFS=$'\t' read -r ref subject_ns; do
    [ -n "$ref" ] || continue
    kubectl get serviceaccount supercred-demo-runner -n "$subject_ns" >/dev/null 2>&1 \
      || failures+=("$ref -> serviceaccount ${subject_ns}/supercred-demo-runner does not exist")
  done <<< "$bindings"

  # A binding with no subjects at all is the same defect wearing a different
  # hat, so an empty result is a failure too, not a pass.
  [ -n "$bindings" ]
  [ "${#failures[@]}" -eq 0 ] || {
    printf 'inert binding: %s\n' "${failures[@]}" >&2
    return 1
  }
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
  wait_for_idle 60
  run demo_api POST /demo-api/runs "$SUPERADMIN_TOKEN" '{"step":"1"}'
  [ "$output" = "202" ]
  run body_field run_id
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ─── The read routes are split by audience, and BOTH halves are asserted ─────
#
# ISC-17 ("/status with a non-superadmin token returns 403") and ISC-45 ("a
# non-superadmin sees phase status") read as a contradiction. They are not one:
# ISC-45's "non-superadmin" is the dashboard's client-side visibility flag,
# whose holder still carries a full superadmin token, while ISC-17's is a
# genuinely different identity. The resolution, recorded in the ISA's Decisions
# section on 2026-08-04, splits the read routes by audience:
#
#   superadmin only  /status            run history of a mutating control plane
#                    /runs/{id}/log     raw script stdout/stderr
#   any authenticated  /steps           a static phase list
#                      /runs/{id}       one phase's status
#
# The half that is CLOSED is asserted above. This asserts the half that is
# deliberately OPEN, so a future tightening cannot quietly break ISC-45 while
# every test stays green — and so the split is legible here rather than only in
# prose someone has to find.

@test "DEMOAPI a NON-superadmin can still read the phase list and a phase's status" {
  # The preceding test starts a run and does not await it; without this the
  # POST below lands on a busy runner and answers 409, not 202.
  wait_for_idle 60
  start="$(demo_api POST /demo-api/runs "$SUPERADMIN_TOKEN" '{"step":"1"}')"
  [ "$start" = "202" ]
  run_id="$(body_field run_id)"
  [ -n "$run_id" ]

  # Open: this is what the panel renders for a non-superadmin (ISC-45).
  run demo_api GET /demo-api/steps "$VIEWER_TOKEN"
  [ "$output" = "200" ]
  run demo_api GET "/demo-api/runs/${run_id}" "$VIEWER_TOKEN"
  [ "$output" = "200" ]

  # Closed: raw script output is the literal subject of the design constraint
  # "run/reset controls and raw step logs are superadmin-only".
  run demo_api GET "/demo-api/runs/${run_id}/log?offset=0" "$VIEWER_TOKEN"
  [ "$output" = "403" ]
  run error_code
  [ "$output" = "superadmin_required" ]
}

@test "DEMOAPI the gated read routes answer 401 before 403 when unauthenticated" {
  # Ordering matters: a 403 to an anonymous caller would confirm the existence
  # of an authorization boundary to someone who has not authenticated at all.
  run demo_api GET /demo-api/status
  [ "$output" = "401" ]
  run demo_api GET "/demo-api/runs/does-not-exist/log?offset=0"
  [ "$output" = "401" ]
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
  #
  # The allowlist is {offset, wait}, and each entry has to earn its place:
  #   offset — a byte position in the run log. Not a credential.
  #   wait   — long-poll duration in seconds, added by f39e35d when the waiting
  #            log moved onto the live transport. Not a credential.
  # A new parameter appearing here SHOULD fail this test until someone states
  # why it is safe. That is the point of the allowlist, so keep it explicit
  # rather than relaxing the comparison.
  #
  # Comments are stripped before scanning. Without that, the doc block above
  # isLiveTransport matched on its own prose — it documents `?logTransport=sse`
  # as something a HUMAN may put on the page URL, which the client READS via
  # URLSearchParams and never builds. A guard that fires on its own
  # documentation gets muted, and a muted security guard is worse than none.
  # Drop only lines that are ENTIRELY comment — a leading `*` (JSDoc
  # continuation) or a leading `//`. A range delete from /* to */ was the first
  # attempt and it swallowed the file: the ranges nest and pair wrongly across a
  # file with both a leading doc block and inline ones, and the parameter set
  # came back empty, which would have passed a laxer assertion while checking
  # nothing at all.
  params="$(grep -vE '^[[:space:]]*(\*|//|/\*)' \
      "${BATS_TEST_DIRNAME}/../apps/dashboard-signalloom/src/api/demoRunner.ts" \
    | grep -oE '[?&][A-Za-z_][A-Za-z0-9_]*=' \
    | tr -d '?&=' | sort -u | tr '\n' ' ')"
  [ "$params" = "offset wait " ] || {
    echo "query parameters the client builds: [${params}]" >&2
    echo "expected exactly [offset wait ] — a new one must be justified above" >&2
    return 1
  }

  # And the token is passed as a header, on every call that carries one.
  run grep -c 'Authorization: `Bearer' "${BATS_TEST_DIRNAME}/../apps/dashboard-signalloom/src/api/demoRunner.ts"
  [ "$output" -ge 1 ]
}
