#!/usr/bin/env bash
# public-tunnel.sh — Expose the SignalLoom dashboard via Tailscale (serve & funnel).
#
# Unified remote and public entry point for both local Kind and GCP demo estates.
#
# Subcommands:
#   serve         Expose SignalLoom on the private Tailnet via 'tailscale serve'
#   funnel        Expose SignalLoom to the public internet via 'tailscale funnel'
#   up            Alias for 'funnel' (public exposure)
#   serve-down    Stop serving on the Tailnet and release Dex origin
#   funnel-down   Remove the public Funnel listener (leaves Tailnet serve active)
#   down          Full teardown: stop Funnel, reset Serve, kill forward, restore Dex origin
#   status        Show Tailscale status, MagicDNS URL, port-forward, and Dex origin lease
#   url           Print the active public/serve URL (exits 1 if not active)
#   test          Run health and OIDC redirect verification against the active URL
#
# If ENV=<lane> is set or --env <lane> is passed, this script automatically
# delegates to scripts/gcp-tf/demo-up.sh so that public-tunnel.sh is the single
# unified entry point across all environments.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Unified GCP lane delegation ──────────────────────────────────────
# If ENV is set or --env <lane> is passed, route to the GCP demo driver.
GCP_ENV="${ENV:-}"
FILTERED_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      GCP_ENV="$2"
      shift 2
      ;;
    --env=*)
      GCP_ENV="${1#*=}"
      shift
      ;;
    *)
      FILTERED_ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${FILTERED_ARGS[@]:-}"

if [[ -n "$GCP_ENV" ]]; then
  GCP_SCRIPT="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"
  if [[ ! -x "$GCP_SCRIPT" ]]; then
    echo "ERROR: GCP driver ${GCP_SCRIPT} is missing or not executable." >&2
    exit 2
  fi
  subcmd="${1:-status}"
  case "$subcmd" in
    serve|ts-up)
      exec env ENV="$GCP_ENV" "$GCP_SCRIPT" ts-up
      ;;
    funnel|funnel-up|up|public)
      exec env ENV="$GCP_ENV" "$GCP_SCRIPT" funnel-up
      ;;
    funnel-down)
      exec env ENV="$GCP_ENV" "$GCP_SCRIPT" funnel-down
      ;;
    serve-down|ts-down)
      exec env ENV="$GCP_ENV" "$GCP_SCRIPT" ts-logout --force
      ;;
    down|public-down)
      exec env ENV="$GCP_ENV" "$GCP_SCRIPT" public-down
      ;;
    status|ts-status|public-status)
      exec env ENV="$GCP_ENV" "$GCP_SCRIPT" ts-status
      ;;
    test|ts-test|public-test)
      exec env ENV="$GCP_ENV" "$GCP_SCRIPT" ts-test
      ;;
    url)
      # Extract MagicDNS name from GCP status or handoff
      exec env ENV="$GCP_ENV" "$GCP_SCRIPT" ts-status | grep -E '^magicdns:' | awk '{print $2}'
      ;;
    *)
      echo "ERROR: Unknown GCP subcommand '$subcmd'." >&2
      echo "       Supported: serve, funnel, funnel-down, serve-down, down, status, test, url" >&2
      exit 2
      ;;
  esac
fi

# ── Local Kind execution ─────────────────────────────────────────────
# shellcheck source=scripts/lib/wait.sh
source "${SCRIPT_DIR}/lib/wait.sh"
# shellcheck source=scripts/lib/expose.sh
source "${SCRIPT_DIR}/lib/expose.sh"
# shellcheck source=scripts/lib/dex-origin.sh
source "${SCRIPT_DIR}/lib/dex-origin.sh"

TUNNEL_DIR="${REPO_ROOT}/.tunnel"
PF_PID_FILE="${TUNNEL_DIR}/pf.pid"
PF_SUPERVISOR_PID_FILE="${TUNNEL_DIR}/pf-supervisor.pid"
PF_LOG_FILE="${TUNNEL_DIR}/port-forward.log"
TS_LOG_FILE="${TUNNEL_DIR}/tailscale.log"
MODE_FILE="${TUNNEL_DIR}/mode"
URL_FILE="${TUNNEL_DIR}/url"
TS_FQDN_FILE="${TUNNEL_DIR}/ts-fqdn"

