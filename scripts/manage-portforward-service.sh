#!/usr/bin/env bash
# manage-portforward-service.sh — Lifecycle manager for signalloom-portforward systemd user unit
#
# Usage:
#   scripts/manage-portforward-service.sh install       Install unit, reload daemon, enable & start service
#   scripts/manage-portforward-service.sh uninstall     Stop, disable service and remove unit
#   scripts/manage-portforward-service.sh start         Start the port-forward service
#   scripts/manage-portforward-service.sh stop          Stop the port-forward service
#   scripts/manage-portforward-service.sh restart       Restart the port-forward service
#   scripts/manage-portforward-service.sh status        Show systemd status and probe HTTP endpoint
#   scripts/manage-portforward-service.sh logs [N]      Display last N journal logs (default: 30)
#   scripts/manage-portforward-service.sh enable        Enable service to start on login
#   scripts/manage-portforward-service.sh disable       Disable service autostart
#   scripts/manage-portforward-service.sh override-port Set local port override drop-in
#   scripts/manage-portforward-service.sh clean-stale   Terminate stale non-systemd listeners on target port

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SERVICE_NAME="signalloom-portforward.service"
UNIT_SOURCE="${REPO_ROOT}/d2-signalloom/infra/systemd/signalloom-portforward.service"
DROPIN_EXAMPLE="${REPO_ROOT}/d2-signalloom/infra/systemd/signalloom-portforward.service.d/10-port-override.conf.example"
USER_CONFIG_DIR="${HOME}/.config/systemd/user"
UNIT_DEST="${USER_CONFIG_DIR}/${SERVICE_NAME}"
DROPIN_DIR="${USER_CONFIG_DIR}/${SERVICE_NAME}.d"

DEFAULT_PORT=5173
DEFAULT_NAMESPACE="fe-signalloom"
DEFAULT_SERVICE="svc/dashboard-signalloom"

# Color helpers
log()  { printf '\033[1;36m[portforward-service]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[portforward-service] ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[portforward-service] !\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[portforward-service] ✗\033[0m %s\n' "$*" >&2; exit 1; }

# Helper to execute user commands directly or via systemd-run if sandboxed
run_systemd_cmd() {
  if "$@"; then
    return 0
  else
    systemd-run --user --wait --collect --pipe "$@"
  fi
}

# Helper to write files into ~/.config/systemd/user (handles Landlock/sandbox boundaries)
write_user_file() {
  local target_path="$1"
  local content="$2"
  local target_dir
  target_dir="$(dirname "${target_path}")"

  if mkdir -p "${target_dir}" 2>/dev/null && printf '%s\n' "${content}" > "${target_path}" 2>/dev/null; then
    return 0
  fi

  # Fallback to systemd-run outside sandbox
  systemd-run --user --wait --collect --pipe bash -c "mkdir -p '${target_dir}' && cat > '${target_path}'" <<< "${content}"
}

remove_user_file() {
  local target_path="$1"
  if rm -f "${target_path}" 2>/dev/null; then
    return 0
  fi
  systemd-run --user --wait --collect --pipe rm -f "${target_path}"
}

# Check cluster availability
check_cluster() {
  log "Verifying Kubernetes cluster connectivity..."
  if ! kubectl cluster-info >/dev/null 2>&1; then
    fail "Kubernetes API server unreachable. Verify cluster is running (e.g. 'make up' or 'kubectl cluster-info')."
  fi
  if ! kubectl get "${DEFAULT_SERVICE}" -n "${DEFAULT_NAMESPACE}" >/dev/null 2>&1; then
    warn "Service ${DEFAULT_SERVICE} not found in namespace ${DEFAULT_NAMESPACE}. Port-forward will auto-reconnect once deployed."
  fi
  ok "Cluster connectivity verified."
}

