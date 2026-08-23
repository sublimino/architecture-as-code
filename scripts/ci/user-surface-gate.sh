#!/usr/bin/env bash
#
# Post-deploy user-surface acceptance gate.
#
# Drives every user-facing demo surface through the SAME URL a human uses, and
# fails the deploy when any of them is not actually usable.
#
# ═══ Why this exists ════════════════════════════════════════════════════════
#
# On 2026-08-23 the demo lane scored 29/29 PASS while BOTH shipped demos were
# dead at the URL the principal opens. Measured, not inferred:
#
#     POST /api/demo/supercred/runs    -> 503 demo_root_unresolved
#     POST /api/demo/signalfusion/runs -> 503 demo_root_unresolved
#     GET  /api/demo/<either>/status   -> 200 {"script_available":false}
#
# Nothing in the 29 stages could see it. Of those stages exactly one drove a
# browser, and the pipeline's own notion of the demo is
# `http://${DASHBOARD_HOSTNAME}:${DASHBOARD_LOCAL_PORT}/` — a port-forward to
# localhost. The suite proved the estate CONVERGED. It never proved the product
# WORKED. This gate closes precisely that gap and nothing wider.
#
# ═══ The four design rules, each tied to how we got here ════════════════════
#
# 1. REAL SURFACE. The base URL is the lane's tailnet origin. No 127.0.0.1, no
#    port-forward, no stub, no fixture. A gate that can pass against localhost
#    cannot see a Gateway/HTTPRoute defect, and an HTTPRoute defect is exactly
#    what was wrong: there is no /api/demo rule, so the generic /api rule
#    swallows both demos into a backend with no scripts and no kubectl.
#
# 2. DERIVED ENUMERATION. Surfaces come from demo_runner.DEMO_CONFIGS via
#    scripts/ci/demo-surface-registry.py, never from a list in this file. A new
#    demo is covered the moment it is servable. See that script's header for why
#    a hand-written list is the one thing this gate must not contain.
#
# 3. COMPLETION, NOT 200. /weave returns 200 while every act 503s, so HTTP 200
#    is not evidence. Readiness mode asserts the runner reports itself CAPABLE
#    (script_available) and enumerates steps; --execute additionally drives a
#    real run to the terminal state `succeeded`.
#
# 4. FOUR VERDICTS, NOT TWO. "not deployed" and "deployed but broken" need
#    different people and different fixes, so 404, 401/403, 5xx, 200-with-error
#    and 200-with-success are reported as distinct outcomes. The operator must
#    learn WHICH demo is broken and IN WHICH WAY from this run, not from a
#    browser afterwards.
#
# ═══ Readiness vs execute ═══════════════════════════════════════════════════
#
# Default is READINESS: strictly non-mutating (GETs only). It is the safe mode
# for a live demo lane, and it is sufficient to catch both defects above, both
# of which surface as script_available=false.
#
# --execute additionally POSTs a run and polls it to a terminal state. That
# MUTATES the cluster — supercred step 1 deploys workloads, seeds OpenBao and
# registers a SPIRE entry — so it is opt-in and belongs in disposable CI lanes,
# never by default against the URL someone may be presenting from.
#
# Readiness alone does NOT prove a demo completes. That limit is stated in the
# summary line of every readiness run rather than left for a reader to infer.
#
# Exit: 0 all surfaces pass · 1 at least one surface failed · 2 gate could not run.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

REGISTRY_SOURCE="${REGISTRY_SOURCE:-${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/src/demo_runner.py}"
REGISTRY_TOOL="${REGISTRY_TOOL:-${SCRIPT_DIR}/demo-surface-registry.py}"

BASE_URL="${USER_SURFACE_BASE_URL:-}"
DEMO_USER="${USER_SURFACE_USER:-demo-user@signalloom.local}"
DEMO_PASS="${USER_SURFACE_PASS:-demo-user}"
DEX_CLIENT="${USER_SURFACE_CLIENT:-signalloom-dashboard}"
CURL_TIMEOUT="${USER_SURFACE_CURL_TIMEOUT:-30}"
RUN_TIMEOUT="${USER_SURFACE_RUN_TIMEOUT:-900}"
EXECUTE=0
ONLY_DEMO=""
EXEC_STEP="${USER_SURFACE_STEP:-1}"