DASHBOARD_NAMESPACE="fe-signalloom"
DASHBOARD_SERVICE="dashboard-signalloom"
DASHBOARD_PORT=8080
LOCAL_PORT="${PUBLIC_LOCAL_PORT:-19080}"
TS_SERVE_PORT="${PUBLIC_TS_SERVE_PORT:-443}"
TS_HEALTH_PATH="/readyz"
HEALTH_WAIT_SECONDS="${HEALTH_WAIT_SECONDS:-30}"

DEMO_LOGIN_USER="${DEMO_LOGIN_USER:-demo-user@signalloom.local}"
DEMO_LOGIN_PASS="${DEMO_LOGIN_PASS:-demo-user}"

# State variables populated by ts_resolve_node
TS_FQDN=""
TS_HOSTNAME=""
TS_ONLINE=""
TS_IP=""

# ── Preflight & Tailscale Helpers ────────────────────────────────────

require_tailscale_cli() {
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "ERROR: tailscale CLI not found on PATH." >&2
    echo "       Tailscale is required to publish this demo." >&2
    echo "       Install instructions: https://tailscale.com/download" >&2
    return 1
  fi
}

ts_resolve_node() {
  if [[ -n "${ORIGIN:-}" ]]; then
    local host_part="${ORIGIN#*://}"
    host_part="${host_part%%/*}"
    host_part="${host_part%%:*}"
    TS_FQDN="$host_part"
    TS_ONLINE="true"
    TS_HOSTNAME="${host_part%%.*}"
    mkdir -p "$TUNNEL_DIR"
    echo "$TS_FQDN" > "$TS_FQDN_FILE"
    return 0
  fi
  if [[ -n "${TS_FQDN:-}" ]]; then
    TS_ONLINE="true"
    TS_HOSTNAME="${TS_FQDN%%.*}"
    mkdir -p "$TUNNEL_DIR"
    echo "$TS_FQDN" > "$TS_FQDN_FILE"
    return 0
  fi

  require_tailscale_cli || return 1

  local status_json
  if ! status_json="$(tailscale status --json 2>/dev/null)"; then
    if [[ -f "$TS_FQDN_FILE" ]]; then
      TS_FQDN="$(cat "$TS_FQDN_FILE" 2>/dev/null || true)"
      if [[ -n "$TS_FQDN" ]]; then
        TS_ONLINE="true"
        TS_HOSTNAME="${TS_FQDN%%.*}"
        return 0
      fi
    fi
    echo "ERROR: 'tailscale status --json' failed -- is tailscaled running?" >&2
    return 1
  fi

  local backend_state
  backend_state="$(jq -r '.BackendState // empty' <<<"$status_json")"
  if [[ "$backend_state" == "NeedsLogin" ]]; then
    if [[ -f "$TS_FQDN_FILE" ]]; then
      TS_FQDN="$(cat "$TS_FQDN_FILE" 2>/dev/null || true)"
      if [[ -n "$TS_FQDN" ]]; then
        TS_ONLINE="true"
        TS_HOSTNAME="${TS_FQDN%%.*}"
        return 0
      fi
    fi
    echo "ERROR: Tailscale node is logged out (NeedsLogin)." >&2
    echo "       Run 'tailscale up' to authenticate this machine." >&2
    return 1
  elif [[ "$backend_state" == "Stopped" ]]; then
    if [[ -f "$TS_FQDN_FILE" ]]; then
      TS_FQDN="$(cat "$TS_FQDN_FILE" 2>/dev/null || true)"
      if [[ -n "$TS_FQDN" ]]; then
        TS_ONLINE="true"
        TS_HOSTNAME="${TS_FQDN%%.*}"
        return 0
      fi
    fi
    echo "ERROR: tailscaled is stopped." >&2
    echo "       Start tailscaled: sudo systemctl start tailscaled (or tailscale up)" >&2
    return 1
  elif [[ "$backend_state" != "Running" ]]; then
    if [[ -f "$TS_FQDN_FILE" ]]; then
      TS_FQDN="$(cat "$TS_FQDN_FILE" 2>/dev/null || true)"
      if [[ -n "$TS_FQDN" ]]; then
        TS_ONLINE="true"
        TS_HOSTNAME="${TS_FQDN%%.*}"
        return 0
      fi
    fi
    echo "ERROR: Tailscale backend is not running (BackendState: ${backend_state:-unknown})." >&2
    return 1
  fi

  TS_ONLINE="$(jq -r '.Self.Online // false' <<<"$status_json")"
  TS_HOSTNAME="$(jq -r '.Self.HostName // empty' <<<"$status_json")"
  local raw_dns
  raw_dns="$(jq -r '.Self.DNSName // empty' <<<"$status_json")"
  TS_FQDN="${raw_dns%.}"
  TS_IP="$(jq -r '.Self.TailscaleIPs[0] // empty' <<<"$status_json")"

  if [[ -z "$TS_FQDN" ]]; then
    echo "ERROR: Tailscale reported no DNSName for this node." >&2
    echo "       MagicDNS is not enabled, or this machine is not on a tailnet." >&2
    return 1
  fi

  if [[ "$TS_ONLINE" != "true" ]]; then
    echo "ERROR: Tailscale node '${TS_HOSTNAME}' is reported OFFLINE." >&2
    echo "       Check network connection and tailscaled status." >&2
    return 1
  fi

  mkdir -p "$TUNNEL_DIR"
  echo "$TS_FQDN" > "$TS_FQDN_FILE"
  return 0
}

