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
HTTPROUTE_MANIFEST="$REPO_ROOT/deploy/eap-tenant-httproute.yaml"
DEX_CONFIG_MANIFEST="$REPO_ROOT/d2-signalloom/infra/dex/dex-config-eap.yaml"
TENANT_POLICY_MANIFEST="$REPO_ROOT/d2-infra/components/ingress/tenant-filter-policy.yaml"

log() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo "[verify-tenant-routing] $*" >&2
  fi
}

check_http() {
  local host="$1"
  local header_name="$2"
  local header_val="$3"
  local path="${4:-/}"
  local ip="$TARGET_IP"
  local port="$TARGET_PORT"

  if [[ "$HERMETIC" == "true" ]]; then
    # Hermetic mock evaluation matching Envoy filter policy rules
    local clean_host="$host"
    local clean_val=""
    if [[ -n "$header_val" ]]; then
      clean_val="$(echo "$header_val" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/^["\x27]|["\x27]$//g')"
    fi

    if [[ "$clean_host" != "$CANONICAL_HOST" && "$clean_host" != "$CANONICAL_DEMO_HOST" ]]; then
      echo "404"
      return 0
    fi

    if [[ -n "$clean_val" ]]; then
      if [[ "$clean_val" == "$RETIRED_TENANT" || "$clean_val" == "$RETIRED_HASH" || ("$clean_val" != "$CANONICAL_TENANT" && "$clean_val" != "$CANONICAL_HASH") ]]; then
        echo "403"
        return 0
      fi
    fi
    echo "200"
    return 0
  fi

  local curl_args=("-s" "-o" "/dev/null" "-w" "%{http_code}" "--max-time" "3")
  curl_args+=("-H" "Host: $host")
  if [[ -n "$header_name" && -n "$header_val" ]]; then
    curl_args+=("-H" "$header_name: $header_val")
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
RESULTS=()

run_probe() {
  local id="$1"
  local name="$2"
  local host="$3"
  local hdr_name="$4"
  local hdr_val="$5"
  local expected_code="$6"

  log "Running probe $id: $name (Host: $host, Header: $hdr_name='$hdr_val')..."
  local actual_code
  actual_code="$(check_http "$host" "$hdr_name" "$hdr_val")"
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
run_probe "P1" "Canonical host + valid X-SignalLoom-Tenant" "$CANONICAL_HOST" "X-SignalLoom-Tenant" "$CANONICAL_TENANT" "200" || ((ERRORS++))
run_probe "P2" "Canonical host + valid X-Tenant-ID" "$CANONICAL_HOST" "X-Tenant-ID" "$CANONICAL_TENANT" "200" || ((ERRORS++))
run_probe "P3" "Canonical host + inferred tenant (no header)" "$CANONICAL_HOST" "" "" "200" || ((ERRORS++))
run_probe "P4" "Canonical host + mismatched tenant header" "$CANONICAL_HOST" "X-SignalLoom-Tenant" "rogue" "403" || ((ERRORS++))
run_probe "P5" "Canonical host + mismatched X-Tenant-ID" "$CANONICAL_HOST" "X-Tenant-ID" "unauthorized-org" "403" || ((ERRORS++))
run_probe "P6" "Canonical host + legacy typo kurasi header" "$CANONICAL_HOST" "X-Tenant-ID" "$RETIRED_TENANT" "403" || ((ERRORS++))
run_probe "P7" "Canonical host + legacy typo hash header" "$CANONICAL_HOST" "X-Tenant-ID" "$RETIRED_HASH" "403" || ((ERRORS++))
run_probe "P8" "Case-insensitive whitespace header normalization" "$CANONICAL_HOST" "X-Tenant-ID" "  KUSARI  " "200" || ((ERRORS++))
run_probe "P9" "Case-insensitive legacy typo rejection" "$CANONICAL_HOST" "X-Tenant-ID" "  KuRaSi  " "403" || ((ERRORS++))
run_probe "P10" "Legacy typo host rejection" "$RETIRED_HOST" "X-Tenant-ID" "$CANONICAL_TENANT" "404" || ((ERRORS++))
run_probe "P11" "Canonical demo host routing" "$CANONICAL_DEMO_HOST" "" "" "200" || ((ERRORS++))

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
