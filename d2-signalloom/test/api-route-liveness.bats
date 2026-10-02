#!/usr/bin/env bats
# Does the RUNNING backend have every API route the UI calls?
#
# ─── What went wrong, that this exists to catch ──────────────────────────────
#
# On 2026-08-17 the Signal Store page rendered "Failed — Request failed with
# status code 404". Every test was green. The source declared
# GET /api/signals/store/stats and had done for hours; the fe-signalloom pod
# answering the request was built before that route existed, so the running app
# had four proxy routes where the tree has five.
#
# Rebuilding fe-signalloom turned the 404 into a 502, which reads like progress
# and was not. signal-ingest — the service the portal proxies to — was ALSO
# running an image that predated its own half of the route. The page stayed
# broken. Two independently stale images, one symptom, and the second one only
# became visible after the first was fixed.
#
# This is the same class as scripts/check-deployed-staleness.sh: the code under
# test is not the code answering requests. That guard could not have caught
# either instance, because its WORKLOAD_TOPOLOGY covered only
# supercred-demo-runner and dashboard-signalloom. Both offenders here were
# outside it — fe-signalloom is now instrumented and inside it, and
# signal-ingest structurally cannot be (distroless, no shell, so the
# `kubectl exec … cat /etc/osramp-build-id` readback has nothing to run).
#
# So this suite asks the question over HTTP instead of over exec, which works
# against an image with no shell in it: not "is the deployed fingerprint equal
# to the tree's" but the thing that fingerprint is a proxy FOR — "can the
# running process actually serve what the UI is going to ask it for".
#
# ─── Why the upstream tier is a separate assertion ───────────────────────────
#
# A missing route on signal-ingest does NOT surface as a 404 at the portal. Go's
# ServeMux answers an unregistered path with the plain-text body
# `404 page not found`, and signal_fusion._proxy calls resp.json() on it. The
# JSONDecodeError falls through to the generic `except Exception` and is
# re-raised as 502 upstream_unavailable "signal-ingest proxy error".
#
# A test that only knew "404 means the route is missing" would therefore have
# passed against the genuinely broken cluster of 2026-08-17. The upstream tier
# below probes signal-ingest DIRECTLY so a missing route is read at the hop
# where it is still legible, before the proxy masks it as a connectivity fault.
#
# ─── How the upstream tier reads registration ────────────────────────────────
#
# Until signal-ingest enforced authentication, a GET probe told registered from
# missing without running a handler: 200, 405 for a POST-only route, and Go's
# plain-text `404 page not found` for an unregistered path. Behind
# api.ProtectedRouter that is gone. Authentication runs before routing, so an
# anonymous probe is 401 on every path. An authenticated GET on a POST-only
# route is 403 unregistered_route, because ServeMux reports no pattern for a
# method mismatch. And an authenticated POST runs the handler: collectors/seed
# seeds the store. That is the thing this suite must never do on a cluster that
# is usually mid-rehearsal.
#
# So the tier reads the RUNNING process's route table instead. ProtectedRouter
# logs one JSON line per route it registers, "HTTP authorization route
# registered", with the method and pattern.
# api.TestEveryRegisteredRouteIsAnnouncedInTheStartupLog pins that contract.
# A {param} segment matches any concrete segment and the method must match,
# exactly as ServeMux decides. An empty readback (the log rotated) fails
# loudly. It is never taken to mean "nothing is missing".

DEX_NS="inf-signalloom"
FE_NS="fe-signalloom"
DEX_LOCAL_PORT="${DEX_LOCAL_PORT:-15561}"
PORTAL_LOCAL_PORT="${PORTAL_LOCAL_PORT:-18001}"
ROUTE_LOG_MSG="HTTP authorization route registered"

DASH_SRC="${BATS_TEST_DIRNAME}/../apps/dashboard-signalloom/src"
SIGNAL_FUSION="${BATS_TEST_DIRNAME}/../apps/fe-signalloom/src/signal_fusion.py"

# shellcheck source=../../scripts/lib/wait.sh
source "${BATS_TEST_DIRNAME}/../../scripts/lib/wait.sh"

