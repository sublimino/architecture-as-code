#!/usr/bin/env bash
# ==============================================================================
# Signal Loom Tailscale On-Demand EAP Provisioning & Dynamic Routing Script
#
# Provides deterministic salted customer hashing, Tailscale mesh provisioning,
# Serve/Funnel automation, and idempotent teardown. Supports TAILSCALE_MOCK=1
# for offline development and containerized CI environments.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${EAP_BACKEND_PORT:-8080}"
MOCK_DIR="${TAILSCALE_MOCK_DIR:-/tmp/tailscale-eap-mock}"

# Auto-detect mock mode if tailscale CLI binary is missing
if ! command -v tailscale >/dev/null 2>&1; then
  TAILSCALE_MOCK=1
else
  TAILSCALE_MOCK="${TAILSCALE_MOCK:-0}"
fi

resolve_salt() {
  if [[ -n "${SIGNAL_LOOM_EAP_SALT:-}" ]]; then
    printf '%s' "$SIGNAL_LOOM_EAP_SALT"
    return 0
  fi
  if [[ -n "${BAO_ADDR:-}" ]] && command -v bao >/dev/null 2>&1; then
    local s
    if s="$(bao kv get -field=salt secret/signalloom/eap 2>/dev/null)" && [[ -n "$s" ]]; then
      printf '%s' "$s"
      return 0
    fi
  fi
  echo "ERROR: EAP salt unavailable: set SIGNAL_LOOM_EAP_SALT or provision secret/signalloom/eap in OpenBao" >&2
  exit 2
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [arguments]

Commands:
  hash <company-name>             Derive 8-char hex hash using canonical salt
  urls <company-name>             Print internal mesh and MagicDNS URLs for company
  provision <company-name>        Provision and join Tailscale mesh node (sl-eap-HASH)
  serve <company-name> [port]     Configure Tailscale Serve proxying 443 to backend port
  funnel <company-name>           Enable Tailscale Funnel for public UAT (*.ts.net)
  status [company-name]           Display current node status and routing details
  teardown <company-name>         Reset proxy and log out Tailscale node idempotently
  help                            Show this help message

Environment Variables:
  SIGNAL_LOOM_EAP_SALT            Cryptographic salt (required if OpenBao not provisioned)
  TAILSCALE_AUTH_KEY              Tailscale pre-auth key for non-interactive up
  TAILSCALE_MOCK                  Force mock mode (1=mock, 0=live, default: auto)
  EAP_BACKEND_PORT                Target backend port for serve proxy (default: 8080)
EOF
}

normalize_company() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "ERROR: Company name cannot be empty" >&2
    return 1
  fi
  # Lowercase and trim whitespace
  printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | xargs
}

calc_hash() {
  local company; company="$(normalize_company "${1:-}")"
  local salt; salt="$(resolve_salt)"
  local payload="${salt}:${company}"
  local full_hash
  if command -v sha256sum >/dev/null 2>&1; then
    full_hash="$(printf '%s' "$payload" | sha256sum | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    full_hash="$(printf '%s' "$payload" | shasum -a 256 | awk '{print $1}')"
  else
    python3 -c "import hashlib, sys; print(hashlib.sha256(b'$payload').hexdigest())"
  fi
  printf '%s' "${full_hash:0:8}"
}

cmd_hash() {
  local company="${1:-}"
  if [[ -z "$company" ]]; then
    echo "Usage: $(basename "$0") hash <company-name>" >&2
    exit 1
  fi
  calc_hash "$company"
  echo ""
}

cmd_urls() {
  local company="${1:-}"
  if [[ -z "$company" ]]; then
    echo "Usage: $(basename "$0") urls <company-name>" >&2
    exit 1
  fi
  local h; h="$(calc_hash "$company")"
  local host="sl-eap-${h}"
  cat <<EOF
{
  "company_name": "$company",
  "customer_hash": "$h",
  "hostname": "$host",
  "internal_mesh_url": "https://${host}.tailscale",
  "external_fqdn": "https://${host}.ts.net"
}
EOF
}

cmd_provision() {
  local company="${1:-}"
  if [[ -z "$company" ]]; then
    echo "Usage: $(basename "$0") provision <company-name>" >&2
    exit 1
  fi
  local h; h="$(calc_hash "$company")"
  local host="sl-eap-${h}"

  echo "==> Provisioning EAP Tailscale node for '$company' (hostname: $host)..."

  if [[ "$TAILSCALE_MOCK" == "1" ]]; then
    mkdir -p "$MOCK_DIR/$host"
    cat > "$MOCK_DIR/$host/state.json" <<EOF
{
  "hostname": "$host",
  "customer_hash": "$h",
  "company_name": "$company",
  "state": "Running",
  "ipv4": "100.64.0.$(( 16#${h:0:2} % 250 + 1 ))",
  "ipv6": "fd7a:115c:a1e0::$h",
  "dns_name": "${host}.ts.net",
  "provisioned_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "mock": true
}
EOF
    echo "    [MOCK] Node '$host' successfully provisioned and joined tailnet."
    return 0
  fi

  local auth_args=()
  if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
    auth_args=("--authkey=${TAILSCALE_AUTH_KEY}")
  fi

  tailscale up \
    --hostname="$host" \
    --accept-dns=false \
    "${auth_args[@]}"
  echo "    Node '$host' online in tailnet."
}

