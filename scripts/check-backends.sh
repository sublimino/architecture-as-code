#!/usr/bin/env bash
# check-backends.sh — is every backend the dashboard proxies to actually there?
#
#   check-backends.sh static   # manifests only, no cluster (CI / pre-deploy)
#   check-backends.sh live     # against the running cluster (doctor / post-deploy)
#
# ─── Why this exists ────────────────────────────────────────────────────────
#
# Twice in two days a complete, tested backend slice sat in the repo and was
# never deployed, and the failure reached a human as a cryptic error rather than
# "not deployed":
#
#   fleet-manager   written 2026-08-04 with source, tests and manifests. Never
#                   built, in no kustomization, no nginx location. The Fleet page
#                   died on `Unexpected token '<', "<!doctype "...` because
#                   nginx's SPA catch-all answered the API call with index.html
#                   at 200 OK — res.ok was TRUE, so nothing looked wrong.
#
#   afm-platform    same shape. rbac_correlation.py resolves
#                   afm-platform.fe-k8s-afm.svc.cluster.local:8000; nothing AFM
#                   was deployed and the namespace did not exist, so
#                   /rbac-explorer failed with
#                   `[Errno -2] Name or service not known`.
#
# In both cases every test passed. Unit tests mock fetch, contract tests mock the
# upstream, and the BATS suites assert manifest CONTENT rather than manifest
# PRESENCE in a cluster. Nothing asserted the deployed system was whole.
#
# ─── Why nginx.conf is the source of truth ──────────────────────────────────
#
# The dashboard reaches every backend through an nginx `proxy_pass`, so the set
# of `set $var http://<host>` lines IS the set of backends that must exist. It
# cannot drift from reality the way a hand-maintained list would: adding a proxy
# without deploying its upstream is exactly the bug, and this reads the proxy.
#
# The repo already applies this reasoning in the opposite direction —
# d2-signalloom/test/dashboard-route-collisions.bats asserts every nginx upstream
# has a matching dashboard egress NetworkPolicy rule, and that guard caught the
# Fleet egress gap the moment the proxy was added. This is the same idea aimed at
# deployment rather than policy.

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX_CONF="${NGINX_CONF:-${repo_root}/d2-signalloom/apps/dashboard-signalloom/nginx.conf}"

# Emits `host port service namespace` for every proxied upstream.
upstreams() {
  # `set $name http://<svc>.<ns>.svc.cluster.local:<port>;`
  grep -oE 'set \$[a-z_]+ +http://[a-z0-9.-]+(:[0-9]+)?' "$NGINX_CONF" \
    | sed -E 's|.*http://||' \
    | sort -u \
    | while IFS= read -r hostport; do
        [ -z "$hostport" ] && continue
        local host port svc ns
        host="${hostport%%:*}"
        port="${hostport##*:}"
        [ "$port" = "$host" ] && port=80
        svc="${host%%.*}"
        ns="${host#*.}"; ns="${ns%%.*}"
        printf '%s %s %s %s\n' "$host" "$port" "$svc" "$ns"
      done
}

fail=0
# Tracked separately from `fail` because they are different answers and the
# remediation differs. See the verdict block at the bottom.
could_not_look=0

# ── static: every upstream must be deployable from something in this repo ────
#
# Catches the fleet-manager/AFM shape at review time, with no cluster: a proxy
# pointing at a service no manifest declares can never work.
check_static() {
  local host port svc ns hits
  printf '\n── backends declared by nginx (static) ──\n\n'
  while read -r host port svc ns; do
    [ -z "$host" ] && continue
    # Search every D2 slice, not just d2-signalloom: afm-platform's manifests
    # live in d2-k8s-afm/, and scoping to one slice reported a deployed service
    # as UNDECLARED — a guard that cries wolf gets muted, which is worse than no
    # guard at all.
    hits="$(grep -rl --include='*.yaml' -E "^[[:space:]]*name:[[:space:]]*${svc}\$" \
              "${repo_root}"/d2-* 2>/dev/null | head -3 || true)"
    if [ -n "$hits" ]; then
      printf '  DECLARED    %-52s -> %s\n' "${svc}.${ns}:${port}" "$(basename "$(echo "$hits" | head -1)")"
    else
      printf '  UNDECLARED  %-52s no D2 slice declares a Service named %s\n' "${svc}.${ns}:${port}" "$svc" >&2
      fail=1
    fi
  done < <(upstreams)
}

