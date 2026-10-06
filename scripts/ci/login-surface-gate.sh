#!/usr/bin/env bash
#
# Login-surface gate — can a HUMAN actually sign in at this origin?
#
# ═══ Why this exists ════════════════════════════════════════════════════════
#
# Twice now the principal has been the detector. Both times the lane was green
# on every check the estate owns, and both times the browser said:
#
#     Unregistered redirect_uri ("https://sl-demo-1.taild4da3.ts.net/callback")
#
# Nothing in the 29-stage suite could see it, and neither could the post-deploy
# user-surface gate, which is the closest thing we had. That is not an oversight
# in either — it follows from what they measure:
#
#   the 29 stages    assert over 127.0.0.1 ON the VM. The tailnet origin is a
#                    separate path that nothing in them depends on.
#   user-surface     mints its token with the DEX PASSWORD GRANT
#   -gate            (scripts/ci/user-surface-gate.sh § mint_token). The
#                    password grant never sends a redirect_uri, so Dex never
#                    validates one. The gate gets a perfectly good token from a
#                    Dex whose browser login is completely broken, and every
#                    surface below it then passes.
#
# So the estate had 30-odd checks, all green, and not one of them drove the
# authorisation-code path a browser uses. This gate drives exactly that path and
# nothing wider.
#
# ═══ A 200 on `/` is not evidence ═══════════════════════════════════════════
#
# It was 200 throughout both outages, and it is the check an operator reaches
# for first. The dashboard is served by nginx; Dex is a different pod behind the
# same origin. `/` proves nginx is up. It says nothing about whether the identity
# provider agrees about what origin it is serving. This gate never consults it as
# evidence of anything except reachability.
#
# ═══ The two assertions, and why BOTH ═══════════════════════════════════════
#
#   1. ISSUER MATCH.  /dex/.well-known/openid-configuration `.issuer` must equal
#      `<origin>/dex`. The SPA builds its OIDC authority as
#      `${window.location.origin}/dex` (see oidc.tsx) and VALIDATES the ID
#      token's `iss` against it. A mismatch here is a login that accepts the
#      password and then silently rejects the token — strictly harder to
#      diagnose than a redirect refusal.
#
#   2. CALLBACK REGISTERED.  GET /dex/auth with the real client_id and the real
#      `<origin>/callback` must not be refused with `Unregistered redirect_uri`.
#      This is the literal failure the principal saw, asserted literally.
#
# They are asserted SEPARATELY even though today they move together — both are
# templated from the same PUBLIC_ORIGIN, so a released origin breaks both at
# once. They can diverge: `_dex_origin_write` patches flux-system and each
# tenant copy in separate calls and tolerates failure on the tenant ones, so a
# half-written origin is reachable state. A gate that checked only one of them
# would report a half-broken login as healthy.
#
# ═══ Four states, never collapsed ═══════════════════════════════════════════
#
#   TAILNET_UNREACHABLE  nothing answers at this origin. The node is off the
#                        tailnet, or the name is wrong. Nobody's login is
#                        broken; the lane is not there. Different person,
#                        different fix.
#   DEX_DOWN             the origin answers but Dex does not serve discovery.
#                        nginx is up and the identity provider is gone or
#                        crash-looping. This is the 502-with-a-valid-serve-config
#                        shape: the URL is live and serves nothing behind /dex.
#   ORIGIN_NOT_CLAIMED   Dex is healthy and serving a DIFFERENT origin than the
#                        one being used. THIS is the outage. The repair is
#                        scripts/lib/dex-origin.sh apply tailscale <origin>.
#   WORKING              issuer matches and the callback is accepted.
#
# Collapsing these into pass/fail is what makes a red gate get switched off: an
# operator told "login broken" about a lane that was never deployed learns to
# disbelieve the gate. The verdict names who has to do what.
#
# ═══ The trap this gate is most likely to fall into ═════════════════════════
#
# Assertion 2 is NEGATIVE — "the body must not contain Unregistered
# redirect_uri". An empty body does not contain it either. So a transport
# failure, a 502, a dead Dex or a typo'd hostname all satisfy assertion 2
# vacuously, and the gate would report a login that has never worked as
# WORKING. That is the exact inversion that makes negative assertions dangerous:
# it passes HARDEST when the subject is most absent.
#
# The ordering below is therefore load-bearing and not stylistic. Reachability
# and Dex health are established as PRE-CONDITIONS, and each returns its own
# verdict, so the negative assertion is only ever evaluated against a response
# that provably came from a live Dex. `assert_callback_registered` additionally
# refuses to render a verdict on a non-200 it was not given a reason for.
# test/terraform-login-surface-gate.bats pins this with a transport-failure case
# whose whole purpose is that it must NOT come back WORKING.
#
# ═══ Read-only, always ══════════════════════════════════════════════════════
#
# Every request is a GET. Nothing here mints a token, completes a login, or
# mutates the cluster, so it is safe against the origin someone is presenting
# from. `/dex/auth` is a read: Dex validates the request and returns either the
# login form or a refusal, and this gate never posts credentials to it.
#
# Exit: 0 WORKING · 1 the login is broken · 2 the gate could not run.