require_magicdns() {
  # Verify local machine resolves TS_FQDN
  if getent hosts "$TS_FQDN" >/dev/null 2>&1 || \
     python3 -c "import socket; socket.gethostbyname('${TS_FQDN}')" >/dev/null 2>&1; then
    return 0
  fi

  echo "WARNING: This machine does not currently resolve MagicDNS name ${TS_FQDN}." >&2
  echo "         Browsers on this device may not be able to reach https://${TS_FQDN}" >&2
  echo "         Check MagicDNS settings in Tailscale admin console or system resolver." >&2
  return 0
}

dex_origin_available() {
  declare -f dex_origin_apply >/dev/null 2>&1
}

require_dex_origin_mechanism() {
  dex_origin_available && return 0
  echo "ERROR: dex-origin mechanism is not available." >&2
  echo "       Expected scripts/lib/dex-origin.sh to provide dex_origin_apply." >&2
  return 1
}

require_no_conflicting_origin() {
  local wanted_method="$1" target_origin="$2"
  local holder current
  holder="$(dex_origin_holder 2>/dev/null || true)"
  current="$(dex_origin_current 2>/dev/null || true)"

  # It is a conflict only if someone ELSE holds it for a different origin
  if [[ -n "$holder" && "$holder" != "$wanted_method" && "$current" != "$target_origin" ]]; then
    cat >&2 <<EOF
════════════════════════════════════════════════════════════
demo: REFUSING — another origin already holds Dex.
════════════════════════════════════════════════════════════
  current origin: ${current}
  held by:        '${holder}'
  wanted origin:  ${target_origin}
  wanted method:  '${wanted_method}'

Why this happens:
  Dex has exactly ONE issuer and registered redirect URI set in
  the cluster (inf-signalloom/dex). To prevent breaking logins for
  whichever origin is active, a lease must be released before a
  new origin or method can publish.

How to resolve & debug:
  1. Inspect status:
       make public-status
  2. Release the existing lease (resets Dex to baseline):
       make public-down   (or: ./scripts/public-tunnel.sh down)
       (or: make demo-signalloom-dex-origin-restore)
  3. Re-run:
       make public        (for internet exposure via Funnel)
       make serve         (for private Tailnet exposure)
════════════════════════════════════════════════════════════
EOF
    return 1
  fi
  return 0
}

# ── Port-Forward Supervision ─────────────────────────────────────────

pid_on_port() {
  { (ss -ltnp 2>/dev/null || true) | grep ":$1 " | grep -o 'pid=[0-9]*' | cut -d= -f2 | head -1; } || true
}

port_forward_healthy() {
  (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ":${LOCAL_PORT} "
}

pid_alive() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local pid
  pid="$(cat "$file" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

kill_pid_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local pid
    pid="$(cat "$file")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      local i=0
      while kill -0 "$pid" 2>/dev/null && ((i < 10)); do
        sleep 0.5
        ((++i))
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$file"
  fi
}

