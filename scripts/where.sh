#!/usr/bin/env bash
# where.sh — "where is Signal Loom right now, and what URL do I hand someone?"
#
# One read-only command that detects which surfaces exist and prints routing
# info for each. It takes no arguments and never mutates anything: no apply, no
# tunnel start, no port-forward, no VM resume.
#
# The problem it solves is that routing information was scattered across three
# commands that each know about one surface and nothing about the others:
#
#   make public-status      local Kind, via the ngrok tunnel
#   make ci-status          the imperative GCP CI VMs
#   make gcp-tf-status ENV= a Terraform environment, and only if you already
#                           know its key and the state bucket
#
# None of them answers "what is up?", which is the question actually being
# asked, usually right before a demo.
#
# ─── The honesty rule ───────────────────────────────────────────────────────
#
# Every line is one of PRESENT / ABSENT / BROKEN / UNKNOWN, and UNKNOWN is a
# first-class answer. A status tool that reports "not running" when it merely
# failed to look is worse than one that says it could not tell: the first sends
# you debugging a healthy system, and this repo has already lost time to a
# gcloud query failure reading as a missing VM. Anything requiring credentials
# we do not have, or a probe we did not run, says so.
#
# Reachability is only ever claimed when it was probed. A DNS record and a load
# balancer IP mean an address exists, not that it serves.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROBE=0
[ "${1:-}" = "--probe" ] && PROBE=1
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  echo
  echo "usage: where.sh [--probe]"
  echo "  --probe   additionally curl each address and report the status code."
  echo "            Off by default: it makes outbound requests, and a demo URL"
  echo "            may be allowlisted to somewhere that is not this machine."
  exit 0
fi

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
row() { printf '  %-26s %-9s %s\n' "$1" "$2" "$3"; }

have() { command -v "$1" >/dev/null 2>&1; }

probe_url() {
  # Echoes an 8-word verdict. Never claims health it did not observe.
  local url="$1" code
  if [ "$PROBE" -eq 0 ]; then
    echo "not probed (--probe to check)"
    return
  fi
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null)"
  case "$code" in
  000) echo "no response within 8s" ;;
  200) echo "HTTP 200" ;;
  30[1237]) echo "HTTP $code — redirect, likely the auth boundary" ;;
  401 | 403) echo "HTTP $code — reached the auth/allowlist boundary" ;;
  502 | 503 | 504) echo "HTTP $code — edge is up, backend is not" ;;
  *) echo "HTTP $code" ;;
  esac
}

echo
bold "LOCAL — Kind cluster"

if ! have kubectl; then
  row "kubectl" "UNKNOWN" "not installed; cannot inspect the local cluster"
else
  ctx="$(kubectl config current-context 2>/dev/null)"
  if [ -z "$ctx" ]; then
    row "kube context" "ABSENT" "no current context"
  elif ! kubectl get nodes >/dev/null 2>&1; then
    row "kube context" "BROKEN" "context '${ctx}' set but the API server did not answer"
  else
    age="$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $4; exit}')"
    row "kube context" "PRESENT" "${ctx} (node up ${age:-unknown})"

    ns_found=0
    for ns in fe-signalloom inf-signalloom fe-signalloom-agents; do
      if kubectl get ns "$ns" >/dev/null 2>&1; then
        ns_found=$((ns_found + 1))
      fi
    done
    if [ "$ns_found" -eq 0 ]; then
      row "signalloom slice" "ABSENT" "no fe-/inf-signalloom namespaces; run 'make demo-signalloom-up'"
    else
      row "signalloom slice" "PRESENT" "${ns_found}/3 namespaces active"
    fi

    at="$(kubectl get ns --no-headers 2>/dev/null | grep -c '^agent-trust-')"
    if [ "${at:-0}" -gt 0 ]; then
      row "agent-trust slice" "PRESENT" "${at} namespaces active"
    else
      row "agent-trust slice" "ABSENT" "not deployed"
    fi
  fi
fi

echo
bold "LOCAL — public tunnel (ngrok)"

tunnel="${REPO_ROOT}/scripts/public-tunnel.sh"
if [ ! -x "$tunnel" ]; then
  row "tunnel script" "ABSENT" "scripts/public-tunnel.sh missing"
