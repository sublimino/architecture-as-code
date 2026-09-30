#!/usr/bin/env bash
# ==============================================================================
# SLDC-P3-2 Tenant Ingress Routing & Dex OIDC Verification Script
#
# Simulates external Tailscale ingress traffic to Envoy Gateway, validating
# HTTP status codes, tenant header isolation, 403 rejection of mismatched/legacy
# headers, default inferred tenant routing, and Dex OIDC callback alignment.
#
# Usage:
#   scripts/verify-tenant-routing.sh [--target-ip IP] [--port PORT] [--hermetic] [--json] [--out FILE]
# ==============================================================================
set -eo pipefail

CANONICAL_TENANT="kusari"
CANONICAL_HASH="4b53ab6b"
CANONICAL_HOST="sl-eap-${CANONICAL_HASH}.ts.net"
CANONICAL_DEMO_HOST="sl-eap-${CANONICAL_HASH}.demo.signalloom.io"
RETIRED_TENANT="kurasi"
RETIRED_HASH="6f82ad81"
RETIRED_HOST="sl-eap-${RETIRED_HASH}.ts.net"

TARGET_IP="${SLDC_TARGET_IP:-172.19.0.20}"
TARGET_PORT="${SLDC_TARGET_PORT:-30080}"
HTTPS_PORT="${SLDC_HTTPS_PORT:-31443}"
KUBECTL="${KUBECTL:-kubectl}"
CONTEXT="${SLDC_HUB_CONTEXT:-kind-signalloom-hub}"

HERMETIC=false
OUTPUT_JSON=false
OUTPUT_FILE=""
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-ip) TARGET_IP="$2"; shift 2 ;;
    --port) TARGET_PORT="$2"; shift 2 ;;
    --https-port) HTTPS_PORT="$2"; shift 2 ;;
    --canonical-host) CANONICAL_HOST="$2"; shift 2 ;;
    --hermetic|--dry-run) HERMETIC=true; shift ;;
    --json) OUTPUT_JSON=true; shift ;;
    --out) OUTPUT_FILE="$2"; shift 2 ;;
    --verbose|-v) VERBOSE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--target-ip IP] [--port PORT] [--hermetic] [--json] [--out FILE]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HTTPROUTE_MANIFEST="${SLDC_HTTPROUTE_MANIFEST:-$REPO_ROOT/deploy/eap-tenant-httproute.yaml}"
DEX_CONFIG_MANIFEST="$REPO_ROOT/d2-signalloom/infra/dex/dex-config-eap.yaml"
TENANT_POLICY_MANIFEST="${SLDC_TENANT_POLICY_MANIFEST:-$REPO_ROOT/d2-infra/components/ingress/tenant-filter-policy.yaml}"
LUA_HARNESS="$REPO_ROOT/test/fixtures/tenant/envoy_lua_harness.lua"

log() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo "[verify-tenant-routing] $*" >&2
  fi
}

# Hermetic mode answers each probe from the shipped config, not a copy of it:
# a Host outside the HTTPRoute's hostnames is 404 (no route), otherwise the
# real Envoy Lua filter from the policy manifest runs under LuaJIT and its
# local reply (or 200 upstream) is the answer.
HERMETIC_LUA=""
hermetic_setup() {
  local tool
  for tool in yq luajit; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: --hermetic needs $tool on PATH" >&2; exit 2; }
  done
  HERMETIC_LUA="$(mktemp)"
  trap 'rm -f "$HERMETIC_LUA"' EXIT
  yq 'select(.kind == "EnvoyExtensionPolicy") | .spec.lua[0].inline' "$TENANT_POLICY_MANIFEST" >"$HERMETIC_LUA"
  grep -q 'envoy_on_request' "$HERMETIC_LUA" || { echo "ERROR: no Lua filter in $TENANT_POLICY_MANIFEST" >&2; exit 2; }
}

hermetic_status() {
  local host="$1" header_name="$2" header_val="$3" header2_name="${4:-}" header2_val="${5:-}" out
  if ! yq -e ".spec.hostnames[] | select(. == \"$host\")" "$HTTPROUTE_MANIFEST" >/dev/null 2>&1; then
    echo "404"
    return 0
  fi
  local hdr=()
  if [[ -n "$header_name" ]]; then
    hdr+=("${header_name,,}=${header_val//%/%25}")
  fi
  if [[ -n "$header2_name" ]]; then
    hdr+=("${header2_name,,}=${header2_val//%/%25}")
  fi
  if ! out="$(luajit "$LUA_HARNESS" "$HERMETIC_LUA" "${hdr[@]}" 2>&1)"; then
    echo "ERROR: Lua filter raised: $out" >&2
    echo "500"
    return 0
  fi
  if [[ "$out" == *"action=respond"* ]]; then
    sed -n 's/^status=//p' <<<"$out"
  else
    echo "200"
  fi
}