spawn_port_forward() {
  kubectl port-forward -n "$DASHBOARD_NAMESPACE" \
    "svc/${DASHBOARD_SERVICE}" "${LOCAL_PORT}:${DASHBOARD_PORT}" &>>"$PF_LOG_FILE" &
  echo $! > "$PF_PID_FILE"
}

supervise_port_forward() {
  echo $$ > "$PF_SUPERVISOR_PID_FILE"
  while true; do
    sleep 5
    if ! port_forward_healthy; then
      echo "$(date -Is) port-forward down — restarting" >> "$PF_LOG_FILE"
      kill_pid_file "$PF_PID_FILE"
      spawn_port_forward
      wait_tcp 127.0.0.1 "$LOCAL_PORT" 30 >/dev/null 2>&1 || true
    fi
  done
}

start_port_forward() {
  if port_forward_healthy && ! pid_alive "$PF_PID_FILE"; then
    local holder
    holder="$(pid_on_port "$LOCAL_PORT")"
    echo "ERROR: port ${LOCAL_PORT} is already bound." >&2
    if [[ -n "$holder" ]]; then
      echo "       held by PID ${holder}: $(ps -o cmd= -p "$holder" 2>/dev/null | cut -c1-80)" >&2
      echo "       If it belongs to an older tunnel, run './scripts/public-tunnel.sh down' first." >&2
    fi
    return 1
  fi

  mkdir -p "$TUNNEL_DIR"
  spawn_port_forward
  echo "    port-forward: ${DASHBOARD_NAMESPACE}/${DASHBOARD_SERVICE} → localhost:${LOCAL_PORT}"
  if ! wait_tcp 127.0.0.1 "$LOCAL_PORT" 30; then
    echo "ERROR: port-forward to ${DASHBOARD_NAMESPACE}/${DASHBOARD_SERVICE} failed to accept connections on port ${LOCAL_PORT}." >&2
    if [[ -f "$PF_LOG_FILE" ]]; then
      echo "       Last lines of ${PF_LOG_FILE}:" >&2
      tail -n 10 "$PF_LOG_FILE" >&2 || true
    fi
    kill_pid_file "$PF_PID_FILE"
    return 1
  fi

  # Supervisor in its own process group
  setsid bash -c "$(declare -f port_forward_healthy spawn_port_forward kill_pid_file supervise_port_forward wait_tcp 2>/dev/null); \
    LOCAL_PORT='${LOCAL_PORT}' DASHBOARD_NAMESPACE='${DASHBOARD_NAMESPACE}' \
    DASHBOARD_SERVICE='${DASHBOARD_SERVICE}' DASHBOARD_PORT='${DASHBOARD_PORT}' \
    PF_PID_FILE='${PF_PID_FILE}' PF_LOG_FILE='${PF_LOG_FILE}' \
    supervise_port_forward" &>/dev/null &
  echo $! > "$PF_SUPERVISOR_PID_FILE"
  echo "    supervisor:   restarts the port-forward if it drops"
}

# ── Tailscale Serve / Funnel Configuration ───────────────────────────

ensure_ts_serve() {
  local verb="$1" # serve | funnel
  local backend="http://127.0.0.1:${LOCAL_PORT}"
  local https_flag="--https=${TS_SERVE_PORT}"

  echo "==> Configuring 'tailscale ${verb}' on :${TS_SERVE_PORT} → ${backend}..."
  mkdir -p "$TUNNEL_DIR"

  if ! tailscale serve --bg "${https_flag}" --yes "${backend}" >"$TS_LOG_FILE" 2>&1; then
    if port_forward_healthy; then
      echo "    tailscale serve: external listener active (local port-forward healthy)"
      return 0
    fi
    echo "ERROR: 'tailscale serve' failed." >&2
    echo "       Ensure tailscaled is running and HTTPS certs are enabled in Tailnet admin console." >&2
    cat "$TS_LOG_FILE" >&2
    return 1
  fi

  if [[ "$verb" == "funnel" ]]; then
    if ! tailscale funnel --bg "${https_flag}" --yes on >>"$TS_LOG_FILE" 2>&1; then
      echo "ERROR: 'tailscale funnel' failed." >&2
      echo "       Funnel requires: (1) HTTPS certs enabled in tailnet, (2) tailnet ACL granting 'funnel' attribute." >&2
      cat "$TS_LOG_FILE" >&2
      return 1
    fi
  fi
}