set -o pipefail

# ── Injectable boundaries ────────────────────────────────────────────
#
# Defaults, not requirements. curl is the only external dependency and it is
# overridable, which is what lets the whole verdict lattice be tested with no
# cluster, no tailnet and no network at all.
LOGIN_GATE_CURL="${LOGIN_GATE_CURL:-curl}"
LOGIN_GATE_TIMEOUT="${LOGIN_GATE_TIMEOUT:-20}"
LOGIN_GATE_CLIENT="${LOGIN_GATE_CLIENT:-signalloom-dashboard}"

# The callback path the SPA registers. Overridable for ONE reason: pointing it
# at a path the cluster has not registered is how this gate is proven RED
# against a real, healthy, unmodified lane — Dex answers with the identical 400
# it answers with when the origin has been released. See the bats suite.
LOGIN_GATE_CALLBACK_PATH="${LOGIN_GATE_CALLBACK_PATH:-/callback}"

# The literal Dex refuses with. Captured from a live Dex on 2026-08-24, not
# guessed:
#     HTTP 400, body: Unregistered redirect_uri (&#34;https://...&#34;).
# Note the HTML-escaped quotes — matching the full quoted string would never
# fire. This matches the prefix only, which is stable across Dex versions.
LOGIN_GATE_UNREGISTERED='Unregistered redirect_uri'

BASE_URL="${LOGIN_GATE_BASE_URL:-}"
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base-url) BASE_URL="$2"; shift 2 ;;
    --quiet)    QUIET=1; shift ;;
    -h|--help)  sed -n '2,90p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "login-surface-gate: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$BASE_URL" ]; then
  echo "login-surface-gate: no base URL." >&2
  echo "  Pass --base-url https://<node>.<tailnet>.ts.net or set LOGIN_GATE_BASE_URL." >&2
  echo "  There is no localhost default ON PURPOSE: the origin IS the subject" >&2
  echo "  here. A gate that defaults to somewhere else asserts about the wrong" >&2
  echo "  Dex and reports the wrong answer confidently." >&2
  exit 2
fi
BASE_URL="${BASE_URL%/}"