cmd_serve() {
  local company="${1:-}"
  local target_port="${2:-$PORT}"
  if [[ -z "$company" ]]; then
    echo "Usage: $(basename "$0") serve <company-name> [port]" >&2
    exit 1
  fi
  local h; h="$(calc_hash "$company")"
  local host="sl-eap-${h}"

  echo "==> Configuring Tailscale Serve proxy for '$host' -> 127.0.0.1:$target_port..."

  if [[ "$TAILSCALE_MOCK" == "1" ]]; then
    mkdir -p "$MOCK_DIR/$host"
    cat > "$MOCK_DIR/$host/serve.json" <<EOF
{
  "hostname": "$host",
  "target_port": $target_port,
  "serve_status": "Active",
  "https_url": "https://${host}.tailscale",
  "configured_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "mock": true
}
EOF
    echo "    [MOCK] Serve active at https://${host}.tailscale proxying to 127.0.0.1:$target_port."
    return 0
  fi

  tailscale serve --bg --https=443 "http://127.0.0.1:$target_port"
  echo "    Serve configured: https://${host}.tailscale -> http://127.0.0.1:$target_port."
}

cmd_funnel() {
  local company="${1:-}"
  if [[ -z "$company" ]]; then
    echo "Usage: $(basename "$0") funnel <company-name>" >&2
    exit 1
  fi
  local h; h="$(calc_hash "$company")"
  local host="sl-eap-${h}"

  echo "==> Enabling Tailscale Funnel for '$host'..."

  if [[ "$TAILSCALE_MOCK" == "1" ]]; then
    mkdir -p "$MOCK_DIR/$host"
    cat > "$MOCK_DIR/$host/funnel.json" <<EOF
{
  "hostname": "$host",
  "funnel_status": "Active",
  "public_url": "https://${host}.ts.net",
  "configured_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "mock": true
}
EOF
    echo "    [MOCK] Funnel enabled: https://${host}.ts.net is live."
    return 0
  fi

  tailscale funnel --bg 443 on
  echo "    Funnel enabled: https://${host}.ts.net."
}

cmd_status() {
  local company="${1:-}"
  if [[ -n "$company" ]]; then
    local h; h="$(calc_hash "$company")"
    local host="sl-eap-${h}"
    if [[ "$TAILSCALE_MOCK" == "1" ]]; then
      if [[ -f "$MOCK_DIR/$host/state.json" ]]; then
        cat "$MOCK_DIR/$host/state.json"
        echo ""
      else
        echo "{\"hostname\": \"$host\", \"state\": \"NotProvisioned\", \"mock\": true}"
      fi
      return 0
    fi
    tailscale status --json | grep -A 10 "$host" || tailscale status
  else
    if [[ "$TAILSCALE_MOCK" == "1" ]]; then
      echo "{\"mock_mode\": true, \"mock_dir\": \"$MOCK_DIR\", \"nodes\": $(ls -1 "$MOCK_DIR" 2>/dev/null | wc -l)}"
      return 0
    fi
    tailscale status
  fi
}

cmd_teardown() {
  local company="${1:-}"
  if [[ -z "$company" ]]; then
    echo "Usage: $(basename "$0") teardown <company-name>" >&2
    exit 1
  fi
  local h; h="$(calc_hash "$company")"
  local host="sl-eap-${h}"

  echo "==> Tearing down EAP Tailscale node for '$company' ($host)..."

  if [[ "$TAILSCALE_MOCK" == "1" ]]; then
    rm -rf "$MOCK_DIR/$host"
    echo "    [MOCK] Node '$host' mock state cleared cleanly."
    return 0
  fi

  # Reset serve and funnel if active
  tailscale serve reset 2>/dev/null || true
  tailscale funnel reset 2>/dev/null || true
  # Logout if logged in
  tailscale logout 2>/dev/null || true
  echo "    Teardown complete for '$host'."
}

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    hash)      cmd_hash "$@" ;;
    urls)      cmd_urls "$@" ;;
    provision) cmd_provision "$@" ;;
    serve)     cmd_serve "$@" ;;
    funnel)    cmd_funnel "$@" ;;
    status)    cmd_status "$@" ;;
    teardown)  cmd_teardown "$@" ;;
    help|--help|-h) usage ;;
    *)
      echo "ERROR: Unknown command '$cmd'" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