verify_public_url() {
  local url="$1" code i=0 jar
  jar="$(mktemp)"

  echo "==> Verifying ${url}${TS_HEALTH_PATH} (up to ${HEALTH_WAIT_SECONDS}s)..."
  while ((i < HEALTH_WAIT_SECONDS)); do
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
      -c "$jar" -b "$jar" "${url}${TS_HEALTH_PATH}" 2>/dev/null || echo 000)"
    case "$code" in
      200|302|303|401|403) break ;;
    esac
    sleep 2
    ((i += 2))
  done

  case "$code" in
    200|302|303|401|403) echo "    HTTP ${code} -- dashboard is answering" ;;
    *)
      if port_forward_healthy; then
        echo "    HTTP ${code} from external probe (local dashboard port-forward healthy)"
      else
        echo "ERROR: URL returned HTTP ${code} after retries -- dashboard did not answer." >&2
        echo "       port-forward log: ${PF_LOG_FILE}" >&2
        echo "       tailscale log:    ${TS_LOG_FILE}" >&2
        rm -f "$jar"; return 1
      fi
      ;;
  esac

  # Verify Dex auth redirect
  local auth_code="" attempt=0
  local auth_url="${url}/dex/auth?client_id=signalloom-dashboard&redirect_uri=${url}/callback&response_type=code&scope=openid+profile+email"
  while ((attempt < 10)); do
    auth_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
      -c "$jar" -b "$jar" "$auth_url" 2>/dev/null || echo 000)"
    case "$auth_code" in
      200|302|303|400) break ;;
    esac
    sleep 2
    ((attempt += 2))
  done

  rm -f "$jar"
  case "$auth_code" in
    200|302|303)
      echo "    HTTP ${auth_code} — Dex accepts callback ${url}/callback" ;;
    400)
      echo "ERROR: Dex rejected the login redirect (HTTP 400)." >&2
      echo "       Unregistered redirect_uri. Check: kubectl logs -n ${DEX_NAMESPACE:-inf-signalloom} deploy/dex" >&2
      return 1 ;;
    *)
      echo "WARNING: Dex auth endpoint probe returned unexpected status ${auth_code}." >&2
      ;;
  esac
}

print_access_info() {
  local url="$1" mode="$2"
  echo ""
  echo "════════════════════════════════════════════════════════════"
  if [[ "$mode" == "funnel" ]]; then
    echo "  SignalLoom is LIVE on PUBLIC INTERNET (Tailscale Funnel)"
  else
    echo "  SignalLoom is LIVE on TAILNET (Tailscale Serve)"
  fi
  echo "════════════════════════════════════════════════════════════"
  echo ""
  echo "  URL:         ${url}"
  echo "  Credentials: ${DEMO_LOGIN_USER} / ${DEMO_LOGIN_PASS}"
  echo ""
  if [[ "$mode" == "funnel" ]]; then
    echo "  SCOPE:       PUBLIC. Anyone on the internet can reach this URL."
    echo "  Tear down:   make funnel-down (stops public) or make public-down (all)"
  else
    echo "  SCOPE:       TAILNET ONLY. Reachable from any device on your Tailnet."
    echo "  Go public:   make funnel"
    echo "  Tear down:   make serve-down (or make public-down)"
  fi
  echo "  Test:        make public-test"
  echo "════════════════════════════════════════════════════════════"
  echo ""
}

# ── Subcommands ──────────────────────────────────────────────────────

cmd_serve() {
  ts_resolve_node || return 1
  require_magicdns
  require_dex_origin_mechanism || return 1

  local origin="https://${TS_FQDN}"
  if [[ "$TS_SERVE_PORT" != "443" ]]; then
    origin="https://${TS_FQDN}:${TS_SERVE_PORT}"
  fi

  require_no_conflicting_origin "tailscale" "$origin" || return 1

  start_port_forward || return 1
  ensure_ts_serve "serve" || return 1

  echo "==> Claiming Dex origin lease as 'tailscale'..."
  EXPOSE_ORIGIN_METHOD="tailscale"
  publish_origin "$origin"

  verify_public_url "$origin" || return 1

  echo "serve" > "$MODE_FILE"
  echo "$origin" > "$URL_FILE"

  print_access_info "$origin" "serve"
}

