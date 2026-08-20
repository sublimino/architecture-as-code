#!/usr/bin/env bash
# dex-origin.sh — ONE origin, one holder, for every access method.
#
# Dex has exactly one issuer and one registered callback list, so the demo can
# be published on exactly ONE origin at a time. That is not a policy this file
# invents; it is a property of OIDC that this file makes visible and enforceable.
#
# Four access methods want to publish the demo, and every one of them needs the
# same three things to agree with the origin a browser actually typed:
#
#   Dex issuer                  d2-signalloom/infra/inf-signalloom/base/dex.yaml
#   Dex staticClients redirect  same file
#   API_JWT_ISSUER (x2)         apps/fe-signalloom, apps/supercred-demo-runner
#
#   IAP tunnel        http://localhost:<port>                     (loopback only)
#   ngrok             https://<random>.ngrok-free.app
#   Tailscale         https://<node>.<tailnet>.ts.net             (private)
#   Tailscale Funnel  https://<node>.<tailnet>.ts.net             (public)
#
# Every one of those now terminates at the SAME place: the dashboard's nginx,
# `dashboard-signalloom:8080` in fe-signalloom, which serves the SPA and proxies
# /dex/ and /api/ same-origin. IAP used to be the odd one out — it tunnelled to
# the Envoy Gateway instead, which is why it needed a pinned port, an /etc/hosts
# line and an SNI-matching hostname. It does not any more, and the consequence
# for THIS file is that IAP is an ordinary lease-taking method rather than a
# privileged baseline. See "THE BASELINE IS NOT A METHOD" below.
#
# All five fields are already `${PUBLIC_ORIGIN:=<baseline>}` templates resolved
# by Flux postBuild.substituteFrom from the flux-runtime-info ConfigMap, so
# DELIVERING an origin is a solved problem — see publish_origin's history in
# expose.sh, and the substituteFrom block in d2-osramp-fleet/tenants/local/
# signalloom.yaml. This file does not re-solve it. It adds the three things that
# were missing and that only matter once there is more than one publisher:
#
#   1. A LEASE. Whoever holds the origin is recorded, so a second access method
#      is REFUSED and told who to tear down. Without this, two methods silently
#      overwrite each other's issuer and the loser presents as a broken login —
#      the single worst outcome available here, because it looks like an
#      application bug rather than a configuration collision.
#
#   2. IDEMPOTENCE. Re-applying the same origin does nothing. This is not a
#      micro-optimisation: applying an origin restarts Dex, and Dex runs
#      `storage: type: memory`, so every restart invalidates every in-flight
#      login. A no-op that costs a Dex restart is a no-op that logs people out.
#
#   3. VALIDATION. A trailing slash on the origin yields `https://host//dex` as
#      the issuer, which every token consumer then rejects. Rejecting the origin
#      at the door is the only place this is cheap to catch.
#
# WHERE THE LEASE LIVES, and why it is not a file.
#
# In the cluster, as sibling keys of PUBLIC_ORIGIN in the same ConfigMap. The
# cluster is the ONLY thing all four access methods share: a Tailscale node and
# an ngrok tunnel may be driven from different checkouts on different machines.
# public-tunnel.sh already learned this the expensive way for its port-forward
# and still carries the scar in its error text ("If it belongs to another
# checkout, run 'make public-down' there"). A lease in .tunnel/ would be blind
# to exactly the collision it exists to prevent.
#
# Usable as a library (source it) or as a CLI (scripts/lib/dex-origin.sh apply
# ngrok https://x.ngrok-free.app). Every external dependency below is
# env-overridable so the whole mechanism is testable with no cluster at all —
# see test/terraform-dex-origin.bats.

# ── Injectable boundaries ────────────────────────────────────────────
#
# Defaults, not requirements. Anything here can be pointed at a stub.
DEX_ORIGIN_KUBECTL="${DEX_ORIGIN_KUBECTL:-kubectl}"
DEX_ORIGIN_FLUX="${DEX_ORIGIN_FLUX:-flux}"