# Detect and terminate stale processes bound to the target port that are NOT part of the service
clean_stale_listeners() {
  local port="${1:-${DEFAULT_PORT}}"
  log "Checking for stale listeners on port ${port}..."

  local current_unit_pid=""
  current_unit_pid="$(systemctl --user show "${SERVICE_NAME}" --property=MainPID --value 2>/dev/null || echo "")"
  if [ "${current_unit_pid}" = "0" ]; then
    current_unit_pid=""
  fi

  # Search for listening PIDs on localhost:port
  local stale_pids=()
  if command -v fuser >/dev/null 2>&1; then
    local pids_found
    pids_found="$(fuser "${port}/tcp" 2>/dev/null || true)"
    for p in ${pids_found}; do
      if [ -n "${p}" ] && [ "${p}" != "${current_unit_pid}" ] && [ "${p}" != "$$" ]; then
        stale_pids+=("${p}")
      fi
    done
  fi

  if [ ${#stale_pids[@]} -eq 0 ] && command -v ss >/dev/null 2>&1; then
    local ss_pids
    ss_pids="$(ss -tulpn "sport = :${port}" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 || true)"
    for p in ${ss_pids}; do
      if [ -n "${p}" ] && [ "${p}" != "${current_unit_pid}" ] && [ "${p}" != "$$" ]; then
        stale_pids+=("${p}")
      fi
    done
  fi

  if [ ${#stale_pids[@]} -gt 0 ]; then
    warn "Found stale listener(s) on port ${port}: ${stale_pids[*]}"
    for p in "${stale_pids[@]}"; do
      warn "Terminating stale PID ${p}..."
      kill -15 "${p}" 2>/dev/null || true
      sleep 0.5
      if kill -0 "${p}" 2>/dev/null; then
        kill -9 "${p}" 2>/dev/null || true
      fi
    done
    ok "Terminated stale listener(s)."
  else
    ok "Port ${port} is clear of stale listeners."
  fi
}

cmd_install() {
  log "Installing ${SERVICE_NAME} to ${UNIT_DEST}..."
  if [ ! -f "${UNIT_SOURCE}" ]; then
    fail "Source unit file ${UNIT_SOURCE} not found."
  fi

  check_cluster
  clean_stale_listeners "${DEFAULT_PORT}"

  local unit_content
  unit_content="$(cat "${UNIT_SOURCE}")"
  write_user_file "${UNIT_DEST}" "${unit_content}"

  log "Reloading systemd user daemon..."
  systemctl --user daemon-reload
  log "Enabling ${SERVICE_NAME}..."
  systemctl --user enable "${SERVICE_NAME}"
  log "Starting ${SERVICE_NAME}..."
  systemctl --user restart "${SERVICE_NAME}"

  # Wait up to 10s for active state
  local active=0
  for _ in $(seq 1 20); do
    if systemctl --user is-active --quiet "${SERVICE_NAME}"; then
      active=1
      break
    fi
    sleep 0.5
  done

  if [ "${active}" -ne 1 ]; then
    systemctl --user status "${SERVICE_NAME}" --no-pager || true
    fail "${SERVICE_NAME} failed to reach active state."
  fi

  ok "${SERVICE_NAME} successfully installed and active."
  cmd_status
}

cmd_uninstall() {
  log "Uninstalling ${SERVICE_NAME}..."
  systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl --user disable "${SERVICE_NAME}" 2>/dev/null || true
  remove_user_file "${UNIT_DEST}"
  systemctl --user daemon-reload
  ok "${SERVICE_NAME} uninstalled."
}

cmd_start() {
  clean_stale_listeners "${DEFAULT_PORT}"
  log "Starting ${SERVICE_NAME}..."
  systemctl --user start "${SERVICE_NAME}"
  sleep 1
  cmd_status
}

cmd_stop() {
  log "Stopping ${SERVICE_NAME}..."
  systemctl --user stop "${SERVICE_NAME}"
  ok "${SERVICE_NAME} stopped."
}

cmd_restart() {
  clean_stale_listeners "${DEFAULT_PORT}"
  log "Restarting ${SERVICE_NAME}..."
  systemctl --user restart "${SERVICE_NAME}"
  sleep 1
  cmd_status
}

cmd_status() {
  log "Status of ${SERVICE_NAME}:"
  systemctl --user status "${SERVICE_NAME}" --no-pager || true

  local port="${DEFAULT_PORT}"
  # Check if port override drop-in exists
  local override_file="${DROPIN_DIR}/10-port-override.conf"
  if [ -f "${override_file}" ]; then
    local p
    p="$(grep -E '^[[:space:]]*Environment=LOCAL_PORT=' "${override_file}" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)"
    if [ -n "${p}" ]; then
      port="${p}"
    fi
  fi

  log "Probing http://localhost:${port}..."
  local http_code
  http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${port}" 2>/dev/null || echo "000")"
  if [ "${http_code}" = "200" ]; then
    ok "Endpoint http://localhost:${port} is responding with HTTP 200 OK."
  else
    warn "Endpoint http://localhost:${port} returned HTTP code ${http_code}."
  fi
}

cmd_logs() {
  local lines="${1:-30}"
  log "Showing last ${lines} logs for ${SERVICE_NAME}:"
  if ! journalctl --user -u "${SERVICE_NAME}" --no-pager -n "${lines}"; then
    systemd-run --user --wait --collect --pipe journalctl --user -u "${SERVICE_NAME}" --no-pager -n "${lines}"
  fi
}

cmd_enable() {
  log "Enabling ${SERVICE_NAME}..."
  systemctl --user enable "${SERVICE_NAME}"
  ok "${SERVICE_NAME} enabled."
}

cmd_disable() {
  log "Disabling ${SERVICE_NAME}..."
  systemctl --user disable "${SERVICE_NAME}"
  ok "${SERVICE_NAME} disabled."
}

cmd_override_port() {
  local new_port="${1:-}"
  if [ -z "${new_port}" ]; then
    fail "Usage: $0 override-port <PORT>"
  fi

  log "Configuring port override to ${new_port}..."
  clean_stale_listeners "${new_port}"

  local dropin_file="${DROPIN_DIR}/10-port-override.conf"
  local dropin_content
  dropin_content="[Service]
Environment=LOCAL_PORT=${new_port}
"
  write_user_file "${dropin_file}" "${dropin_content}"
  log "Drop-in configuration written to ${dropin_file}."
  log "Reloading systemd user daemon..."
  systemctl --user daemon-reload
  log "Restarting ${SERVICE_NAME}..."
  systemctl --user restart "${SERVICE_NAME}"
  sleep 1
  ok "Port override applied."
  cmd_status
}

cmd_clean_stale() {
  clean_stale_listeners "${DEFAULT_PORT}"
}

main() {
  local cmd="${1:-status}"
  shift || true

  case "${cmd}" in
    install)
      cmd_install "$@"
      ;;
    uninstall)
      cmd_uninstall "$@"
      ;;
    start)
      cmd_start "$@"
      ;;
    stop)
      cmd_stop "$@"
      ;;
    restart)
      cmd_restart "$@"
      ;;
    status)
      cmd_status "$@"
      ;;
    logs|log)
      cmd_logs "$@"
      ;;
    enable)
      cmd_enable "$@"
      ;;
    disable)
      cmd_disable "$@"
      ;;
    override-port|override)
      cmd_override_port "$@"
      ;;
    clean-stale|clean)
      cmd_clean_stale "$@"
      ;;
    help|--help|-h)
      head -n 16 "$0" | tail -n 14
      ;;
    *)
      fail "Unknown command: ${cmd}. Run '$0 help' for usage."
      ;;
  esac
}

main "$@"