check_http() {
  local host="$1"
  local header_name="$2"
  local header_val="$3"
  local header2_name="${4:-}"
  local header2_val="${5:-}"
  local path="/"
  local ip="$TARGET_IP"
  local port="$TARGET_PORT"

  if [[ "$HERMETIC" == "true" ]]; then
    hermetic_status "$host" "$header_name" "$header_val" "$header2_name" "$header2_val"
    return 0
  fi

  local curl_args=("-s" "-o" "/dev/null" "-w" "%{http_code}" "--max-time" "3")
  curl_args+=("-H" "Host: $host")
  if [[ -n "$header_name" && -n "$header_val" ]]; then
    curl_args+=("-H" "$header_name: $header_val")
  fi
  if [[ -n "$header2_name" && -n "$header2_val" ]]; then
    curl_args+=("-H" "$header2_name: $header2_val")
  fi

  local code
  code="$(curl "${curl_args[@]}" "http://${ip}:${port}${path}" 2>/dev/null || echo "000")"
  if [[ "$code" == "000" && "$ip" == "172.19.0.20" ]]; then
    # Retry on loopback if bridge is not answering
    code="$(curl "${curl_args[@]}" "http://127.0.0.1:${port}${path}" 2>/dev/null || echo "000")"
  fi
  echo "$code"
}

# 1. Manifest Audits
log "Checking HTTPRoute manifest..."
test -f "$HTTPROUTE_MANIFEST" || { echo "ERROR: Missing $HTTPROUTE_MANIFEST" >&2; exit 1; }
grep -q "$CANONICAL_HOST" "$HTTPROUTE_MANIFEST" || { echo "ERROR: HTTPRoute does not contain $CANONICAL_HOST" >&2; exit 1; }
grep -q "signalloom.ai/tenant-hash: \"$CANONICAL_HASH\"" "$HTTPROUTE_MANIFEST" || { echo "ERROR: HTTPRoute missing tenant hash label" >&2; exit 1; }

log "Checking Dex OIDC config manifest..."
test -f "$DEX_CONFIG_MANIFEST" || { echo "ERROR: Missing $DEX_CONFIG_MANIFEST" >&2; exit 1; }
grep -q "https://${CANONICAL_HOST}/auth/callback" "$DEX_CONFIG_MANIFEST" || { echo "ERROR: Dex config missing canonical callback redirect" >&2; exit 1; }

log "Checking Ingress filter policy manifest..."
test -f "$TENANT_POLICY_MANIFEST" || { echo "ERROR: Missing $TENANT_POLICY_MANIFEST" >&2; exit 1; }
grep -q "eap-tenant-kusari" "$TENANT_POLICY_MANIFEST" || { echo "ERROR: Policy targetRef does not match HTTPRoute" >&2; exit 1; }

# 2. Ingress HTTP Probe Matrix
if [[ "$HERMETIC" == "true" ]]; then
  hermetic_setup
fi
RESULTS=()

run_probe() {
  local id="$1"
  local name="$2"
  local host="$3"
  local hdr_name="$4"
  local hdr_val="$5"
  local expected_code="$6"
  local hdr2_name="${7:-}"
  local hdr2_val="${8:-}"

  log "Running probe $id: $name (Host: $host, Header: $hdr_name='$hdr_val')..."
  local actual_code
  actual_code="$(check_http "$host" "$hdr_name" "$hdr_val" "$hdr2_name" "$hdr2_val")"
  local pass=false
  if [[ "$actual_code" == "$expected_code" ]]; then
    pass=true
  fi

  RESULTS+=("{\"id\":\"$id\",\"name\":\"$name\",\"host\":\"$host\",\"header\":\"$hdr_name\",\"value\":\"$hdr_val\",\"expected\":$expected_code,\"actual\":\"$actual_code\",\"pass\":$pass}")

  if [[ "$pass" != "true" ]]; then
    echo "PROBE FAILED: $id ($name) -> Expected $expected_code, Got $actual_code" >&2
    return 1
  fi
}