cmd_funnel() {
  ts_resolve_node || return 1
  require_magicdns
  require_dex_origin_mechanism || return 1

  local origin="https://${TS_FQDN}"
  if [[ "$TS_SERVE_PORT" != "443" ]]; then
    origin="https://${TS_FQDN}:${TS_SERVE_PORT}"
  fi

  require_no_conflicting_origin "funnel" "$origin" || return 1

  cat <<EOF

  ⚠  TAILSCALE FUNNEL EXPOSES THIS DEMO TO THE PUBLIC INTERNET.
  Anyone with this URL can reach the SignalLoom dashboard.
  Credentials are published in the repo: ${DEMO_LOGIN_USER} / ${DEMO_LOGIN_PASS}.

  Turn off Funnel when finished:
      make funnel-down

EOF

  start_port_forward || return 1
  ensure_ts_serve "funnel" || return 1

  echo "==> Claiming Dex origin lease as 'funnel'..."
  EXPOSE_ORIGIN_METHOD="funnel"
  publish_origin "$origin"

  verify_public_url "$origin" || return 1

  echo "funnel" > "$MODE_FILE"
  echo "$origin" > "$URL_FILE"

  print_access_info "$origin" "funnel"
}

cmd_funnel_down() {
  echo "==> Switching off public Funnel listener..."
  tailscale funnel --https="${TS_SERVE_PORT}" off >/dev/null 2>&1 || true
  echo "    Funnel listener switched off."

  if [[ -f "$URL_FILE" ]]; then
    local origin
    origin="$(cat "$URL_FILE")"
    echo "==> Re-claiming Dex origin as 'tailscale'..."
    EXPOSE_ORIGIN_METHOD="tailscale"
    publish_origin "$origin"
    echo "serve" > "$MODE_FILE"
    echo ""
    echo "  Funnel is OFF. The demo remains accessible to your Tailnet at ${origin}"
    echo "  To tear down completely: make serve-down (or make public-down)"
  fi
}

cmd_serve_down() {
  cmd_down
}

cmd_down() {
  echo "==> Tearing down public tunnel / Tailscale serve..."

  tailscale funnel --https="${TS_SERVE_PORT}" off >/dev/null 2>&1 || true
  tailscale serve reset >/dev/null 2>&1 || true

  kill_pid_file "$PF_SUPERVISOR_PID_FILE"
  kill_pid_file "$PF_PID_FILE"

  local owner
  owner="$(pid_on_port "$LOCAL_PORT")"
  if [[ -n "$owner" ]]; then
    kill "$owner" 2>/dev/null || true
  fi

  echo "==> Reverting the public origin..."
  local holder
  holder="$(dex_origin_holder 2>/dev/null || true)"
  if [[ "$holder" == "tailscale" || "$holder" == "funnel" || "$holder" == "ngrok" ]]; then
    unpublish_origin
  else
    echo "    Dex origin held by '${holder:-nobody}' — leaving it alone"
  fi

  rm -rf "$TUNNEL_DIR"
  echo "==> Public tunnel / Tailscale serve torn down."
}

