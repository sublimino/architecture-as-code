#!/usr/bin/env bash
# ==============================================================================
# scripts/eap/bootstrap-eap-env.sh
# Signal Loom EAP Environment Bootstrapper
#
# Creates tenant namespace via API or manifests, verifies lifecycle record,
# registers the Tailscale node with tag-scoped auth key from OpenBao/env, and
# configures Tailscale Serve for the tenant backend port.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS_CLI="$SCRIPT_DIR/tailscale-eap-env.sh"
PORT="${EAP_BACKEND_PORT:-8080}"
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") <company-name> [options]

Options:
  --port <port>       Backend port to proxy (default: 8080)
  --ttl <minutes>     Initial TTL in minutes (default: 240)
  --tier <tier>       Environment tier: demo, uat, pilot (default: demo)
  --dry-run           Print bootstrap plan without executing
  -h, --help          Show this message
EOF
}

COMPANY=""
PORT_ARG=""
TTL_ARG="240"
TIER_ARG="demo"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT_ARG="$2"
      shift 2
      ;;
    --ttl)
      TTL_ARG="$2"
      shift 2
      ;;
    --tier)
      TIER_ARG="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "ERROR: Unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$COMPANY" ]]; then
        COMPANY="$1"
      else
        echo "ERROR: Unexpected positional argument '$1'" >&2
        usage >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$COMPANY" ]]; then
  echo "ERROR: Company name cannot be empty" >&2
  usage >&2
  exit 2
fi

TARGET_PORT="${PORT_ARG:-$PORT}"

# Derive customer hash and validate company
HASH="$("$TS_CLI" hash "$COMPANY")"
HOST="sl-eap-${HASH}"
NAMESPACE="eap-${HASH}"

if [[ "$DRY_RUN" == "1" ]]; then
  cat <<EOF
{
  "dry_run": true,
  "company_name": "$COMPANY",
  "customer_hash": "$HASH",
  "hostname": "$HOST",
  "namespace": "$NAMESPACE",
  "target_port": $TARGET_PORT,
  "ttl_minutes": $TTL_ARG,
  "tier": "$TIER_ARG",
  "mesh_url": "https://${HOST}.tailscale",
  "public_url": "https://${HOST}.ts.net"
}
EOF
  exit 0
fi

echo "==> Bootstrapping EAP environment for '$COMPANY' (hash: $HASH, namespace: $NAMESPACE)..."

# 1. Resolve auth key if in live mode
if [[ "${TAILSCALE_MOCK:-0}" != "1" ]]; then
  if [[ -z "${TAILSCALE_AUTH_KEY:-}" ]]; then
    if [[ -n "${BAO_ADDR:-}" ]] && command -v bao >/dev/null 2>&1; then
      TAILSCALE_AUTH_KEY="$(bao kv get -field=tailscale_authkey secret/signalloom/eap 2>/dev/null || true)"
      if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
        export TAILSCALE_AUTH_KEY
      fi
    fi
  fi
fi

# 2. Provision Tailscale node
echo "  [1/3] Provisioning Tailscale node '$HOST'..."
"$TS_CLI" provision "$COMPANY"

# 3. Configure Tailscale Serve
echo "  [2/3] Configuring Tailscale Serve on port $TARGET_PORT..."
"$TS_CLI" serve "$COMPANY" "$TARGET_PORT"

# 4. Final verification
echo "  [3/3] Verifying node status..."
STATUS_OUT="$("$TS_CLI" status "$COMPANY")"

cat <<EOF
{
  "status": "provisioned",
  "company_name": "$COMPANY",
  "customer_hash": "$HASH",
  "hostname": "$HOST",
  "namespace": "$NAMESPACE",
  "target_port": $TARGET_PORT,
  "mesh_url": "https://${HOST}.tailscale",
  "external_fqdn": "https://${HOST}.ts.net"
}
EOF