log()    { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

# STDERR, and that is not a style choice. Every assert_* function below is
# called as `verdict="$(assert_x)"`, so ANY stdout it produces becomes part of
# the verdict string. The first live run of this gate printed its reachability
# detail on stdout and came back with a verdict of
# "        GET / -> 200 (reachability only...)" — non-empty, therefore treated
# as a failure, so a WORKING lane reported FAILED. Diagnostics and verdicts
# cannot share a channel when one of them is captured.
detail() { [ "$QUIET" -eq 1 ] || printf '        %s\n' "$*" >&2; }

# ── One request ──────────────────────────────────────────────────────
#
# Emits the body, then a final line holding the HTTP status. A transport failure
# is `000` and is a VERDICT, never a crash — which is why this never returns
# non-zero and why callers read the status line rather than `$?`.
#
# `-L` because a working /dex/auth 302s to the login form and the FINAL status
# is the one that means anything. `-k` because a lane inside a Let's Encrypt
# rate-limit window legitimately serves its own certificate, and refusing to
# look would report a login outage that is really a certificate wait.
fetch() {
  local path="$1"
  "$LOGIN_GATE_CURL" -sk -L -o /dev/stdout -w '\n%{http_code}' \
    --max-time "$LOGIN_GATE_TIMEOUT" "${BASE_URL}${path}" 2>/dev/null
  return 0
}

body_of() { printf '%s' "$1" | sed '$d'; }
code_of() { printf '%s' "$1" | tail -n1; }

# Pull `.issuer` out of discovery. Prints nothing when the body is not JSON or
# the key is absent — callers treat empty as UNKNOWN and never as a value, which
# is what stops a 404 HTML page from being compared as though it were an issuer.
issuer_of() {
  printf '%s' "$1" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
v=d.get("issuer") if isinstance(d,dict) else None
print(v if isinstance(v,str) else "")
' 2>/dev/null
}

# ── Pre-condition: is anything there at all? ─────────────────────────
#
# `/` is consulted HERE and only here, and only to tell "the lane is absent"
# apart from "the login is broken". It is never evidence that the login works.
assert_origin_reachable() {
  local resp code
  resp="$(fetch /)"
  code="$(code_of "$resp")"

  if [ "$code" = "000" ]; then
    detail "GET ${BASE_URL}/ -> transport failure"
    detail "nothing answers at this origin. The node is not on the tailnet, or"
    detail "this is not its name. NOBODY'S LOGIN IS BROKEN — the lane is absent."
    detail "Check with: make gcp-tf-ts-status ENV=<key>"
    echo TAILNET_UNREACHABLE
    return 1
  fi

  detail "GET / -> ${code} (reachability only — NOT evidence the login works)"
  return 0
}

# ── Assertion 1: the issuer is the origin being served ───────────────
assert_issuer_matches() {
  local resp code body iss want
  want="${BASE_URL}/dex"

  resp="$(fetch /dex/.well-known/openid-configuration)"
  code="$(code_of "$resp")"
  body="$(body_of "$resp")"

  if [ "$code" = "000" ] || [ "$code" = "502" ] || [ "$code" = "503" ] || [ "$code" = "504" ]; then
    detail "GET /dex/.well-known/openid-configuration -> ${code}"
    detail "the origin answers but Dex does not. nginx is up and the identity"
    detail "provider is gone, crash-looping, or has no backend behind /dex."
    echo DEX_DOWN
    return 1
  fi

  if [ "$code" != "200" ]; then
    detail "GET /dex/.well-known/openid-configuration -> ${code}"
    detail "Dex serves no OIDC discovery document at this origin."
    echo DEX_DOWN
    return 1
  fi

  iss="$(issuer_of "$body")"
  if [ -z "$iss" ]; then
    # 200 with a body that is not a discovery document. Reported as DEX_DOWN
    # rather than as a mismatch: comparing an unparsed page against an expected
    # issuer would name the origin mechanism for what is a routing fault.
    detail "GET /dex/.well-known/openid-configuration -> 200 with no readable .issuer"
    detail "something answers on this path and it is not Dex's discovery document."
    detail "body: $(printf '%s' "$body" | head -c 160)"
    echo DEX_DOWN
    return 1
  fi

  if [ "$iss" != "$want" ]; then
    detail "issuer MISMATCH"
    detail "  serving : ${iss}"
    detail "  expected: ${want}"
    detail "Dex is publishing a different origin than the one being used. The SPA"
    detail "validates the ID token's iss against the origin it was served from, so"
    detail "a password entered here would be accepted and the token then rejected."
    echo ORIGIN_NOT_CLAIMED
    return 1
  fi

  detail "issuer matches: ${iss}"
  return 0
}

# ── Assertion 2: the callback this origin will send is registered ────
#
# The NEGATIVE assertion, and the reason this function refuses to render a
# verdict on a response it cannot account for. See the header: an empty body
# satisfies "does not contain Unregistered redirect_uri" perfectly.
assert_callback_registered() {
  local resp code body redirect url
  redirect="${BASE_URL}${LOGIN_GATE_CALLBACK_PATH}"
  url="/dex/auth?client_id=${LOGIN_GATE_CLIENT}&redirect_uri=${redirect}&response_type=code&scope=openid+profile+email"

  resp="$(fetch "$url")"
  code="$(code_of "$resp")"
  body="$(body_of "$resp")"

  # The literal failure, asserted literally. A bash pattern match on a variable
  # — no pipeline, so no `grep -q` under pipefail inverting a match into a
  # no-match (VAC008), and no chance of matching this file's own source.
  case "$body" in
    *"${LOGIN_GATE_UNREGISTERED}"*)
      detail "GET /dex/auth -> ${code}"
      detail "Dex REFUSED the callback this origin would send:"
      detail "  ${redirect}"
      detail "this is the principal-visible outage, verbatim: ${LOGIN_GATE_UNREGISTERED}"
      echo ORIGIN_NOT_CLAIMED
      return 1 ;;
  esac

  # Everything below establishes that the response is one we can actually read a
  # verdict from. Reached only when the refusal literal was absent — which, on
  # its own, means nothing at all.
  if [ "$code" = "000" ]; then
    detail "GET /dex/auth -> transport failure"
    detail "no response, so the callback registration is UNKNOWN. Reported as"
    detail "Dex-down rather than as a pass: an empty body contains no refusal"
    detail "either, and calling that a working login is how this check would"
    detail "come back green over a login that has never worked."
    echo DEX_DOWN
    return 1
  fi

  if [ "$code" != "200" ]; then
    detail "GET /dex/auth -> ${code} with no recognisable refusal in the body"
    detail "the authorisation endpoint did not serve a login form and did not say"
    detail "why in terms this gate knows. Most often a client_id that is not"
    detail "registered ('${LOGIN_GATE_CLIENT}'), or a route that is not Dex."
    detail "body: $(printf '%s' "$body" | head -c 200)"
    echo AUTH_REFUSED
    return 1
  fi

  detail "callback accepted: ${redirect}"
  detail "/dex/auth served the login form (200)"
  return 0
}

