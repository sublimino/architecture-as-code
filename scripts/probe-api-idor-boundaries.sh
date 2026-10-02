#!/usr/bin/env bash
# probe-api-idor-boundaries.sh — SLAAT-P1-2 fe-signalloom backend API probe.
#
# Adversarial, read-mostly probe of the LIVE fe-signalloom Discovery Portal
# API (kind-osramp cluster, fe-signalloom namespace, svc/fe-signalloom-api:8000)
# via a resilient port-forward. Confirms, against the real deployed service
# (real Dex issuer config, real network stack, real FastAPI exception
# handlers) rather than only the offline pytest harness:
#
#   1. Unauthenticated mutation requests fail closed (401), never 500.
#   2. A syntactically-valid but unsigned/forged Bearer token is rejected.
#   3. Error responses never leak a stack trace, SQL text, or exception repr.
#
# Scope note (see the SLAAT-P1-2 dossier): this live cluster's
# ``API_SUBJECT_TENANTS`` maps exactly one real subject/tenant pair
# (demo-user -> tenant-demo). There is no second tenant's credential to test
# cross-tenant BOLA against live, and no way to mint a Dex-signed JWT for an
# arbitrary subject without completing a real OIDC flow against the live Dex
# instance. Cross-tenant IDOR, JWT alg-confusion, and CAS/replay races are
# therefore verified in the offline pytest suites
# (test_token_adversarial_verification.py, test_tenant_authorization_matrix.py,
# test_enrollment_cas_race_adversarial.py), which control both tenants'
# signing keys precisely; this script verifies the SAME fail-closed contract
# holds on the actual deployed artifact for the one thing it generalizes
# safely without a real token: auth enforcement at the edge.
#
# Read-only / non-destructive: never issues a request that could mutate real
# demo tenant data if it were somehow accepted (every mutating attempt here is
# EXPECTED and VERIFIED to be rejected before reaching business logic).
#
# Usage:
#   scripts/probe-api-idor-boundaries.sh [--out FILE] [--local-port N]
#
# Env:
#   SLAAT_KUBE_CONTEXT    kube context (default: kind-osramp)
#   SLAAT_API_NAMESPACE   fe-signalloom-api namespace (default: fe-signalloom)
#   SLAAT_API_LOCAL_PORT  local port for the port-forward (default: 18000)
#
# Output: JSON array of probe records on stdout (and to --out FILE if given).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KUBE_CONTEXT="${SLAAT_KUBE_CONTEXT:-kind-osramp}"
NAMESPACE="${SLAAT_API_NAMESPACE:-fe-signalloom}"
LOCAL_PORT="${SLAAT_API_LOCAL_PORT:-18000}"
OUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_FILE="$2"; shift 2 ;;
    --local-port) LOCAL_PORT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

BASE_URL="http://127.0.0.1:${LOCAL_PORT}"
PF_PID=""

cleanup() {
  if [[ -n "${PF_PID}" ]]; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

wait_for_ready() {
  local i=0
  while (( i < 15 )); do
    if curl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/health" 2>/dev/null | grep -q '^200$'; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

if ! curl -s -o /dev/null "${BASE_URL}/health" 2>/dev/null; then
  kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" port-forward svc/fe-signalloom-api "${LOCAL_PORT}:8000" \
    >/dev/null 2>&1 &
  PF_PID=$!
  if ! wait_for_ready; then
    echo "FATAL: fe-signalloom-api unreachable after port-forward (15s)" >&2
    exit 1
  fi
fi

RESULTS="[]"

add_result() {
  local name="$1" method="$2" path="$3" status="$4" body="$5" verdict="$6"
  RESULTS="$(jq -c \
    --arg name "$name" --arg method "$method" --arg path "$path" \
    --argjson status "$status" --arg body "$body" --arg verdict "$verdict" \
    '. + [{name:$name, method:$method, path:$path, status:$status, body:$body, verdict:$verdict}]' \
    <<<"${RESULTS}")"
}

probe() {
  local name="$1" method="$2" path="$3" auth_header="$4"
  local tmp status body
  tmp="$(mktemp)"
  if [[ -n "${auth_header}" ]]; then
    status="$(curl -s -o "${tmp}" -w '%{http_code}' -X "${method}" "${BASE_URL}${path}" \
      -H "Authorization: ${auth_header}" -H 'Content-Type: application/json' -d '{}')"
  else
    status="$(curl -s -o "${tmp}" -w '%{http_code}' -X "${method}" "${BASE_URL}${path}" \
      -H 'Content-Type: application/json' -d '{}')"
  fi
  body="$(cat "${tmp}")"
  rm -f "${tmp}"

  local verdict="fail"
  if [[ "${status}" == "401" || "${status}" == "403" ]]; then
    verdict="pass"
  fi
  if echo "${body}" | grep -qiE 'traceback|asyncpg|psycopg|File "|  at '; then
    verdict="fail-leak"
  fi
  add_result "${name}" "${method}" "${path}" "${status}" "${body:0:500}" "${verdict}"
  echo "[$verdict] $name -> $method $path = $status" >&2
}

# 1. Required-test literal: enroll with an invalid bearer token.
probe "enroll-invalid-bearer" "POST" "/api/v1/external-agents/enroll" "Bearer invalid"

# 2. Unauthenticated mutation sweep against representative routes.
probe "unauth-connectors-create" "POST" "/api/v1/connectors" ""
probe "unauth-agent-transition" "POST" "/api/v1/agents/probe-dummy-id/transition" ""
probe "unauth-discovery-claim" "POST" "/api/v1/discovery/claim" ""
probe "unauth-external-agent-register" "POST" "/api/v1/external-agents/registrations" ""

# 3. Forged/malformed Bearer tokens (not Dex-signed -- expect rejection, not 500).
probe "forged-jwt-connectors" "POST" "/api/v1/connectors" "Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJtYWxsb3J5In0."
probe "garbage-bearer-agents" "POST" "/api/v1/agents/probe-dummy-id/transition" "Bearer not-a-jwt-at-all"

echo "${RESULTS}" | jq .

if [[ -n "${OUT_FILE}" ]]; then
  echo "${RESULTS}" | jq . > "${OUT_FILE}"
fi

FAIL_COUNT="$(echo "${RESULTS}" | jq '[.[] | select(.verdict != "pass")] | length')"
echo "probe complete: $(echo "${RESULTS}" | jq 'length') probes, ${FAIL_COUNT} non-pass" >&2
exit 0