# Paths the dashboard calls that the portal is NOT expected to serve.
#
# An allowlist, not a filter: a path may only sit here with a reason, because
# the whole value of this suite is that an unrecognised path FAILS rather than
# being quietly skipped. Same contract as NOT_DATABASE_BACKED in
# src/tests/test_tenant_isolation.py.
#
#   /api/connectors …
#       connectorsClient.ts is a deliberately mock-first data layer for a
#       backend that lives in another repo entirely (ADR-ENHC-012, implemented
#       on services/agent_registry/routers/connectors.py). Its own header says
#       VITE_CONNECTORS_API_MODE defaults to 'mock' and is to be flipped to
#       'live' once that backend is wired. Nothing is deployed here to answer
#       it, and that is the designed state, not drift.
#
#       Exempted by PREFIX rather than as four literal paths, because the
#       reason applies to the whole client and not to the particular calls it
#       makes today. A fifth connector call is covered by the same argument;
#       making someone re-justify it would train the reflex of adding entries
#       to silence this list, which is how an allowlist stops meaning anything.
#
# When connectors goes live this entry must be DELETED, not edited — at which
# point the suite starts asserting it for real.
NOT_SERVED_BY_THE_PORTAL=(
  "/api/connectors"
)

# True when $1 is the exempt path itself or sits beneath it.
path_is_exempt() {
  local path="$1" entry
  for entry in "${NOT_SERVED_BY_THE_PORTAL[@]}"; do
    [ "$path" = "$entry" ] && return 0
    case "$path" in
    "${entry}/"*) return 0 ;;
    esac
  done
  return 1
}

portal_deployed() {
  kubectl get deployment fe-signalloom -n "$FE_NS" >/dev/null 2>&1
}

ingest_deployed() {
  kubectl get deployment signal-ingest -n "$FE_NS" >/dev/null 2>&1
}

start_forwards() {
  kubectl -n "$DEX_NS" port-forward svc/dex "${DEX_LOCAL_PORT}:5556" \
    >"$BATS_TEST_TMPDIR/dex-pf.log" 2>&1 &
  DEX_PID=$!
  kubectl -n "$FE_NS" port-forward svc/fe-signalloom "${PORTAL_LOCAL_PORT}:8000" \
    >"$BATS_TEST_TMPDIR/portal-pf.log" 2>&1 &
  PORTAL_PID=$!
  wait_tcp 127.0.0.1 "$DEX_LOCAL_PORT" 30 || { cat "$BATS_TEST_TMPDIR/dex-pf.log" >&2; return 1; }
  wait_tcp 127.0.0.1 "$PORTAL_LOCAL_PORT" 30 || { cat "$BATS_TEST_TMPDIR/portal-pf.log" >&2; return 1; }
}

teardown() {
  for pid in "${DEX_PID:-}" "${PORTAL_PID:-}"; do
    if [ -n "$pid" ]; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  unset DEX_PID PORTAL_PID
  return 0
}

# Dex password grant. signalloom-dashboard is a PUBLIC client, so client_id goes
# in the form body and not HTTP Basic; the audience scope is what makes the API
# accept the id_token. Both facts are explained at length in
# test/supercred-demo-api.bats, which this mirrors deliberately — auth is never
# bypassed to make a test easier to write.
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

