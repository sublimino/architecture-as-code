#!/usr/bin/env bash
# public-tunnel.sh — Expose the SignalLoom dashboard publicly via an ngrok tunnel.
#
# Subcommands:
#   up      Start port-forward + ngrok, patch Dex for the public URL, print access info
#   down    Tear down tunnel, restore Dex config
#   status  Show tunnel status and URL
#   url     Print the public URL (for scripting; exits 1 if no tunnel)
#
# The tunnel bypasses the Envoy Gateway and port-forwards directly to the
# dashboard nginx (dashboard-signalloom:8080). nginx already proxies /dex/,
# /api/, /supercred-api/, /dashboard/ etc. to their in-cluster backends, so the
# full OIDC flow works without any Gateway SNI matching.
#
# Dex's issuer and redirect URIs are patched to match the ngrok URL. On teardown
# the original secret is restored from a backup taken at tunnel-up time.
#
# Security: a ngrok traffic policy auto-sets a cookie on first browser visit.
# Requests without the cookie get a gate page instead of the dashboard. This
# blocks scrapers and bots but lets anyone with a browser through — appropriate
# for a demo share link, not for production.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/wait.sh
source "${SCRIPT_DIR}/lib/wait.sh"

# ── Configuration ────────────────────────────────────────────────────
TUNNEL_DIR="${REPO_ROOT}/.tunnel"
PF_PID_FILE="${TUNNEL_DIR}/pf.pid"
NGROK_PID_FILE="${TUNNEL_DIR}/ngrok.pid"
NGROK_URL_FILE="${TUNNEL_DIR}/ngrok-url"
NGROK_LOG_FILE="${TUNNEL_DIR}/ngrok.log"
COOKIE_TOKEN_FILE="${TUNNEL_DIR}/cookie-token"
DEX_BACKUP_FILE="${TUNNEL_DIR}/dex-backup.yaml"
POLICY_FILE="${TUNNEL_DIR}/traffic-policy.yaml"
SNAP_POLICY_COPY="${REPO_ROOT}/tunnel-policy.yaml"

DEX_NAMESPACE="inf-signalloom"
DEX_SECRET_NAME="dex-local-auth"
DEX_DEPLOYMENT="dex"
DASHBOARD_NAMESPACE="fe-signalloom"
DASHBOARD_SERVICE="dashboard-signalloom"
DASHBOARD_PORT=8080
LOCAL_PORT="${PUBLIC_LOCAL_PORT:-19080}"
NGROK_API="http://127.0.0.1:4040/api/tunnels"

# Original values for Dex restore validation.
ORIGINAL_ISSUER="https://dashboard.osramp.acme.local:30754/dex"

# ── Helpers ──────────────────────────────────────────────────────────
find_ngrok() {
  if [[ -n "${NGROK_BIN:-}" ]] && [[ -x "$NGROK_BIN" ]]; then
    echo "$NGROK_BIN"; return
  fi
  for candidate in /snap/bin/ngrok "$HOME/bin/ngrok" /usr/local/bin/ngrok; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return; fi
  done
  if command -v ngrok >/dev/null 2>&1; then command -v ngrok; return; fi
  return 1
}

ensure_ngrok() {
  if find_ngrok >/dev/null 2>&1; then return 0; fi

  echo "==> ngrok not found — downloading standalone binary..."
  local dest="${HOME}/bin/ngrok"
  mkdir -p "$(dirname "$dest")"
  local url="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz"
  curl -fsSL "$url" | tar -xzf - -C "$(dirname "$dest")" ngrok
  chmod +x "$dest"
  echo "==> Installed ngrok to ${dest}"

  if [[ -n "${NGROK_AUTHTOKEN:-}" ]]; then
    "$dest" config add-authtoken "$NGROK_AUTHTOKEN"
  fi

  if ! "$dest" config check >/dev/null 2>&1; then
    echo "ERROR: ngrok authtoken not configured." >&2
    echo "       Set NGROK_AUTHTOKEN or run: ngrok config add-authtoken <token>" >&2
    return 1
  fi
}

pid_alive() {
  [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null
}

kill_pid_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local pid
    pid="$(cat "$file")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      # Wait briefly for clean shutdown.
      local i=0
      while kill -0 "$pid" 2>/dev/null && ((i < 10)); do
        sleep 0.5
        ((i++))
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$file"
  fi
}

# ── Traffic policy ───────────────────────────────────────────────────
generate_traffic_policy() {
  local token="$1"
  # Single rule: if the cookie is ABSENT, return a gate page that sets the
  # cookie and meta-refreshes. If the cookie IS present, no rule matches
  # and the request passes straight through to the upstream.
  #
  # The 302+Set-Cookie approach does NOT work with ngrok custom-responses
  # (tested 2026-08-02). Use 200+meta-refresh instead.
  cat > "$POLICY_FILE" <<EOF
on_http_request:
  - name: cookie-gate
    expressions:
      - "!(req.headers.exists(k, k == 'cookie') && req.headers['cookie'].exists(v, v.contains('_sl_gate=${token}')))"
    actions:
      - type: custom-response
        config:
          status_code: 200
          headers:
            content-type: "text/html; charset=utf-8"
            set-cookie: "_sl_gate=${token}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=86400"
          body: '<html><head><meta http-equiv="refresh" content="0"></head><body style="background:#0f172a;color:#94a3b8;font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh;margin:0"><p>Authorizing\u2026</p></body></html>'
EOF
}