ERRORS=0
run_probe "P1" "Canonical host + valid X-SignalLoom-Tenant" "$CANONICAL_HOST" "X-SignalLoom-Tenant" "$CANONICAL_TENANT" "200" || ERRORS=$((ERRORS + 1))
run_probe "P2" "Canonical host + valid X-Tenant-ID" "$CANONICAL_HOST" "X-Tenant-ID" "$CANONICAL_TENANT" "200" || ERRORS=$((ERRORS + 1))
run_probe "P3" "Canonical host + inferred tenant (no header)" "$CANONICAL_HOST" "" "" "200" || ERRORS=$((ERRORS + 1))
run_probe "P4" "Canonical host + mismatched tenant header" "$CANONICAL_HOST" "X-SignalLoom-Tenant" "rogue" "403" || ERRORS=$((ERRORS + 1))
run_probe "P5" "Canonical host + mismatched X-Tenant-ID" "$CANONICAL_HOST" "X-Tenant-ID" "unauthorized-org" "403" || ERRORS=$((ERRORS + 1))
run_probe "P6" "Canonical host + legacy typo kurasi header" "$CANONICAL_HOST" "X-Tenant-ID" "$RETIRED_TENANT" "403" || ERRORS=$((ERRORS + 1))
run_probe "P7" "Canonical host + legacy typo hash header" "$CANONICAL_HOST" "X-Tenant-ID" "$RETIRED_HASH" "403" || ERRORS=$((ERRORS + 1))
run_probe "P8" "Case-insensitive whitespace header normalization" "$CANONICAL_HOST" "X-Tenant-ID" "  KUSARI  " "200" || ERRORS=$((ERRORS + 1))
run_probe "P9" "Case-insensitive legacy typo rejection" "$CANONICAL_HOST" "X-Tenant-ID" "  KuRaSi  " "403" || ERRORS=$((ERRORS + 1))
run_probe "P10" "Legacy typo host rejection" "$RETIRED_HOST" "X-Tenant-ID" "$CANONICAL_TENANT" "404" || ERRORS=$((ERRORS + 1))
run_probe "P11" "Canonical demo host routing" "$CANONICAL_DEMO_HOST" "" "" "200" || ERRORS=$((ERRORS + 1))
run_probe "P12" "Canonical X-Tenant-ID cannot launder a mismatched X-SignalLoom-Tenant" "$CANONICAL_HOST" "X-Tenant-ID" "$CANONICAL_TENANT" "403" "X-SignalLoom-Tenant" "rogue" || ERRORS=$((ERRORS + 1))

TOTAL_PROBES="${#RESULTS[@]}"
PASSED_PROBES=$((TOTAL_PROBES - ERRORS))

JSON_REPORT=$(jq -n \
  --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg canonical_host "$CANONICAL_HOST" \
  --arg canonical_tenant "$CANONICAL_TENANT" \
  --arg canonical_hash "$CANONICAL_HASH" \
  --argjson total "$TOTAL_PROBES" \
  --argjson passed "$PASSED_PROBES" \
  --argjson failed "$ERRORS" \
  --argjson hermetic "$HERMETIC" \
  --argjson results "[$(IFS=,; echo "${RESULTS[*]}")]" \
  '{
    card: "SLDC-P3-2",
    timestamp: $timestamp,
    canonical_host: $canonical_host,
    canonical_tenant: $canonical_tenant,
    canonical_hash: $canonical_hash,
    hermetic: $hermetic,
    summary: {
      total: $total,
      passed: $passed,
      failed: $failed,
      status: (if $failed == 0 then "PASS" else "FAIL" end)
    },
    probes: $results
  }')

if [[ -n "$OUTPUT_FILE" ]]; then
  echo "$JSON_REPORT" > "$OUTPUT_FILE"
fi

if [[ "$OUTPUT_JSON" == "true" ]]; then
  echo "$JSON_REPORT"
else
  echo "=============================================================================="
  echo "SLDC-P3-2 Ingress Routing Verification: $PASSED_PROBES / $TOTAL_PROBES probes passed"
  echo "Canonical Host: $CANONICAL_HOST ($CANONICAL_TENANT / $CANONICAL_HASH)"
  echo "Status: $(if [[ $ERRORS -eq 0 ]]; then echo "SUCCESS"; else echo "FAILURE ($ERRORS errors)"; fi)"
  echo "=============================================================================="
fi

if [[ $ERRORS -gt 0 ]]; then
  exit 1
fi
exit 0