# Every literal API path the dashboard's shared client is asked for.
#
# req() in api/client.ts prepends /api to any path not already carrying it, so
# the call sites are written '/signals/store/stats' and are normalised here.
# Interpolated segments (`/signals/actors/${id}`) are emitted with the
# expression replaced by a '*', and matched against the OpenAPI templates
# segment-wise below — dropping them would blind this to exactly the
# parameterised routes.
dashboard_called_paths() {
  python3 - "$DASH_SRC" <<'PY'
import os, re, sys

root = sys.argv[1]
call = re.compile(r"""req<[^>]*>\(\s*(['"`])(.+?)\1""", re.S)
found = set()
for dirpath, _, names in os.walk(root):
    for n in names:
        if not n.endswith(('.ts', '.tsx')):
            continue
        # Test files stub the transport and freely invent paths; they are not
        # statements about what the product calls.
        if '.test.' in n or dirpath.endswith('__fixtures__'):
            continue
        text = open(os.path.join(dirpath, n), encoding='utf-8').read()
        for _, path in call.findall(text):
            if not path.startswith('/'):
                continue
            path = re.sub(r'\$\{[^{}]*\}', '*', path)
            # A NESTED template literal — `/signals/observations${qs ? `?${qs}`
            # : ''}` — leaves an unbalanced ${ that the substitution above
            # cannot close, and the first version of this emitted the literal
            # garbage path '/api/signals/observations${qs' and reported it as a
            # route the backend was missing. Everything from an unclosed ${ on
            # is an expression, so the checkable path ends there.
            path = path.split('${')[0]
            path = path.split('?')[0].rstrip('/')
            if not path or path == '*':
                continue
            found.add(path if path.startswith('/api') else '/api' + path)
for p in sorted(found):
    print(p)
PY
}

# The proxy table as the working tree declares it: the portal route and the
# signal-ingest path each one forwards to.
#
# Parsed from the decorator/_proxy pair rather than hand-listed, so a route
# added tomorrow is covered without anyone remembering to add it here. A
# hand-maintained copy is the omission this whole class of bug is made of.
signal_fusion_upstreams() {
  python3 - "$SIGNAL_FUSION" <<'PY'
import re, sys

src = open(sys.argv[1], encoding='utf-8').read()
pairs = re.findall(
    r'@router\.(?:get|post)\("([^"]+)"\).*?_proxy\(\s*"(GET|POST)",\s*f?"([^"]+)"',
    src, re.S)
for portal_path, method, upstream in pairs:
    # f-string placeholders become a concrete throwaway segment: signal-ingest
    # routes them by pattern, so any non-empty value probes the same registration.
    upstream = re.sub(r'\{[^}]*\}', 'route-liveness-probe', upstream)
    print(f"{method}\t/api/signals{portal_path}\t{upstream}")
PY
}

# shellcheck source=helpers/ingest-routes.bash
source "${BATS_TEST_DIRNAME}/helpers/ingest-routes.bash"


probe_portal() {
  local path="$1" token="${2:-}"
  local args=(-sS -m 10 -o /dev/null -w '%{http_code}')
  [ -n "$token" ] && args+=(-H "Authorization: Bearer ${token}")
  curl "${args[@]}" "http://127.0.0.1:${PORTAL_LOCAL_PORT}${path}"
}

# `<status> <content-type>`, with the body left in $BATS_TEST_TMPDIR/portal-body.
#
# The status alone is not evidence that a route served data. An SPA catch-all
# answers 200 with text/html for any unmatched path, so a route deleted from the
# API and swallowed by the static handler passes a `[ "$code" = "200" ]` check
# while the page it backs shows nothing. The content type is what distinguishes
# "the API answered" from "something answered".
fetch_portal() {
  local path="$1" token="${2:-}"
  local args=(-sS -m 10 -o "$BATS_TEST_TMPDIR/portal-body" -w '%{http_code} %{content_type}')
  [ -n "$token" ] && args+=(-H "Authorization: Bearer ${token}")
  curl "${args[@]}" "http://127.0.0.1:${PORTAL_LOCAL_PORT}${path}"
}

# The RUNNING portal's own route table, read out of the process that will
# answer the UI's requests. Not the tree's — that is the whole point.
running_portal_paths() {
  curl -fsS -m 15 "http://127.0.0.1:${PORTAL_LOCAL_PORT}/openapi.json" \
    | python3 -c 'import json,sys; [print(p) for p in sorted(json.load(sys.stdin).get("paths", {}))]'
}

setup() {
  portal_deployed || skip "fe-signalloom not deployed — run: make demo-signalloom-up"
  ingest_deployed || skip "signal-ingest not deployed — run: make images-signalfusion && flux reconcile"
  start_forwards
  TOKEN="$(mint_token 'demo-user@signalloom.local' "${DEX_DEMO_PASSWORD:-demo-user}")"
  [ -n "$TOKEN" ]
}