# ── Dex secret management ───────────────────────────────────────────
backup_dex_secret() {
  # Store only the config.yaml content, not the full k8s YAML. The full
  # object carries resourceVersion which goes stale the moment we patch,
  # making `kubectl apply` fail with a conflict on restore.
  kubectl get secret "$DEX_SECRET_NAME" -n "$DEX_NAMESPACE" \
    -o jsonpath='{.data.config\.yaml}' | base64 -d > "$DEX_BACKUP_FILE"
  echo "    Dex config backed up to ${DEX_BACKUP_FILE}"
}

patch_dex_secret() {
  local ngrok_url="$1"
  local config
  config=$(kubectl get secret "$DEX_SECRET_NAME" -n "$DEX_NAMESPACE" \
    -o jsonpath='{.data.config\.yaml}' | base64 -d)

  # Replace the issuer.
  config=$(echo "$config" | sed "s|issuer: ${ORIGINAL_ISSUER}|issuer: ${ngrok_url}/dex|")

  # Add the ngrok callback to redirectURIs (after the last existing entry).
  config=$(echo "$config" | sed "/- http:\/\/localhost:5173\/callback/a\\          - ${ngrok_url}/callback")

  # Reconstruct and apply. Preserves labels via --save-config.
  kubectl create secret generic "$DEX_SECRET_NAME" \
    -n "$DEX_NAMESPACE" \
    --from-literal="config.yaml=${config}" \
    --dry-run=client -o yaml \
    | kubectl apply -f -

  # Re-apply the labels the Kustomization expects.
  kubectl label secret "$DEX_SECRET_NAME" -n "$DEX_NAMESPACE" \
    app.kubernetes.io/name=dex \
    app.kubernetes.io/part-of=signalloom-demo \
    --overwrite

  echo "    Dex issuer patched to ${ngrok_url}/dex"
  kubectl rollout restart "deployment/${DEX_DEPLOYMENT}" -n "$DEX_NAMESPACE"
  sleep 2
  wait_rollout "$DEX_DEPLOYMENT" -n "$DEX_NAMESPACE" 120
  echo "    Dex restarted and ready"
}

restore_dex_secret() {
  if [[ ! -f "$DEX_BACKUP_FILE" ]]; then
    echo "    No Dex backup found — skipping restore"
    return 0
  fi
  local config
  config="$(cat "$DEX_BACKUP_FILE")"

  kubectl create secret generic "$DEX_SECRET_NAME" \
    -n "$DEX_NAMESPACE" \
    --from-literal="config.yaml=${config}" \
    --dry-run=client -o yaml \
    | kubectl apply -f -

  kubectl label secret "$DEX_SECRET_NAME" -n "$DEX_NAMESPACE" \
    app.kubernetes.io/name=dex \
    app.kubernetes.io/part-of=signalloom-demo \
    --overwrite

  echo "    Dex config restored from backup"
  kubectl rollout restart "deployment/${DEX_DEPLOYMENT}" -n "$DEX_NAMESPACE"
  sleep 2
  wait_rollout "$DEX_DEPLOYMENT" -n "$DEX_NAMESPACE" 120
  echo "    Dex restarted and ready"
}

# ── ngrok URL extraction ─────────────────────────────────────────────
extract_ngrok_url() {
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    local url
    url=$(curl -fsS "$NGROK_API" 2>/dev/null \
      | jq -r '.tunnels[0].public_url // empty' 2>/dev/null) || true
    if [[ -n "$url" ]]; then
      echo "$url" > "$NGROK_URL_FILE"
      echo "$url"
      return 0
    fi
    sleep 1
  done
  echo "ERROR: Failed to extract ngrok URL within 30s" >&2
  echo "       Check ${NGROK_LOG_FILE} for errors" >&2
  return 1
}

# ── Port-forward ─────────────────────────────────────────────────────
start_port_forward() {
  # Guard against port already in use.
  if ss -tlnp 2>/dev/null | grep -q ":${LOCAL_PORT} "; then
    echo "ERROR: port ${LOCAL_PORT} already bound" >&2
    echo "       Set PUBLIC_LOCAL_PORT to a different value" >&2
    return 1
  fi

  kubectl port-forward -n "$DASHBOARD_NAMESPACE" \
    "svc/${DASHBOARD_SERVICE}" "${LOCAL_PORT}:${DASHBOARD_PORT}" &>/dev/null &
  echo $! > "$PF_PID_FILE"
  echo "    port-forward: ${DASHBOARD_NAMESPACE}/${DASHBOARD_SERVICE} → localhost:${LOCAL_PORT}"

  wait_tcp 127.0.0.1 "$LOCAL_PORT" 30
}