# ── live: every upstream must resolve AND answer ─────────────────────────────
#
# `absent` and `unreachable` are reported separately on purpose. A Service that
# exists but does not answer is a different bug from one that was never
# deployed, and collapsing them sends the next engineer to the wrong place.
check_live() {
  local host port svc ns
  printf '\n── backends reachable from the cluster (live) ──\n\n'
  if ! kubectl cluster-info >/dev/null 2>&1; then
    printf '  UNAVAILABLE no reachable cluster — deployment state unproven, not disproven\n' >&2
    return 1
  fi
  while read -r host port svc ns; do
    [ -z "$host" ] && continue
    if ! kubectl -n "$ns" get service "$svc" >/dev/null 2>&1; then
      printf '  ABSENT      %-52s Service does not exist. The page that calls it will fail\n' "${svc}.${ns}:${port}" >&2
      printf '              %-52s with a DNS error or an HTML SPA fallback, not a clear message.\n' "" >&2
      fail=1
      continue
    fi
    local endpoints
    endpoints="$(kubectl -n "$ns" get endpoints "$svc" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
    if [ -z "$endpoints" ]; then
      printf '  NO BACKEND  %-52s Service exists but has no ready endpoints\n' "${svc}.${ns}:${port}" >&2
      fail=1
      continue
    fi
    printf '  READY       %-52s %s endpoint(s)\n' "${svc}.${ns}:${port}" "$(printf '%s' "$endpoints" | wc -w)"
  done < <(upstreams)
}

case "${1:-live}" in
  static) check_static ;;
  # ─── Why this is `|| could_not_look=1` and not `|| true` ──────────────────
  #
  # It was `|| true`, and that made the whole live mode capable of passing
  # VACUOUSLY. check_live returns 1 without inspecting anything when kubectl
  # cannot reach a cluster; `|| true` discarded that, `fail` stayed 0, and the
  # script exited 0 printing "All nginx upstreams are declared and reachable"
  # — a confident claim about a cluster it had never opened a connection to.
  #
  # Harmless while the only caller was doctor.sh in front of a human with the
  # cluster in front of them. Not harmless now that this gates a pipeline
  # stage, where a kubeconfig that is missing or points somewhere else is
  # precisely how a guard turns into decoration: every backend absent, stage
  # green. This is the failure check-ci-build-parity.sh's header names —
  # "could not look" written over "looked and found nothing" — and it reaches
  # the same verdict: both are exit 1, and the distinction lives in the words.
  live)   check_static; check_live || could_not_look=1 ;;
  *) printf 'usage: check-backends.sh <static|live>\n' >&2; exit 2 ;;
esac

if [ "$could_not_look" -ne 0 ]; then
  printf '\n  Deployment state is UNPROVEN, not proven good: there was no reachable\n' >&2
  printf '  cluster to ask. This is not the same as "all backends are up", and it is\n' >&2
  printf '  a failure for the same reason — a caller that treats it as a pass has a\n' >&2
  printf '  guard that reports success hardest when it is looking at nothing.\n' >&2
  printf '  Check KUBECONFIG and that the cluster is running, then re-run.\n\n' >&2
  exit 1
fi
if [ "$fail" -ne 0 ]; then
  printf '\n  One or more backends the dashboard proxies to are missing.\n' >&2
  printf '  Deploy them before demoing — a missing backend surfaces to the audience\n' >&2
  printf '  as a JSON parse error or a raw errno, not as "not deployed".\n\n' >&2
  exit 1
fi
printf '\n  All nginx upstreams are declared and reachable.\n\n'