# ─── The extractors, before anything is concluded from them ──────────────────
#
# Both sweeps below are "for each thing the extractor found, assert X". An
# extractor that finds nothing makes that a loop over an empty set, which
# passes, reports success and checks nothing — the exact shape of green this
# repo has been bitten by before (see test/no-exec-probes-in-tests.bats and the
# probe-returned-a-number guard in supercred-demo-api.bats). So the extractors
# are asserted to have worked BEFORE their output is trusted.

@test "ROUTELIVE the dashboard call-site extractor finds the client's API surface" {
  run dashboard_called_paths
  [ "$status" -eq 0 ]

  local count
  count="$(printf '%s\n' "$output" | grep -c '^/api/')"
  # 29 literal paths on 2026-08-18. The floor is deliberately well below that so
  # ordinary product churn does not fail it, while a regex that silently stops
  # matching — the realistic failure — collapses to single digits and does.
  [ "$count" -ge 20 ] || {
    echo "call-site extractor found only ${count} paths; it has stopped matching." >&2
    echo "Every sweep below is vacuous until this is fixed. Found:" >&2
    printf '%s\n' "$output" >&2
    return 1
  }

  # A named path that is known to be there, so a regex which matches SOMETHING
  # but not the shape we care about still fails.
  printf '%s\n' "$output" | grep -qx '/api/signals/store/stats' || {
    echo "extractor did not find /api/signals/store/stats, which weaveApi.ts calls" >&2
    return 1
  }
}

@test "ROUTELIVE the proxy-table extractor finds every signal_fusion route" {
  run signal_fusion_upstreams
  [ "$status" -eq 0 ]

  local count
  count="$(printf '%s\n' "$output" | grep -c '^\(GET\|POST\)')"
  [ "$count" -ge 8 ] || {
    echo "proxy-table extractor found only ${count} routes in signal_fusion.py." >&2
    printf '%s\n' "$output" >&2
    return 1
  }

  # The route this suite was written for, and its upstream. If the parse ever
  # drifts, it must not drift silently past this one.
  printf '%s\n' "$output" \
    | grep -q "^GET	/api/signals/store/stats	/api/v1/store/stats$" || {
    echo "proxy table is missing GET /api/signals/store/stats -> /api/v1/store/stats" >&2
    printf '%s\n' "$output" >&2
    return 1
  }
}

# ─── Tier 1: the portal ──────────────────────────────────────────────────────

@test "ROUTELIVE every path the dashboard calls is registered on the RUNNING portal" {
  local running called missing=() path
  running="$(running_portal_paths)"
  [ -n "$running" ]

  called="$(dashboard_called_paths)"
  [ -n "$called" ]

  while IFS= read -r path; do
    [ -n "$path" ] || continue

    path_is_exempt "$path" && continue

    # An interpolated call site matches an OpenAPI template positionally: same
    # segment count, and every literal segment equal. '/api/signals/actors/*'
    # matches '/api/signals/actors/{actor_id}' and nothing shorter.
    printf '%s\n' "$running" | python3 -c '
import sys
want = sys.argv[1].strip("/").split("/")
for line in sys.stdin:
    have = line.strip().strip("/").split("/")
    if len(have) != len(want):
        continue
    if all(w == "*" or h.startswith("{") or h == w for h, w in zip(have, want)):
        sys.exit(0)
sys.exit(1)' "$path" || missing+=("$path")
  done <<<"$called"

  [ "${#missing[@]}" -eq 0 ] || {
    echo "The dashboard calls these paths; the RUNNING fe-signalloom does not serve them:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo >&2
    echo "Either the pod predates the route (rebuild + roll: make images-signalloom" >&2
    echo "then kubectl -n ${FE_NS} rollout restart deploy/fe-signalloom), or the" >&2
    echo "client calls something no backend has. Check which before assuming:" >&2
    echo "  make check-deployed-staleness" >&2
    return 1
  }
}