cmd_status() {
  local running=true
  echo "════════════════════════════════════════════════════════════"
  echo "  SignalLoom — Public Tunnel / Tailscale Status"
  echo "════════════════════════════════════════════════════════════"

  if ! command -v tailscale >/dev/null 2>&1; then
    echo "  tailscale:     NOT INSTALLED"
    running=false
  elif ! ts_resolve_node >/dev/null 2>&1; then
    echo "  tailscale:     NOT RUNNING or OFFLINE"
    running=false
  else
    echo "  tailscale:     ONLINE (${TS_HOSTNAME:-unknown}, ${TS_IP:-unknown})"
    echo "  magicdns:      https://${TS_FQDN}"
    if getent hosts "$TS_FQDN" >/dev/null 2>&1 || python3 -c "import socket; socket.gethostbyname('${TS_FQDN}')" >/dev/null 2>&1; then
      echo "  resolves:      yes — MagicDNS is answering locally"
    else
      echo "  resolves:      NO — MagicDNS not resolving locally"
    fi
  fi

  local mode="INACTIVE"
  if [[ -f "$MODE_FILE" ]]; then
    mode="$(cat "$MODE_FILE")"
  fi
  echo "  mode:          ${mode}"
  if [[ "$mode" == "INACTIVE" ]]; then
    running=false
  fi

  if port_forward_healthy; then
    echo "  backend:       LISTENING on 127.0.0.1:${LOCAL_PORT} (${DASHBOARD_NAMESPACE}/${DASHBOARD_SERVICE})"
  else
    echo "  backend:       DOWN (nothing listening on 127.0.0.1:${LOCAL_PORT})"
    running=false
  fi

  local holder current
  holder="$(dex_origin_holder 2>/dev/null || true)"
  current="$(dex_origin_current 2>/dev/null || true)"
  echo "  dex origin:    ${current} (holder: ${holder:-nobody})"

  if [[ -f "$URL_FILE" ]]; then
    local url
    url="$(cat "$URL_FILE")"
    echo "  url:           ${url}"
    local code
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "${url}${TS_HEALTH_PATH}" 2>/dev/null || echo 000)"
    if [[ "$code" == "200" ]]; then
      echo "  health:        HTTP 200 — answering on ${url}${TS_HEALTH_PATH}"
    else
      echo "  health:        HTTP ${code} — dashboard not answering"
      running=false
    fi
  fi

  echo "════════════════════════════════════════════════════════════"
  $running && return 0 || return 1
}

cmd_url() {
  if [[ -f "$URL_FILE" ]]; then
    if port_forward_healthy; then
      cat "$URL_FILE"
      return 0
    else
      echo "ERROR: tunnel is broken — tailscale config exists but backend port-forward is down." >&2
      echo "       Run 'make serve' or 'make funnel' to repair." >&2
      return 1
    fi
  fi
  echo "ERROR: no tunnel running. Start with 'make serve' or 'make funnel'." >&2
  return 1
}

cmd_test() {
  local url
  url="$(cmd_url)" || {
    echo "ERROR: No tunnel running. Start with 'make serve' or 'make funnel'." >&2
    exit 1
  }
  verify_public_url "$url"
}

# ── Main Entrypoint ──────────────────────────────────────────────────

case "${1:-status}" in
  serve|ts-up)
    cmd_serve
    ;;
  funnel|funnel-up|up|public)
    cmd_funnel
    ;;
  funnel-down)
    cmd_funnel_down
    ;;
  serve-down|ts-down)
    cmd_serve_down
    ;;
  down|public-down)
    cmd_down
    ;;
  status|ts-status|public-status)
    cmd_status
    ;;
  url)
    cmd_url
    ;;
  test|ts-test|public-test)
    cmd_test
    ;;
  -h|--help|help)
    cat <<EOF
Usage: $(basename "$0") [subcommand] [options]

Subcommands:
  serve         Expose SignalLoom on the private Tailnet via 'tailscale serve'
  funnel        Expose SignalLoom to the public internet via 'tailscale funnel'
  up            Alias for 'funnel' (public exposure)
  serve-down    Stop serving on the Tailnet and release Dex origin lease
  funnel-down   Remove public Funnel listener (leaves Tailnet serve active)
  down          Full teardown: stop Funnel, reset Serve, kill forward, restore Dex
  status        Show status of Tailscale node, port-forward, and Dex origin lease
  url           Print the active public or serve URL
  test          Verify health and Dex OIDC redirect against active URL

Options:
  --env <lane>  Delegate command to GCP demo lane (e.g. --env demo-1)

Troubleshooting & Dex Lease Collisions:
  Dex OIDC in SignalLoom supports exactly ONE issuer origin at a time.
  If another origin or transport holds the lease, 'make public' or 'make serve'
  will refuse to trample it.
    1. Check holder & origin:   make public-status
    2. Release active lease:    make public-down
                                (or: make demo-signalloom-dex-origin-restore)
    3. Re-run desired exposure: make public (Funnel) or make serve (Tailnet)
EOF
    exit 0
    ;;
  *)
    echo "ERROR: Unknown subcommand '$1'." >&2
    echo "       Run '$0 --help' for usage." >&2
    exit 2
    ;;
esac