# ── THE BASELINE IS NOT A METHOD ─────────────────────────────────────
#
# The resting origin. Held by NOBODY.
#
# It used to double as "the IAP access method's origin", and that conflation is
# what made IAP special: because the manifests already defaulted to this value,
# the IAP path could open a tunnel and skip the origin mechanism entirely — so
# it never took a lease, and every other method had to work around a publisher
# it could not see. Now that IAP terminates at the same nginx as everything else
# it claims `http://localhost:<port>` like any other method, and this value is
# only ever two things: what `dex_origin_current` reports when nobody has
# published, and what `restore` writes to hand the demo back.
#
# It is the Envoy Gateway's origin because that is what the MANIFESTS default
# to, not because any access path prefers it. Envoy is still deployed and still
# the Gateway API ingress; it is simply no longer on the access path.
#
# This string must stay identical to the `:=default` in dex.yaml, in
# apps/fe-signalloom/base/deployment.yaml and in
# apps/supercred-demo-runner/base/deployment.yaml, and to the port
# scripts/acceptance-test.sh pins its Gateway forward to. If they drift, a
# teardown lands on an origin no manifest defaults to and the demo comes back up
# broken. test/terraform-dex-origin.bats asserts the manifests agree with this.
DEX_ORIGIN_BASELINE="${DEX_ORIGIN_BASELINE:-https://dashboard.osramp.acme.local:30754}"

DEX_ORIGIN_CONFIGMAP="${DEX_ORIGIN_CONFIGMAP:-flux-runtime-info}"

# The lease is single-homed in flux-system ON PURPOSE. The tenant copies below
# are what the substitution actually reads, but they are copies — writing the
# holder to three places creates three answers to "who holds this" and no way to
# adjudicate between them when they disagree.
DEX_ORIGIN_LEASE_NAMESPACE="${DEX_ORIGIN_LEASE_NAMESPACE:-flux-system}"

# ── Space-separated strings, deliberately not arrays ─────────────────
#
# `FOO=("${FOO[@]:-a b}")` does NOT give you a two-element array when FOO is
# unset — it gives you ONE element containing "a b". scripts/lib/expose.sh
# carries exactly that construct at its FLUX_TARGETS default and gets away with
# it only because public-tunnel.sh reassigns the array afterwards; any other
# caller sourcing expose.sh alone would reconcile a Kustomization named `apps`
# in namespace `inf-signalloom`, which does not exist, and would say
# "reconciled" while doing nothing. A string plus `read -ra` at the point of use
# has no such trap and is overridable from the environment, which an array is
# not.
DEX_ORIGIN_TENANT_NAMESPACES="${DEX_ORIGIN_TENANT_NAMESPACES:-inf-signalloom fe-signalloom}"
DEX_ORIGIN_FLUX_TARGETS="${DEX_ORIGIN_FLUX_TARGETS:-inf-signalloom/infra-configs fe-signalloom/apps}"

DEX_ORIGIN_DEX_NAMESPACE="${DEX_ORIGIN_DEX_NAMESPACE:-inf-signalloom}"
DEX_ORIGIN_DEX_DEPLOYMENT="${DEX_ORIGIN_DEX_DEPLOYMENT:-dex}"
DEX_ORIGIN_ROLLOUT_TIMEOUT="${DEX_ORIGIN_ROLLOUT_TIMEOUT:-120s}"

# Who to name in a refusal. A bare method name ("held by tailscale") does not
# tell the reader which machine to go and tear down.
DEX_ORIGIN_OWNER="${DEX_ORIGIN_OWNER:-$(id -un 2>/dev/null || echo unknown)@$(hostname 2>/dev/null || echo unknown)}"

# Lease key names. Siblings of PUBLIC_ORIGIN in the same ConfigMap.
#
# Not `readonly`. A second `readonly` assignment to an already-readonly name is
# a hard error in bash, so marking these would make the file fatal to source
# twice — and expose.sh sources it while public-tunnel.sh may reach it directly.
DEX_ORIGIN_KEY="PUBLIC_ORIGIN"
DEX_ORIGIN_KEY_METHOD="PUBLIC_ORIGIN_METHOD"
DEX_ORIGIN_KEY_OWNER="PUBLIC_ORIGIN_OWNER"
DEX_ORIGIN_KEY_SINCE="PUBLIC_ORIGIN_SINCE"