@test "ROUTELIVE the running portal's declared routes actually answer" {
  # OpenAPI is a declaration, and this suite exists because declarations and
  # behaviour diverge. These are the read routes the Signal Store and Weave
  # pages issue on load; all are side-effect free, and each is asserted to be
  # reachable with a real token rather than merely listed.
  local path code
  for path in /api/signals/store/stats /api/signals/observations \
              /api/signals/actors /api/signals/coverage; do
    code="$(probe_portal "$path" "$TOKEN")"
    [ "$code" != "404" ] || {
      echo "$path is in the running OpenAPI but answers 404" >&2
      return 1
    }
    # 502 is how a missing UPSTREAM route reaches the caller (see header). It is
    # a pass for "the portal has the route" and a failure for the page, so it is
    # called out here rather than folded into a catch-all.
    [ "$code" != "502" ] || {
      echo "$path answers 502 — the portal has the route but signal-ingest does not." >&2
      echo "See the upstream tier below; rebuild signal-ingest: make images-signalfusion" >&2
      return 1
    }
    [ "$code" = "200" ] || {
      echo "$path answered ${code} with a valid superadmin token" >&2
      return 1
    }
  done

  # And the answer is JSON of the right shape, not merely a 200.
  #
  # A 200 proves something replied. The dashboard's catch-all serves index.html
  # with text/html for any path it does not recognise, so a route that vanished
  # from the API and fell through to the static handler would satisfy every
  # assertion above while the Signal Store page rendered nothing. The content
  # type separates "the API answered" from "something answered"; the key shape
  # separates "the API answered" from "the API answered with an empty fallback".
  local ct
  read -r code ct <<<"$(fetch_portal /api/signals/store/stats "$TOKEN")"
  [ "$code" = "200" ]
  case "$ct" in
  application/json*) ;;
  *)
    echo "/api/signals/store/stats answered 200 with content-type '${ct}'." >&2
    echo "Not JSON — this is the SPA catch-all or an error page, not the API." >&2
    return 1
    ;;
  esac

  # StoreStats as weaveApi.ts declares it. Asserted on the KEYS, not on values:
  # a freshly-rolled store legitimately holds zero observations, so requiring
  # non-zero counts would fail on a correct cluster. A missing key means the
  # upstream shape changed under the client, which the page cannot survive.
  python3 - "$BATS_TEST_TMPDIR/portal-body" <<'PY' || return 1
import json, sys

required = {
    "total_observations", "observations_by_layer", "observations_by_fidelity",
    "actor_count", "actors_by_status", "last_ingestion", "store_type",
}
try:
    body = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as exc:
    print(f"store/stats body is not JSON: {exc}", file=sys.stderr)
    sys.exit(1)
if not isinstance(body, dict):
    print(f"store/stats returned {type(body).__name__}, not an object", file=sys.stderr)
    sys.exit(1)
missing = required - set(body)
if missing:
    print(f"store/stats is missing StoreStats keys: {sorted(missing)}", file=sys.stderr)
    print(f"got: {sorted(body)}", file=sys.stderr)
    sys.exit(1)
# The counts must be numbers. A string or null here renders as NaN on the page
# and is the shape of a fallback stub rather than a real reading.
for key in ("total_observations", "actor_count"):
    if not isinstance(body[key], int):
        print(f"store/stats {key} is {body[key]!r}, not an integer", file=sys.stderr)
        sys.exit(1)
PY
}

@test "ROUTELIVE the portal still refuses these routes without a token" {
  # A registration probe that authenticated would be a fine way to prove the
  # route exists and simultaneously delete the reason it is gated. Both halves
  # are asserted so this suite can never be the thing that relaxes auth.
  local path code
  for path in /api/signals/store/stats /api/signals/observations; do
    code="$(probe_portal "$path")"
    [ "$code" = "401" ] || {
      echo "$path answered ${code} unauthenticated; expected 401" >&2
      return 1
    }
  done
}