while [ $# -gt 0 ]; do
  case "$1" in
    --base-url) BASE_URL="$2"; shift 2 ;;
    --execute)  EXECUTE=1; shift ;;
    --demo)     ONLY_DEMO="$2"; shift 2 ;;
    --step)     EXEC_STEP="$2"; shift 2 ;;
    -h|--help)  sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "user-surface-gate: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$BASE_URL" ]; then
  echo "user-surface-gate: no base URL." >&2
  echo "  Pass --base-url https://<node>.<tailnet>.ts.net or set USER_SURFACE_BASE_URL." >&2
  echo "  This gate has no localhost default ON PURPOSE: a localhost run cannot" >&2
  echo "  observe the Gateway/HTTPRoute layer, which is where both known demo" >&2
  echo "  outages actually lived." >&2
  exit 2
fi
BASE_URL="${BASE_URL%/}"

# ─── Helpers ────────────────────────────────────────────────────────────────

# Emit `<http_code>\n<body>`. Never fails the script: a transport error is a
# verdict (UNREACHABLE), not a crash, and must be reported per-surface.
http() {
  local method="$1" path="$2" token="$3" body="$4"
  local args=(-sk -o /dev/stdout -w '\n%{http_code}' --max-time "$CURL_TIMEOUT" -X "$method")
  [ -n "$token" ] && args+=(-H "Authorization: Bearer ${token}")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl "${args[@]}" "${BASE_URL}${path}" 2>/dev/null
}

# Pull one JSON field. Prints nothing when the body is not JSON or the key is
# absent — callers treat empty as "unknown", never as a value.
#
# Values are re-serialised as JSON, strings alone printed raw. This is not
# cosmetic. The first draft printed Python's repr, so a WORKING demo returned
# `True`, which compares unequal to the JSON `true` every caller tests against
# — a gate permanently stuck RED, which is exactly as useless as one stuck
# GREEN and far more likely to get switched off. Caught by asking what this
# would print once the demos were fixed, not by seeing it fail.
jfield() {
  python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for k in sys.argv[1].split("."):
    if not isinstance(d,dict) or k not in d: sys.exit(0)
    d=d[k]
print("" if d is None else (d if isinstance(d,str) else json.dumps(d)))
' "$1" 2>/dev/null
}

log()  { printf '%s\n' "$*"; }
fail_detail() { printf '        %s\n' "$*"; }

# ─── Token ──────────────────────────────────────────────────────────────────
#
# The audience scope is load-bearing: without
# `audience:server:client_id:signalloom-api` Dex mints an id_token with
# aud=signalloom-dashboard and the API rejects it. That would turn every
# surface below into a 401 and report a total outage that is really a bad
# token — a whole-estate false RED, which erodes trust in this gate as surely
# as a false GREEN does.
mint_token() {
  curl -sk --max-time "$CURL_TIMEOUT" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "client_id=${DEX_CLIENT}" \
    --data-urlencode "username=${DEMO_USER}" \
    --data-urlencode "password=${DEMO_PASS}" \
    --data-urlencode 'scope=openid profile email groups audience:server:client_id:signalloom-api' \
    "${BASE_URL}/dex/token" 2>/dev/null | jfield id_token
}

log "════ POST-DEPLOY USER-SURFACE GATE ═══════════════════════════════════"
log "  base URL : ${BASE_URL}"
log "  mode     : $([ "$EXECUTE" -eq 1 ] && echo 'EXECUTE (drives real runs — mutates the cluster)' || echo 'READINESS (non-mutating GETs)')"
log "  registry : ${REGISTRY_SOURCE#"${REPO_ROOT}/"}"
log ""

# ─── Enumerate ──────────────────────────────────────────────────────────────
registry_out="$(python3 "$REGISTRY_TOOL" "$REGISTRY_SOURCE" 2>&1)"
if [ $? -ne 0 ] || [ -z "$registry_out" ]; then
  log "GATE CANNOT RUN: demo surface enumeration failed."
  log "$registry_out"
  log ""
  log "This is a hard stop, not a pass. A gate that cannot list the surfaces it"
  log "guards must never report success over an empty set."
  exit 2
fi

demo_count="$(printf '%s\n' "$registry_out" | wc -l | tr -d ' ')"
log "Enumerated ${demo_count} demo surface(s) from the registry:"
printf '%s\n' "$registry_out" | while IFS=$'\t' read -r t l _; do log "  · ${l} (/api/demo/${t})"; done
log ""