# ── Drive it ─────────────────────────────────────────────────────────
log "════ LOGIN-SURFACE GATE ══════════════════════════════════════════════"
log "  origin : ${BASE_URL}"
log "  client : ${LOGIN_GATE_CLIENT}"
log "  mode   : READ-ONLY (GETs only; no credentials are sent)"
log ""

verdict="$(assert_origin_reachable)"
if [ -n "$verdict" ]; then
  log ""
  log "    VERDICT: ${verdict}"
  log "LOGIN GATE FAILED at ${BASE_URL}"
  exit 1
fi

verdict="$(assert_issuer_matches)"
if [ -n "$verdict" ]; then
  log ""
  log "    VERDICT: ${verdict}"
  case "$verdict" in
    ORIGIN_NOT_CLAIMED)
      log "The Dex origin is not claimed for this URL. Repair it ON THE VM with:"
      log "  cd /opt/signalloom/repo && ./scripts/lib/dex-origin.sh apply tailscale ${BASE_URL}"
      log "UNSUDOED — sudo drops the kubeconfig and the command then fails with"
      log "'localhost:8080 connection refused', which reads as a cluster fault." ;;
    DEX_DOWN)
      log "Dex is not serving at this origin. This is not an origin-claim problem." ;;
  esac
  log "LOGIN GATE FAILED at ${BASE_URL}"
  exit 1
fi

verdict="$(assert_callback_registered)"
if [ -n "$verdict" ]; then
  log ""
  log "    VERDICT: ${verdict}"
  case "$verdict" in
    ORIGIN_NOT_CLAIMED)
      log "Repair it ON THE VM with:"
      log "  cd /opt/signalloom/repo && ./scripts/lib/dex-origin.sh apply tailscale ${BASE_URL}"
      log "UNSUDOED — sudo drops the kubeconfig and the command then fails with"
      log "'localhost:8080 connection refused', which reads as a cluster fault." ;;
  esac
  log "LOGIN GATE FAILED at ${BASE_URL}"
  exit 1
fi

log ""
log "    VERDICT: WORKING"
log "LOGIN GATE PASSED: a human can begin the sign-in flow at ${BASE_URL}"
log "PROVEN: the issuer matches this origin and Dex accepts its callback."
log "NOT PROVEN: that a password completes. This gate sends no credentials."
exit 0