# ─── Tier 2: the upstream the portal proxies to ──────────────────────────────

# The live route table, or a loud failure. An empty readback must never be read
# as "nothing is missing" — that is a loop over the empty set.
ingest_routes_or_fail() {
  INGEST_ROUTES="$(running_ingest_routes)"
  [ -n "$INGEST_ROUTES" ] || {
    echo "signal-ingest's log holds no '${ROUTE_LOG_MSG}' lines: the startup log has" >&2
    echo "rotated, or the running image predates ProtectedRouter. Cannot tell which routes" >&2
    echo "it serves. Restart it to re-announce: kubectl -n ${FE_NS} rollout restart deploy/signal-ingest" >&2
    return 1
  }
}

@test "ROUTELIVE every upstream path the portal proxies to is registered on the RUNNING signal-ingest" {
  local table missing=() method portal upstream
  table="$(signal_fusion_upstreams)"
  [ -n "$table" ]
  ingest_routes_or_fail

  while IFS=$'\t' read -r method portal upstream; do
    [ -n "$upstream" ] || continue
    [ "$(ingest_route_absent "$method" "$upstream" "$INGEST_ROUTES")" = absent ] &&
      missing+=("${method} ${upstream}  (proxied from ${portal})")
  done <<<"$table"

  [ "${#missing[@]}" -eq 0 ] || {
    echo "The portal proxies to these paths; the RUNNING signal-ingest has no such route:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo >&2
    echo "Behind ProtectedRouter an authenticated request to an unregistered route is" >&2
    echo "403 unregistered_route. Rebuild, publish and roll:" >&2
    echo "  make -C d2-signalloom signal-ingest-image-publish && flux reconcile kustomization apps -n ${FE_NS}" >&2
    return 1
  }
}

# ─── Can these probes see a missing route at all? ────────────────────────────

@test "ROUTELIVE the probes detect an absent route rather than passing regardless" {
  # Falsification. Every assertion above concludes "no route was missing", and
  # the cheapest way to reach that conclusion is for the probe to have stopped
  # working. A synthetic path that is definitely not registered must be seen as
  # missing by the same code paths the sweeps use, or those sweeps prove nothing.
  local absent="/api/v1/route-liveness-falsification-$$"
  ingest_routes_or_fail

  local verdict
  verdict="$(ingest_route_absent GET "$absent" "$INGEST_ROUTES")"
  [ "$verdict" = "absent" ] || {
    echo "an unregistered path on signal-ingest was judged '${verdict}'." >&2
    echo "The upstream sweep cannot see a missing route, so its clean result" >&2
    echo "is not evidence that the routes are present." >&2
    return 1
  }

  # The method is part of the registration: correlate is POST-only, so a POST
  # reads present and a GET reads absent. If both read the same, the sweep is
  # ignoring the method and would pass a route registered under the wrong verb.
  [ "$(ingest_route_absent POST /api/v1/correlate "$INGEST_ROUTES")" = present ] &&
    [ "$(ingest_route_absent GET /api/v1/correlate "$INGEST_ROUTES")" = absent ] || {
    echo "POST/GET /api/v1/correlate were not told apart by method." >&2
    return 1
  }

  # And the discrimination that the first version of this suite got wrong: a
  # parameterised pattern must match a concrete segment. Without this, the
  # sweep reports every parameterised route as missing — which is exactly how
  # it failed on 2026-08-18.
  verdict="$(ingest_route_absent GET /api/v1/actors/route-liveness-probe "$INGEST_ROUTES")"
  [ "$verdict" = "present" ] || {
    echo "GET /api/v1/actors/<unknown> was judged '${verdict}', expected 'present'." >&2
    echo "That path IS a registered pattern. Judging it absent makes every" >&2
    echo "parameterised route a false positive and this suite unusable." >&2
    return 1
  }

  # The portal side of the same question: the OpenAPI readback must not report
  # a path it was never given.
  running_portal_paths | grep -qx "$absent" && {
    echo "the running portal reported a synthetic path as one of its routes" >&2
    return 1
  }

  return 0
}