TOKEN="$(mint_token)"
if [ -z "$TOKEN" ]; then
  log "GATE CANNOT RUN: could not mint a Dex token at ${BASE_URL}/dex/token"
  log "  user: ${DEMO_USER}  client: ${DEX_CLIENT}"
  log ""
  log "Reported as CANNOT-RUN rather than as every-demo-broken: a bad token"
  log "makes all surfaces 401 at once, and a gate that calls that a product"
  log "outage teaches its operator to disbelieve it."
  exit 2
fi
log "Dex token minted (${#TOKEN} chars) — probing surfaces as ${DEMO_USER}"
log ""

# ─── Probe one surface ──────────────────────────────────────────────────────
#
# Prints `VERDICT` on the last line; detail goes to stdout above it.
probe_demo() {
  local demo_type="$1" label="$2"
  local resp code body

  resp="$(http GET "/api/demo/${demo_type}/status" "$TOKEN" "")"
  code="$(printf '%s' "$resp" | tail -n1)"
  body="$(printf '%s' "$resp" | sed '$d')"

  case "$code" in
    000) fail_detail "transport failure reaching ${BASE_URL}/api/demo/${demo_type}/status"
         echo UNREACHABLE; return ;;
    404) fail_detail "GET /api/demo/${demo_type}/status -> 404"
         fail_detail "the route does not exist at this origin — the demo is NOT DEPLOYED,"
         fail_detail "or no HTTPRoute sends this path to a backend that serves it."
         echo NOT_DEPLOYED; return ;;
    401|403)
         fail_detail "GET /api/demo/${demo_type}/status -> ${code} with a valid superadmin token"
         fail_detail "$(printf '%s' "$body" | head -c 200)"
         echo UNAUTHORIZED; return ;;
    5*)  fail_detail "GET /api/demo/${demo_type}/status -> ${code}"
         fail_detail "error code: $(printf '%s' "$body" | jfield error.code)"
         fail_detail "$(printf '%s' "$body" | jfield error.message | head -c 300)"
         echo BROKEN; return ;;
    200) : ;;
    *)   fail_detail "GET /api/demo/${demo_type}/status -> unexpected ${code}"
         echo BROKEN; return ;;
  esac

  # 200 is where the last outage lived. Everything below this line is the
  # difference between "the page loaded" and "the demo works".
  local available
  available="$(printf '%s' "$body" | jfield script_available)"
  if [ "$available" != "true" ]; then
    fail_detail "GET /api/demo/${demo_type}/status -> 200, but script_available=${available:-<absent>}"
    fail_detail "the surface answers and reports itself INCAPABLE of running the demo."
    fail_detail "this is the 200-with-an-error-inside case: a browser shows a page,"
    fail_detail "every act fails. Usual causes: the *_DEMO_CWD env var is unset on the"
    fail_detail "serving pod, the demo script is absent from its image, or the request"
    fail_detail "is being routed to a backend that has neither."
    echo BROKEN; return
  fi

  # Steps must enumerate: a capable runner with no steps is a demo a human
  # cannot drive, and it would otherwise pass every check above.
  resp="$(http GET "/api/demo/${demo_type}/steps" "$TOKEN" "")"
  code="$(printf '%s' "$resp" | tail -n1)"
  body="$(printf '%s' "$resp" | sed '$d')"
  local nsteps
  nsteps="$(printf '%s' "$body" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("steps") or []))