else
  # public-tunnel.sh status exits non-zero on BROKEN, which is exactly the state
  # worth surfacing rather than swallowing: ngrok accepting traffic with no
  # backend serves every visitor a 502, and looks "running" to a process check.
  status_out="$("$tunnel" status 2>&1)"
  status_rc=$?
  url="$("$tunnel" url 2>/dev/null)"

  if echo "$status_out" | grep -qi 'BROKEN'; then
    row "ngrok tunnel" "BROKEN" "accepting traffic with no backend — every visitor gets 502"
    row "" "" "repair with: make public"
  elif [ "$status_rc" -eq 0 ] && [ -n "$url" ]; then
    row "ngrok tunnel" "PRESENT" "$url"
    row "" "" "$(probe_url "$url")"
  else
    row "ngrok tunnel" "ABSENT" "not running; start with 'make public'"
  fi
fi

echo
bold "GCP — Terraform demo environments"

tf_root="${REPO_ROOT}/terraform/environments"
if [ ! -d "$tf_root" ]; then
  row "terraform tree" "ABSENT" "terraform/environments not present"
else
  # An environment is "declared" if a tfvars names it, and "deployed" only if a
  # readable remote state says so. Those are different claims and the gap
  # between them is the entire point of this section.
  declared="$(grep -rhoE '"(demo|ci)-[1-9][0-9]*"[[:space:]]*=[[:space:]]*\{' "$tf_root" 2>/dev/null |
    grep -oE '(demo|ci)-[1-9][0-9]*' | sort -u | tr '\n' ' ')"
  if [ -z "$declared" ]; then
    row "declared envs" "ABSENT" "no environment keys found in any tfvars"
  else
    row "declared envs" "PRESENT" "${declared}(from tfvars; declared is not deployed)"
  fi

  if [ -z "${TF_STATE_BUCKET:-}" ]; then
    row "remote state" "UNKNOWN" "TF_STATE_BUCKET unset — cannot read what is deployed"
    row "" "" "see terraform/RUNBOOK.md; nothing has been applied yet"
  elif ! have gcloud; then
    row "remote state" "UNKNOWN" "gcloud not installed"
  else
    acct="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
    if [ -z "$acct" ]; then
      row "gcloud auth" "UNKNOWN" "no active account — run: gcloud auth login"
    else
      row "gcloud auth" "PRESENT" "$acct"
      for env in $declared; do
        out="$(cd "$tf_root" && TF_DATA_DIR=".terraform-${env}" terraform output -json 2>/dev/null)"
        if [ -z "$out" ] || [ "$out" = "{}" ]; then
          row "$env" "UNKNOWN" "no readable state locally; run 'make gcp-tf-status ENV=${env}'"
          continue
        fi
        host="$(echo "$out" | jq -r '.hostname.value // empty' 2>/dev/null)"
        ip="$(echo "$out" | jq -r '.lb_ip_address.value // empty' 2>/dev/null)"
        if [ -n "$host" ]; then
          row "$env" "PRESENT" "https://${host}${ip:+  (LB ${ip})}"
          row "" "" "$(probe_url "https://${host}")"
        elif [ -n "$ip" ]; then
          row "$env" "PRESENT" "LB ${ip} — no hostname; managed cert disabled"
        else
          row "$env" "UNKNOWN" "state readable but names no hostname or LB address"
        fi
      done
    fi
  fi
fi

echo
bold "GCP — imperative CI VMs (pre-existing estate)"

gcp_ci="${REPO_ROOT}/scripts/ci/gcp-ci.sh"
if [ ! -x "$gcp_ci" ]; then
  row "gcp-ci.sh" "ABSENT" "script missing"
elif ! have gcloud; then
  row "CI VMs" "UNKNOWN" "gcloud not installed"
else
  # SSH_AUTH_SOCK is emptied for the query: a populated agent makes gcloud's IAP
  # path fail with "agent refused operation", which reads as a VM fault and is a
  # local one.
  out="$(env SSH_AUTH_SOCK='' timeout 45 "$gcp_ci" status 2>&1 | head -2)"
  if echo "$out" | grep -q 'QUERY_FAILED'; then
    row "signalloom-ci" "UNKNOWN" "query failed — the active account cannot see the project"
  else
    row "signalloom-ci" "PRESENT" "$(echo "$out" | head -1 | cut -c1-70)"
  fi
  row "" "" "these are CI runners, not demo surfaces — no public route by design"
fi

echo
bold "What to hand someone"
echo
if [ -n "${url:-}" ] && ! echo "${status_out:-}" | grep -qi 'BROKEN'; then
  echo "  ${url}   (local Kind via ngrok — ephemeral, dies with this laptop)"
else
  echo "  Nothing is publicly routable right now."
fi
echo
echo "  A demo-N environment is the permanent answer: its own HTTPS load balancer,"
echo "  managed certificate and Cloud Armor allowlist, with a stable hostname that"
echo "  does not depend on this machine being awake. None is deployed yet —"
echo "  terraform/RUNBOOK.md is the procedure, and it needs your approval first."
echo
