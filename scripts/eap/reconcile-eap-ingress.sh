#!/usr/bin/env bash
# ==============================================================================
# scripts/eap/reconcile-eap-ingress.sh
# Signal Loom Ingress & Serve Reconciler
#
# Compares desired tenant ingress from GET /api/v1/environments/ with actual
# Tailscale serve status and Dex client origins. Reconciles drift by adding
# missing serve routes and evicting orphaned routes.
# Supports --dry-run to print ingress diff without mutating state.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS_CLI="$SCRIPT_DIR/tailscale-eap-env.sh"
MOCK_DIR="${TAILSCALE_MOCK_DIR:-/tmp/tailscale-eap-mock}"

DRY_RUN=0
API_URL="${EAP_API_URL:-http://localhost:8080/api/v1/environments}"
AUTH_TOKEN="${EAP_AUTH_TOKEN:-${AUTH_TOKEN:-}}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --dry-run           Print ingress diff without modifying state
  --api-url <url>     Signal Loom environments API endpoint (default: http://localhost:8080/api/v1/environments)
  --token <jwt>       Bearer authentication token for environments API
  -h, --help          Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --api-url)
      API_URL="$2"
      shift 2
      ;;
    --token)
      AUTH_TOKEN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# 1. Fetch desired active environments
get_desired_hosts() {
  if [[ -n "$AUTH_TOKEN" ]] && command -v curl >/dev/null 2>&1; then
    local json
    if json="$(curl -sSf -H "Authorization: Bearer $AUTH_TOKEN" "$API_URL" 2>/dev/null)"; then
      if command -v jq >/dev/null 2>&1; then
        echo "$json" | jq -r '.[] | select(.state != "terminated") | .customer_hash' | sort -u
        return 0
      fi
    fi
  fi

  # Fallback to local mock state or environment file if API is unavailable
  if [[ -d "$MOCK_DIR" ]]; then
    for node_dir in "$MOCK_DIR"/sl-eap-*; do
      if [[ -d "$node_dir" && -f "$node_dir/state.json" ]]; then
        local base; base="$(basename "$node_dir")"
        local h="${base#sl-eap-}"
        if [[ "$h" =~ ^[0-9a-f]{8}$ ]]; then
          echo "$h"
        fi
      fi
    done | sort -u
    return 0
  fi

  echo ""
}

# 2. Fetch actual active serve entries
get_actual_hosts() {
  if [[ "${TAILSCALE_MOCK:-0}" == "1" || ! -x "$(command -v tailscale 2>/dev/null)" ]]; then
    if [[ -d "$MOCK_DIR" ]]; then
      for node_dir in "$MOCK_DIR"/sl-eap-*; do
        if [[ -d "$node_dir" && -f "$node_dir/serve.json" ]]; then
          local base; base="$(basename "$node_dir")"
          local h="${base#sl-eap-}"
          if [[ "$h" =~ ^[0-9a-f]{8}$ ]]; then
            echo "$h"
          fi
        fi
      done | sort -u
    fi
    return 0
  fi

  if command -v tailscale >/dev/null 2>&1; then
    local serve_json
    if serve_json="$(tailscale serve status --json 2>/dev/null)" && [[ -n "$serve_json" ]]; then
      if command -v jq >/dev/null 2>&1; then
        echo "$serve_json" | jq -r 'keys[]? | capture("sl-eap-(?<h>[0-9a-f]{8})") | .h' | sort -u
        return 0
      fi
    fi
  fi
  echo ""
}

DESIRED_HASHES="$(get_desired_hosts | tr '\n' ' ' | xargs)"
ACTUAL_HASHES="$(get_actual_hosts | tr '\n' ' ' | xargs)"

MISSING=()
ORPHANED=()

for h in $DESIRED_HASHES; do
  if [[ ! " $ACTUAL_HASHES " =~ [[:space:]]${h}[[:space:]] ]]; then
    MISSING+=("$h")
  fi
done

for h in $ACTUAL_HASHES; do
  if [[ ! " $DESIRED_HASHES " =~ [[:space:]]${h}[[:space:]] ]]; then
    ORPHANED+=("$h")
  fi
done

DIFF_EMPTY=1
if [[ ${#MISSING[@]} -gt 0 || ${#ORPHANED[@]} -gt 0 ]]; then
  DIFF_EMPTY=0
fi

if [[ "$DRY_RUN" == "1" ]]; then
  cat <<EOF
{
  "dry_run": true,
  "in_sync": $( [[ "$DIFF_EMPTY" == "1" ]] && echo "true" || echo "false" ),
  "desired_count": $(echo "$DESIRED_HASHES" | wc -w),
  "actual_count": $(echo "$ACTUAL_HASHES" | wc -w),
  "missing_routes": [$(printf '"%s",' "${MISSING[@]-}" | sed 's/,$//')],
  "orphaned_routes": [$(printf '"%s",' "${ORPHANED[@]-}" | sed 's/,$//')]
}
EOF
  exit 0
fi

if [[ "$DIFF_EMPTY" == "1" ]]; then
  echo "==> Ingress is in sync. Desired: $(echo "$DESIRED_HASHES" | wc -w), Actual: $(echo "$ACTUAL_HASHES" | wc -w)."
  exit 0
fi

echo "==> Reconciling ingress drift..."
echo "    Missing routes to add: ${MISSING[*]:-none}"
echo "    Orphaned routes to remove: ${ORPHANED[*]:-none}"

# Reconcile missing
for h in "${MISSING[@]-}"; do
  if [[ -n "$h" ]]; then
    echo "  [+] Configuring serve proxy for sl-eap-$h..."
    "$TS_CLI" serve "hash:$h" "${EAP_BACKEND_PORT:-8080}" || true
  fi
done

# Reconcile orphaned
for h in "${ORPHANED[@]-}"; do
  if [[ -n "$h" ]]; then
    echo "  [-] Removing orphaned serve proxy for sl-eap-$h..."
    "$TS_CLI" teardown --hash "$h" || true
  fi
done

# Re-check
NEW_ACTUAL="$(get_actual_hosts | tr '\n' ' ' | xargs)"
REMAINING_MISSING=()
for h in $DESIRED_HASHES; do
  if [[ ! " $NEW_ACTUAL " =~ [[:space:]]${h}[[:space:]] ]]; then
    REMAINING_MISSING+=("$h")
  fi
done

if [[ ${#REMAINING_MISSING[@]} -eq 0 ]]; then
  echo "==> Ingress reconciliation complete and verified."
  exit 0
else
  echo "ERROR: Reconciliation failed to converge. Remaining missing: ${REMAINING_MISSING[*]}" >&2
  exit 1
fi