except Exception: print(0)' 2>/dev/null)"
  if [ "$code" != "200" ] || [ "${nsteps:-0}" -lt 1 ]; then
    fail_detail "GET /api/demo/${demo_type}/steps -> ${code}, ${nsteps:-0} step(s)"
    fail_detail "the demo advertises no acts, so there is nothing a human could run."
    echo BROKEN; return
  fi
  fail_detail "status 200, script_available=true, ${nsteps} step(s) enumerated"

  if [ "$EXECUTE" -ne 1 ]; then
    echo READY; return
  fi

  # ─── Execute: the only mode that proves COMPLETION ────────────────────────
  resp="$(http POST "/api/demo/${demo_type}/runs" "$TOKEN" "{\"step\":\"${EXEC_STEP}\"}")"
  code="$(printf '%s' "$resp" | tail -n1)"
  body="$(printf '%s' "$resp" | sed '$d')"
  if [ "$code" != "202" ]; then
    fail_detail "POST /api/demo/${demo_type}/runs {step:${EXEC_STEP}} -> ${code}"
    fail_detail "error code: $(printf '%s' "$body" | jfield error.code)"
    fail_detail "$(printf '%s' "$body" | jfield error.message | head -c 300)"
    echo BROKEN; return
  fi

  local run_id deadline status
  run_id="$(printf '%s' "$body" | jfield run_id)"
  [ -z "$run_id" ] && run_id="$(printf '%s' "$body" | jfield id)"
  if [ -z "$run_id" ]; then
    fail_detail "run accepted (202) but no run id in the response body — cannot poll to completion"
    echo BROKEN; return
  fi
  fail_detail "run ${run_id} accepted; polling to a terminal state (max ${RUN_TIMEOUT}s)"

  deadline=$(( SECONDS + RUN_TIMEOUT ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 5
    resp="$(http GET "/api/demo/${demo_type}/runs/${run_id}" "$TOKEN" "")"
    code="$(printf '%s' "$resp" | tail -n1)"
    body="$(printf '%s' "$resp" | sed '$d')"
    [ "$code" != "200" ] && continue
    status="$(printf '%s' "$body" | jfield status)"
    case "$status" in
      running) continue ;;
      succeeded)
        fail_detail "run ${run_id} reached terminal state: succeeded"
        echo PASS; return ;;
      failed|cancelled|timed_out)
        fail_detail "run ${run_id} reached terminal state: ${status}"
        fail_detail "exit_code=$(printf '%s' "$body" | jfield exit_code) error=$(printf '%s' "$body" | jfield error | head -c 200)"
        fail_detail "the demo STARTED and did not complete — deployed, reachable, broken at runtime."
        echo RAN_FAILED; return ;;
      *) continue ;;
    esac
  done
  fail_detail "run ${run_id} still not terminal after ${RUN_TIMEOUT}s — treated as a failure"
  echo RAN_TIMEOUT
}

# ─── Drive every surface ────────────────────────────────────────────────────
#
# A pipe would put this loop in a subshell and lose the counters, which is a
# classic way for a gate to always exit 0. Read from a here-string instead.
failures=0
checked=0
summary=""

while IFS=$'\t' read -r demo_type label _script; do
  [ -z "$demo_type" ] && continue
  if [ -n "$ONLY_DEMO" ] && [ "$demo_type" != "$ONLY_DEMO" ]; then continue; fi
  checked=$(( checked + 1 ))

  log "──── ${label}  (/api/demo/${demo_type}) ────"
  out="$(probe_demo "$demo_type" "$label")"
  verdict="$(printf '%s' "$out" | tail -n1)"
  printf '%s\n' "$(printf '%s' "$out" | sed '$d')"

  case "$verdict" in
    PASS)  log "    VERDICT: PASS — ran to completion" ;;
    READY) log "    VERDICT: READY — capable and enumerable (completion NOT asserted in readiness mode)" ;;
    *)     log "    VERDICT: ${verdict} — FAILED"; failures=$(( failures + 1 )) ;;
  esac
  summary="${summary}${label}|${verdict}"$'\n'
  log ""
done <<< "$registry_out"

if [ "$checked" -eq 0 ]; then
  log "GATE CANNOT RUN: no surface matched --demo '${ONLY_DEMO}'."
  exit 2
fi

log "════ SUMMARY ═════════════════════════════════════════════════════════"
printf '%s' "$summary" | while IFS='|' read -r l v; do
  [ -z "$l" ] && continue
  case "$v" in
    PASS|READY) printf '  %-14s %s\n' "$v" "$l" ;;
    *)          printf '  %-14s %s   <<< BROKEN USER SURFACE\n' "$v" "$l" ;;
  esac
done
log ""

if [ "$failures" -ne 0 ]; then
  log "GATE FAILED: ${failures} of ${checked} user-facing demo surface(s) are not usable at ${BASE_URL}"
  log "These are the surfaces a human opens. A deploy carrying this is not shippable."
  exit 1
fi

if [ "$EXECUTE" -ne 1 ]; then
  log "GATE PASSED (readiness): ${checked}/${checked} surface(s) reachable, capable and enumerable."
  log "NOT PROVEN: that any demo runs to completion. Readiness mode issues no runs."
  log "Run with --execute in a disposable lane for a completion proof."
else
  log "GATE PASSED (execute): ${checked}/${checked} surface(s) ran step ${EXEC_STEP} to 'succeeded'."
fi
exit 0