# ── Subcommands ──────────────────────────────────────────────────────
cmd_up() {
  # Idempotent: if tunnel is already running, just print info.
  if pid_alive "$NGROK_PID_FILE" && pid_alive "$PF_PID_FILE" && [[ -f "$NGROK_URL_FILE" ]]; then
    local url
    url="$(cat "$NGROK_URL_FILE")"
    echo "Tunnel is already running."
    print_access_info "$url"
    return 0
  fi

  # Clean up any partial state from a previous crash.
  cmd_down_quiet

  ensure_ngrok
  local ngrok_bin
  ngrok_bin="$(find_ngrok)"

  mkdir -p "$TUNNEL_DIR"

  echo "════════════════════════════════════════════════════════════"
  echo "  SignalLoom — Public Tunnel"
  echo "════════════════════════════════════════════════════════════"
  echo ""

  # 1. Cookie gate token.
  local token
  token="$(openssl rand -hex 16)"
  echo "$token" > "$COOKIE_TOKEN_FILE"
  echo "==> Cookie gate token generated"

  # 2. Traffic policy.
  generate_traffic_policy "$token"
  echo "==> Traffic policy written"

  # 3. Backup Dex secret.
  echo "==> Backing up Dex secret..."
  backup_dex_secret

  # 4. Port-forward.
  echo "==> Starting port-forward..."
  start_port_forward

  # 5. ngrok tunnel.
  echo "==> Starting ngrok tunnel..."
  local policy_path="$POLICY_FILE"
  # Snap confinement workaround: snap apps cannot read hidden directories.
  if [[ "$ngrok_bin" == /snap/* ]]; then
    cp "$POLICY_FILE" "$SNAP_POLICY_COPY"
    policy_path="$SNAP_POLICY_COPY"
  fi

  "$ngrok_bin" http "$LOCAL_PORT" \
    --traffic-policy-file="$policy_path" \
    --log=stdout --log-format=json > "$NGROK_LOG_FILE" 2>&1 &
  echo $! > "$NGROK_PID_FILE"

  # 6. Extract URL.
  echo "==> Waiting for ngrok URL..."
  local url
  url="$(extract_ngrok_url)"
  echo "    ${url}"

  # 7. Patch Dex.
  echo "==> Patching Dex for public URL..."
  patch_dex_secret "$url"

  echo ""
  print_access_info "$url"
}

print_access_info() {
  local url="$1"
  echo "════════════════════════════════════════════════════════════"
  echo "  SignalLoom is now publicly accessible"
  echo "════════════════════════════════════════════════════════════"
  echo ""
  echo "  URL:         ${url}"
  echo "  Credentials: demo-user@signalloom.local / demo-user"
  echo ""
  echo "  The cookie gate auto-authenticates on first browser visit."
  echo "  Share the URL directly — no token needed."
  echo ""
  echo "  Remote test:  make public-test"
  echo "  Tear down:    make public-down"
  echo ""
  echo "════════════════════════════════════════════════════════════"
}

cmd_down() {
  echo "==> Tearing down public tunnel..."

  # 1. Restore Dex.
  echo "==> Restoring Dex secret..."
  restore_dex_secret

  cmd_down_quiet

  echo "==> Public tunnel torn down."
}

# Quiet teardown for cleanup during up (no Dex restore).
cmd_down_quiet() {
  kill_pid_file "$NGROK_PID_FILE"
  kill_pid_file "$PF_PID_FILE"
  rm -f "$SNAP_POLICY_COPY"
  rm -rf "$TUNNEL_DIR"
}

cmd_status() {
  local running=true
  if ! pid_alive "$NGROK_PID_FILE"; then
    echo "ngrok: not running"
    running=false
  else
    echo "ngrok: running (PID $(cat "$NGROK_PID_FILE"))"
  fi

  if ! pid_alive "$PF_PID_FILE"; then
    echo "port-forward: not running"
    running=false
  else
    echo "port-forward: running (PID $(cat "$PF_PID_FILE"))"
  fi

  if [[ -f "$NGROK_URL_FILE" ]] && $running; then
    echo "url: $(cat "$NGROK_URL_FILE")"
    return 0
  fi
  return 1
}

cmd_url() {
  if [[ -f "$NGROK_URL_FILE" ]] && pid_alive "$NGROK_PID_FILE"; then
    cat "$NGROK_URL_FILE"
    return 0
  fi
  echo "ERROR: no tunnel running" >&2
  return 1
}

# ── Main ─────────────────────────────────────────────────────────────
case "${1:-}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  url)    cmd_url ;;
  *)
    echo "Usage: $0 {up|down|status|url}" >&2
    echo "" >&2
    echo "  up      Start port-forward + ngrok, patch Dex, print access info" >&2
    echo "  down    Tear down tunnel, restore Dex config" >&2
    echo "  status  Show tunnel status and URL" >&2
    echo "  url     Print the public URL (for scripting)" >&2
    exit 1
    ;;
esac