# ── Validation ───────────────────────────────────────────────────────
#
# Pure. No cluster, no network, no side effects — which is what makes the
# malformed-origin cases cheap to test exhaustively.
#
# An origin is scheme + host + optional port and NOTHING else. Everything
# downstream appends to it (`${origin}/dex`, `${origin}/callback`), so any path,
# query, fragment or trailing slash produces a subtly wrong URL rather than an
# error: `https://host/` becomes the issuer `https://host//dex`, which Dex
# serves happily and every token consumer then rejects as a mismatched `iss`.
#
# ── Cleartext is allowed on loopback and NOWHERE else ────────────────
#
# nginx serves plain HTTP on 8080, so the IAP origin genuinely is
# `http://localhost:<port>` — the tunnel is the confidentiality boundary there,
# and Google has already authenticated the caller before a byte reaches it.
#
# The same URL shape with a routable host is a different thing entirely: Dex
# would issue its authorisation code, its ID token and every subsequent bearer
# over the wire in the clear, and browsers additionally drop `Secure` cookies
# and refuse `SameSite=None` on a non-secure origin — so the failure is half
# silent interception and half a login that mysteriously will not stick.
#
# Refused at the door rather than warned about. There is no legitimate caller in
# this estate: Tailscale and Funnel get a real certificate from `tailscale
# serve`, ngrok terminates TLS at its edge, and IAP is loopback. An origin that
# is neither loopback nor https is a mistake every time.
dex_origin_is_loopback() {
  local host="${1-}"
  [[ "$host" == "localhost" ]] && return 0
  # The whole 127.0.0.0/8 block, not just 127.0.0.1. A forward bound to
  # 127.0.0.2 is equally local and equally safe, and treating it as routable
  # would refuse a correct origin with a security message — the kind of wrong
  # refusal that gets a guard disabled rather than fixed.
  [[ "$host" =~ ^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

dex_origin_validate() {
  local origin="${1-}" rest host port reason="" insecure=0

  if [[ -z "$origin" ]]; then
    reason="origin is empty"
  elif [[ "$origin" =~ [[:space:]] ]]; then
    reason="origin contains whitespace"
  elif [[ "$origin" != http://* && "$origin" != https://* ]]; then
    reason="origin must begin with http:// or https://"
  else
    rest="${origin#*://}"
    if [[ -z "$rest" ]]; then
      reason="origin has no host"
    elif [[ "$rest" == */* ]]; then
      # Catches both a real path and the far more common bare trailing slash.
      reason="origin must not contain a path or a trailing slash"
    elif [[ "$rest" == *'?'* ]]; then
      reason="origin must not contain a query string"
    elif [[ "$rest" == *'#'* ]]; then
      reason="origin must not contain a fragment"
    elif [[ "$rest" == *'@'* ]]; then
      reason="origin must not contain userinfo"
    else
      host="${rest%%:*}"
      port=""
      [[ "$rest" == *:* ]] && port="${rest##*:}"

      if [[ -z "$host" ]]; then
        reason="origin has no host"
      elif [[ ! "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        reason="invalid host '${host}'"
      elif [[ -n "$port" && ! "$port" =~ ^[0-9]+$ ]]; then
        reason="invalid port '${port}'"
      elif [[ -n "$port" ]] && { (( port < 1 )) || (( port > 65535 )); }; then
        reason="port ${port} is out of range 1-65535"
      elif [[ "$origin" == http://* ]] && ! dex_origin_is_loopback "$host"; then
        reason="refusing an insecure origin: '${host}' is not loopback"
        insecure=1
      fi
    fi
  fi

  if [[ "$insecure" -eq 1 ]]; then
    # A DIFFERENT trailer from the malformed-origin case. The generic
    # "expected scheme://host[:port]" advice is actively misleading here: the
    # origin IS well formed, and a reader told to check its shape will retype
    # the same URL and watch it be refused again.
    echo "ERROR: ${reason}" >&2
    echo "       Dex would issue its tokens over cleartext to a routable host," >&2
    echo "       and the browser would drop the Secure session cookie, so this" >&2
    echo "       fails as an interceptable login that also will not persist." >&2
    echo "       Use https:// for anything off this machine. http:// is only" >&2
    echo "       accepted on localhost or 127.0.0.0/8, where the IAP tunnel is" >&2
    echo "       the confidentiality boundary." >&2
    echo "       Got: '${origin}'" >&2
    return 1
  fi

  if [[ -n "$reason" ]]; then
    echo "ERROR: ${reason}" >&2
    echo "       Expected scheme://host[:port] with no trailing slash, e.g." >&2
    echo "         ${DEX_ORIGIN_BASELINE}" >&2
    echo "       Got: '${origin}'" >&2
    return 1
  fi
}

# The method name is written into a ConfigMap value and read back into a
# refusal message, so it is constrained to something that cannot be confused
# with prose when it lands in that sentence.
dex_origin_validate_method() {
  local method="${1-}"
  if [[ ! "$method" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "ERROR: invalid access-method name '${method}'." >&2
    echo "       Expected a lowercase token such as: iap, ngrok, tailscale, funnel" >&2
    return 1
  fi
}

# ── Reading cluster state ────────────────────────────────────────────
#
# `read -r a b < <(kubectl -o jsonpath ...)` looks like the obvious way to pull
# several fields at once and is a trap: jsonpath emits no trailing newline, so
# `read` returns NON-ZERO having successfully read everything, and under `set -e`
# that aborts the caller with empty output and no error. Command substitution
# plus an explicit `|| true` cannot fail that way, which is why every read below
# takes one field at a time.
_dex_origin_cm_key() {
  local ns="$1" key="$2" out
  out="$("$DEX_ORIGIN_KUBECTL" get configmap "$DEX_ORIGIN_CONFIGMAP" -n "$ns" \
    -o "jsonpath={.data.${key}}" 2>/dev/null || true)"
  printf '%s' "$out"
}

# The origin the cluster is currently publishing. Falls back to the baseline so
# callers never have to distinguish "no ConfigMap yet" from "resting state" —
# both mean nobody has published anything.
dex_origin_current() {
  local origin
  origin="$(_dex_origin_cm_key "$DEX_ORIGIN_LEASE_NAMESPACE" "$DEX_ORIGIN_KEY")"
  [[ -z "$origin" ]] && origin="$DEX_ORIGIN_BASELINE"
  printf '%s\n' "$origin"
}

# The METHOD currently holding the origin, or nothing when nobody holds it.
#
# Exposed on the CLI as well as in-process, and that is not symmetry for its own
# sake — it closes a real hole. `current` deliberately falls back to the baseline
# so callers never have to distinguish "no ConfigMap" from "resting state", which
# means an out-of-process caller asking `current` on an idle cluster gets a
# non-empty origin back and, if it treats non-empty as "somebody has published",
# refuses itself. scripts/gcp-tf/demo-up.sh did exactly that: every ts-up on a
# resting cluster would have been refused with "another origin already holds
# Dex: <the baseline>". It survived because the driver's suite only ever asked a
# stub, whose `current` prints empty at rest.
#
# The fix is for the question to be askable. "Is anyone holding this" is a
# question about the METHOD key, never about the origin string — which is
# precisely what dex_origin_is_held already encodes in-process.
dex_origin_holder() {
  _dex_origin_cm_key "$DEX_ORIGIN_LEASE_NAMESPACE" "$DEX_ORIGIN_KEY_METHOD"
}

# Held means "some access method has published a non-baseline origin AND said
# who it was".
#
# The `AND said who it was` half is load-bearing and is a deliberate softening.
# An origin present with no method key is pre-lease state: a cluster published
# by an older public-tunnel.sh, or a hand-patched ConfigMap. Refusing there
# would produce "refused: held by (nobody)", which names no one to tear down and
# so cannot be acted on — the exact useless failure this mechanism exists to
# replace. dex_origin_apply grants in that case and warns, because a warning
# that says what was adopted beats a refusal that says nothing.
dex_origin_is_held() {
  local origin method
  origin="$(dex_origin_current)"
  method="$(dex_origin_holder)"
  [[ "$origin" != "$DEX_ORIGIN_BASELINE" && -n "$method" ]]
}

dex_origin_status() {
  local origin method owner since
  origin="$(dex_origin_current)"
  method="$(dex_origin_holder)"
  owner="$(_dex_origin_cm_key "$DEX_ORIGIN_LEASE_NAMESPACE" "$DEX_ORIGIN_KEY_OWNER")"
  since="$(_dex_origin_cm_key "$DEX_ORIGIN_LEASE_NAMESPACE" "$DEX_ORIGIN_KEY_SINCE")"

  echo "origin:  ${origin}"
  if [[ "$origin" == "$DEX_ORIGIN_BASELINE" ]]; then
    # NOT "iap". Naming a method here was true when IAP served at the baseline
    # and is a lie now that it claims http://localhost:<port> like everything
    # else — and it is the expensive kind, because an operator reading
    # "method: iap" on an unheld origin concludes an IAP demo is live and goes
    # looking for a tunnel to tear down.
    echo "method:  (none — resting origin, held by nobody)"
    echo "state:   AVAILABLE"
    return 0
  fi
  echo "method:  ${method:-<unlabelled>}"
  echo "owner:   ${owner:-<unknown>}"
  echo "since:   ${since:-<unknown>}"
  echo "state:   HELD"
}

# ── Writing ──────────────────────────────────────────────────────────
#
# flux-system AND every tenant copy, deliberately.
#
# The tenant copies carry `fluxcd.controlplane.io/copyFrom: flux-system/
# flux-runtime-info`, but that copy does NOT reliably propagate an UPDATE:
# measured on 2026-08-03, changing the key in flux-system (and even forcing a
# ResourceSet reconcile) left both tenant copies on the previous value, so Dex
# and the API kept serving a stale origin. Writing flux-system alone looks
# correct and silently does nothing. flux-system is still written because it is
# the durable source a re-copy or a rebuilt namespace will read; the tenant
# writes are what take effect now.
_dex_origin_write() {
  local origin="$1" method="$2" ns
  local since; since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # One merge patch, so the origin and the lease that describes it can never be
  # half-written. A null value REMOVES a key under a merge patch and is a no-op
  # when the key is already absent, which is what makes release tolerant of a
  # cluster that never had a lease.
  local lease
  if [[ -n "$method" ]]; then
    lease="\"${DEX_ORIGIN_KEY_METHOD}\":\"${method}\",\"${DEX_ORIGIN_KEY_OWNER}\":\"${DEX_ORIGIN_OWNER}\",\"${DEX_ORIGIN_KEY_SINCE}\":\"${since}\""
  else
    lease="\"${DEX_ORIGIN_KEY_METHOD}\":null,\"${DEX_ORIGIN_KEY_OWNER}\":null,\"${DEX_ORIGIN_KEY_SINCE}\":null"
  fi

  if ! "$DEX_ORIGIN_KUBECTL" patch configmap "$DEX_ORIGIN_CONFIGMAP" \
      -n "$DEX_ORIGIN_LEASE_NAMESPACE" --type=merge \
      -p "{\"data\":{\"${DEX_ORIGIN_KEY}\":\"${origin}\",${lease}}}" >/dev/null; then
    echo "ERROR: could not write ${DEX_ORIGIN_CONFIGMAP} in ${DEX_ORIGIN_LEASE_NAMESPACE}." >&2
    echo "       Without it the origin is not published and no lease is held." >&2
    return 1
  fi

  # Tenant copies get the origin only. The lease is single-homed above.
  #
  # Tolerated failure, unlike the write above: a tenant namespace may legitimately
  # not exist yet on a partially-built cluster, and the substitution will pick the
  # value up from the flux-system copy when the namespace appears.
  local ns_list; read -ra ns_list <<< "$DEX_ORIGIN_TENANT_NAMESPACES"
  for ns in "${ns_list[@]}"; do
    "$DEX_ORIGIN_KUBECTL" patch configmap "$DEX_ORIGIN_CONFIGMAP" -n "$ns" \
      --type=merge -p "{\"data\":{\"${DEX_ORIGIN_KEY}\":\"${origin}\"}}" >/dev/null 2>&1 || true
  done

  echo "    PUBLIC_ORIGIN=${origin}"
}

# Reconciling the Kustomization alone is not enough — it re-applies whatever its
# source already had. The OCIRepository must be refreshed first or the new
# substitution never reaches the manifest.
_dex_origin_reconcile() {
  local targets target ns name src
  read -ra targets <<< "$DEX_ORIGIN_FLUX_TARGETS"
  for target in "${targets[@]}"; do
    ns="${target%%/*}"; name="${target##*/}"
    src="$("$DEX_ORIGIN_KUBECTL" get kustomization "$name" -n "$ns" \
      -o jsonpath='{.spec.sourceRef.name}' 2>/dev/null || true)"
    if [[ -n "$src" ]]; then
      "$DEX_ORIGIN_FLUX" reconcile source oci "$src" -n "$ns" >/dev/null 2>&1 || true
    fi
    "$DEX_ORIGIN_FLUX" reconcile kustomization "$name" -n "$ns" >/dev/null 2>&1 || true
  done
  echo "    reconciled ${DEX_ORIGIN_FLUX_TARGETS}"
}

# Dex reads /etc/dex/config.yaml ONCE, at process start. It has no config
# watcher and no SIGHUP reload, so updating the Secret is not enough: the
# kubelet syncs the mounted file on its own schedule and the running process
# never re-reads it. The symptom is maximally confusing — the Secret in the
# cluster visibly contains the new issuer and callback while Dex keeps rejecting
# the login with "Unregistered redirect_uri".
#
# The `signalloom.ai/dex-origin` annotation on the Deployment makes the rendered
# pod template differ per origin, so Flux normally rolls Dex on its own. This
# restart is belt and braces for the case where the annotation resolved to the
# same value but something else in the config changed, and it is also what makes
# `apply` synchronous: without waiting for the rollout, callers verify the new
# origin against the process still serving the old one.
_dex_origin_restart_dex() {
  "$DEX_ORIGIN_KUBECTL" get deploy "$DEX_ORIGIN_DEX_DEPLOYMENT" \
    -n "$DEX_ORIGIN_DEX_NAMESPACE" >/dev/null 2>&1 || return 0
  "$DEX_ORIGIN_KUBECTL" rollout restart "deployment/${DEX_ORIGIN_DEX_DEPLOYMENT}" \
    -n "$DEX_ORIGIN_DEX_NAMESPACE" >/dev/null 2>&1 || true
  "$DEX_ORIGIN_KUBECTL" rollout status "deployment/${DEX_ORIGIN_DEX_DEPLOYMENT}" \
    -n "$DEX_ORIGIN_DEX_NAMESPACE" --timeout="$DEX_ORIGIN_ROLLOUT_TIMEOUT" >/dev/null 2>&1 || true
  echo "    dex restarted to load the new issuer"
}

# ── The verbs ────────────────────────────────────────────────────────

# Publish ORIGIN on behalf of METHOD, or refuse and say who holds it.
dex_origin_apply() {
  local method="${1-}" origin="${2-}"

  dex_origin_validate_method "$method" || return 1
  dex_origin_validate "$origin" || return 1

  # Applying the baseline IS a release. Treating it as anything else would
  # leave the resting origin holding a lease against itself and block the next
  # access method for no reason.
  if [[ "$origin" == "$DEX_ORIGIN_BASELINE" ]]; then
    dex_origin_restore
    return
  fi

  local active_origin active_method
  active_origin="$(dex_origin_current)"
  active_method="$(dex_origin_holder)"

  if [[ "$active_origin" != "$DEX_ORIGIN_BASELINE" ]]; then
    if [[ -z "$active_method" ]]; then
      # See dex_origin_is_held for why this warns rather than refuses.
      echo "    WARNING: adopting an unlabelled origin (${active_origin}) — no holder was recorded" >&2
    elif [[ "$active_method" != "$method" ]]; then
      local owner since
      owner="$(_dex_origin_cm_key "$DEX_ORIGIN_LEASE_NAMESPACE" "$DEX_ORIGIN_KEY_OWNER")"
      since="$(_dex_origin_cm_key "$DEX_ORIGIN_LEASE_NAMESPACE" "$DEX_ORIGIN_KEY_SINCE")"
      echo "ERROR: the demo origin is already held by '${active_method}'." >&2
      echo "         origin: ${active_origin}" >&2
      echo "         owner:  ${owner:-<unknown>}" >&2
      echo "         since:  ${since:-<unknown>}" >&2
      echo "" >&2
      echo "       Dex has ONE issuer, so '${method}' cannot publish ${origin}" >&2
      echo "       alongside it — the loser of that race presents as a broken" >&2
      echo "       login rather than as a configuration collision." >&2
      echo "" >&2
      echo "       Tear the current one down first:" >&2
      echo "         scripts/lib/dex-origin.sh restore" >&2
      return 1
    fi

    # Same method, same origin: nothing to do. Not cosmetic — Dex runs
    # `storage: type: memory`, so a needless restart logs out every user
    # mid-session.
    if [[ "$active_origin" == "$origin" ]]; then
      echo "    PUBLIC_ORIGIN=${origin} (unchanged — nothing to do)"
      return 0
    fi
  fi

  # Same method, different origin: allowed. ngrok mints a new hostname on every
  # restart, so refusing here would break `make public` re-up.
  _dex_origin_write "$origin" "$method" || return 1
  _dex_origin_reconcile
  _dex_origin_restart_dex
}

# Release the lease and return to the baseline.
#
# This SETS the baseline rather than deleting PUBLIC_ORIGIN. Deleting does not
# unpublish: the tenant copies keep their last value when the key disappears, so
# the demo stays published on a dead origin while the cluster looks reset. An
# explicit value always propagates; an absent one does not.
dex_origin_restore() {
  local active_origin active_method
  active_origin="$(dex_origin_current)"
  active_method="$(dex_origin_holder)"

  if [[ "$active_origin" == "$DEX_ORIGIN_BASELINE" && -z "$active_method" ]]; then
    echo "    PUBLIC_ORIGIN=${DEX_ORIGIN_BASELINE} (already at baseline — nothing to do)"
    return 0
  fi

  _dex_origin_write "$DEX_ORIGIN_BASELINE" "" || return 1
  _dex_origin_reconcile
  _dex_origin_restart_dex
}

# ── CLI ──────────────────────────────────────────────────────────────
dex_origin_main() {
  case "${1:-}" in
    apply)    shift; dex_origin_apply "${1-}" "${2-}" ;;
    restore)  dex_origin_restore ;;
    current)  dex_origin_current ;;
    holder)   dex_origin_holder; printf '\n' ;;
    status)   dex_origin_status ;;
    validate) shift; dex_origin_validate "${1-}" ;;
    *)
      echo "Usage: $0 {apply <method> <origin>|restore|current|holder|status|validate <origin>}" >&2
      echo "" >&2
      echo "  apply     Publish <origin> for <method>, or refuse and name the holder" >&2
      echo "  restore   Release the lease and return to ${DEX_ORIGIN_BASELINE}" >&2
      echo "  current   Print the active origin (the baseline when nobody holds it)" >&2
      echo "  holder    Print the access method holding it, or nothing when free" >&2
      echo "  status    Print the active origin, its holder and when it was taken" >&2
      echo "  validate  Check an origin is well formed (no cluster required)" >&2
      return 1
      ;;
  esac
}

# Executed rather than sourced. `set -euo pipefail` belongs here and not at the
# top of the file: this is sourced by expose.sh, and forcing shell options onto
# a caller that did not ask for them changes the behaviour of code this file
# knows nothing about.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  dex_origin_main "$@"
fi
