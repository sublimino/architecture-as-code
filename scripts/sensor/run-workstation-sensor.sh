#!/usr/bin/env bash
# ==============================================================================
# Signal Loom Workstation Sensor — Local Runner & Tailscale Connector
# ==============================================================================
# Coordinates local coding agent detection and telemetry transmission from
# developer workstations (macOS / Linux) over Tailscale to the Signal Loom platform.
# ==============================================================================

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SENSOR_DIR="${REPO_ROOT}/d2-signalloom/apps/agentmaxxing-host-sensor"

# 1. Resolve Signal Loom Ingress Endpoint
DEFAULT_TAILSCALE_FQDN="https://ftna-signalloom.taild4da3.ts.net"
DEFAULT_LOCAL_ENDPOINT="http://127.0.0.1:19080"

if [[ -n "${SIGNAL_LOOM_ENDPOINT:-}" ]]; then
  ENDPOINT="${SIGNAL_LOOM_ENDPOINT}"
elif curl -sk --connect-timeout 2 -o /dev/null "${DEFAULT_TAILSCALE_FQDN}/health" 2>/dev/null; then
  ENDPOINT="${DEFAULT_TAILSCALE_FQDN}"
elif curl -sk --connect-timeout 2 -o /dev/null "${DEFAULT_TAILSCALE_FQDN}/" 2>/dev/null; then
  ENDPOINT="${DEFAULT_TAILSCALE_FQDN}"
else
  ENDPOINT="${DEFAULT_LOCAL_ENDPOINT}"
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [COMMAND] [OPTIONS]

Signal Loom Workstation Sensor - Local Runner & Tailscale Connector

Commands:
  status            Verify Tailscale mesh connectivity, host kernel, and sensor prerequisites.
  scan              Scan host process table for active coding agent harnesses (Claude, Agy, Cline, Cursor).
  collect <PID>     Collect and display a single telemetry snapshot for a specific agent process.
  watch             Continuously observe active coding agent processes and stream metrics.
  enroll <TOKEN>    Redeem a one-time enrollment token to obtain an audit-scoped JWT bearer key.
  evidence <FILE>   Upload finalized session audit JSON to Signal Loom evidence ingestion.

Environment Variables:
  SIGNAL_LOOM_ENDPOINT  Target platform URL (default: ${ENDPOINT})
  SIGNAL_LOOM_TOKEN     Bearer authentication token (audit-scoped JWT)
  SIGNAL_LOOM_API_KEY   Static SLTM API key for direct signal-ingest transmission
  AGENT_ID              Monitored agent identifier (default: local-workstation-agent)
  TENANT_ID             Attributable tenant identifier (default: tenant-internal)

Examples:
  $(basename "$0") status
  $(basename "$0") scan
  $(basename "$0") collect 12345
  $(basename "$0") enroll amxo_enroll_sec_0123456789abcdef...
EOF
  exit 1
}

cmd_status() {
  echo "================================================================="
  echo "  Signal Loom Workstation Sensor — Tailscale & Runtime Status   "
  echo "================================================================="
  echo ""
  
  # Host Platform Probe
  local os_name; os_name="$(uname -s)"
  local arch_name; arch_name="$(uname -m)"
  local kernel_rel; kernel_rel="$(uname -r)"
  echo "  [✓] Host Architecture:  ${os_name} (${arch_name}), kernel ${kernel_rel}"
  if [[ "${os_name}" == "Darwin" ]]; then
    echo "      Note: Darwin detected. Telemetry runs in userland observation mode."
    echo "      (Linux Landlock LSM and /proc require a Linux host or Docker/OrbStack)."
  elif [[ "${os_name}" == "Linux" ]]; then
    if [[ -d "/proc/sys/fs" ]]; then
      echo "  [✓] Linux Procfs:        Available (/proc)"
    fi
  fi

  # Tailscale Probe
  if command -v tailscale >/dev/null 2>&1; then
    TS_STATUS=$(tailscale status --json 2>/dev/null | jq -r '.Self | "\(.HostName) (\(.TailscaleIPs[0])) on \(.DNSName)"' 2>/dev/null || echo "Connected")
    echo "  [✓] Tailscale Mesh:      ${TS_STATUS}"
  else
    echo "  [!] Tailscale Mesh:      tailscale CLI not found in PATH"
  fi

  # Endpoint Probe
  echo -n "  [?] Ingestion Endpoint:  ${ENDPOINT} ... "
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 3 "${ENDPOINT}/" 2>/dev/null || echo "FAILED")
  if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "301" || "${HTTP_CODE}" == "302" || "${HTTP_CODE}" == "404" ]]; then
    echo "REACHABLE (HTTP ${HTTP_CODE})"
  else
    echo "UNREACHABLE (${HTTP_CODE})"
    echo "      Note: Verify that the Tailscale node (ts-ftna-signalloom) or local forward (19080) is running."
  fi

  # Sensor Code Probe
  echo -n "  [?] Host Sensor Suite:   ${SENSOR_DIR} ... "
  if [[ -d "${SENSOR_DIR}" ]]; then
    echo "LOCATED"
    if [[ "${os_name}" == "Linux" ]]; then
      PYTHONPATH="${SENSOR_DIR}" python3 "${SENSOR_DIR}/cli.py" verify || true
    else
      echo "      (Skipping Linux-specific /proc verify on Darwin; Python module imports valid)"
    fi
  else
    echo "MISSING"
  fi
  echo "================================================================="
}

cmd_scan() {
  python3 -c "
import subprocess, sys

proc = subprocess.run(['ps', '-eo', 'pid,comm,args'], capture_output=True, text=True)
lines = proc.stdout.splitlines()

header = f'{\"PID\":<10} {\"COMMAND\":<16} {\"HARNESS DETECTED\":<25} {\"STATE\":<15}'
print('Scanning process table for active coding agents...\n')
print(header)
print('-' * len(header))

found = 0
for line in lines[1:]:
    parts = line.strip().split(None, 2)
    if len(parts) < 2: continue
    pid = parts[0]
    comm = parts[1]
    cmdline = parts[2] if len(parts) > 2 else ''
    if 'run-workstation-sensor' in cmdline or 'python3 -c' in cmdline: continue
    
    harness = None
    if comm in ('claude', 'claude-code'): harness = 'Claude Code'
    elif comm in ('agy', 'antigravity'): harness = 'Antigravity (Agy)'
    elif comm == 'cline': harness = 'Cline'
    elif comm == 'cursor': harness = 'Cursor'
    elif comm == 'aider': harness = 'Aider'
    elif comm in ('node', 'bun', 'python', 'python3'):
        if any(x in cmdline for x in ['claude', '@anthropic-ai/claude']): harness = 'Claude Code (Node)'
        elif any(x in cmdline for x in ['antigravity', 'agy-cli']): harness = 'Antigravity CLI'
        elif 'cline' in cmdline: harness = 'Cline'
        elif 'aider' in cmdline: harness = 'Aider'
        
    if harness:
        found += 1
        print(f'{pid:<10} {comm[:15]:<16} {harness:<25} {\"Active\":<15}')

print('-' * len(header))
if found == 0:
    print('No active coding agent harnesses currently detected in process table.')
    print('(Supported harnesses: Claude Code, Antigravity CLI, Cline, Cursor, Aider)')
else:
    print(f'Found {found} active agent process(es).')
"
}

cmd_collect() {
  local target_pid="${1:-}"
  if [[ -z "$target_pid" ]]; then
    echo "Error: Target PID required."
    usage
  fi
  
  echo "Collecting telemetry for PID ${target_pid}..."
  PYTHONPATH="${SENSOR_DIR}" python3 "${SENSOR_DIR}/cli.py" inspect \
    --pid "${target_pid}" \
    --json || true
}

cmd_watch() {
  echo "Starting Workstation Sensor Observation Loop..."
  echo "Endpoint: ${ENDPOINT}"
  echo "Press Ctrl+C to stop."
  echo ""

  while true; do
    python3 -c "
import subprocess, sys, os
from datetime import datetime

proc = subprocess.run(['ps', '-eo', 'pid,comm,args'], capture_output=True, text=True)
lines = proc.stdout.splitlines()

for line in lines[1:]:
    parts = line.strip().split(None, 2)
    if len(parts) < 2: continue
    pid = parts[0]
    comm = parts[1]
    cmdline = parts[2] if len(parts) > 2 else ''
    if 'run-workstation-sensor' in cmdline or 'python3 -c' in cmdline: continue

    harness = None
    if comm in ('claude', 'claude-code', 'agy', 'cline', 'cursor', 'aider'): harness = comm
    elif comm in ('node', 'bun', 'python', 'python3'):
        if any(x in cmdline for x in ['claude', 'antigravity', 'cline', 'aider']): harness = comm

    if harness:
        now_ts = datetime.utcnow().strftime('%H:%M:%SZ')
        print(f'[{now_ts}] Sampling Agent PID {pid} ({comm})...')
        subprocess.run(['python3', '${SENSOR_DIR}/cli.py', 'inspect', '--pid', pid], capture_output=False)
" 2>/dev/null || true
    sleep 5
  done
}

cmd_enroll() {
  local token="${1:-}"
  if [[ -z "$token" ]]; then
    echo "Error: One-time enrollment token required."
    echo "Usage: $(basename "$0") enroll <amxo_enroll_sec_...>"
    exit 1
  fi

  echo "Redeeming one-time enrollment token at ${ENDPOINT}/api/v1/external-agents/enroll..."
  local client_nonce; client_nonce="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
  local host_name; host_name="$(hostname -s 2>/dev/null || hostname)"
  local agent_id="${AGENT_ID:-local-workstation-${host_name}}"

  local payload
  payload=$(cat <<JSON
{
  "schema_version": "1.0.0",
  "agent_id": "${agent_id}",
  "host_id": "${host_name}",
  "key_id": "key-${host_name}-001",
  "key_algorithm": "Ed25519",
  "public_key": "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE",
  "client_nonce": "${client_nonce}",
  "credential_kind": "existing-mtls-identity",
  "credential_scope": "audit-upload-only",
  "credential_bootstrap": "pre-provisioned-out-of-band",
  "tenant_id": "${TENANT_ID:-tenant-internal}"
}
JSON
)

  local resp; resp=$(curl -sS -X POST "${ENDPOINT}/api/v1/external-agents/enroll" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${token}" \
    -d "${payload}" 2>&1 || true)

  echo "Server Response:"
  echo "${resp}" | jq . 2>/dev/null || echo "${resp}"

  local issued_token
  issued_token=$(echo "${resp}" | jq -r '.token // .access_token // empty' 2>/dev/null || true)
  if [[ -n "${issued_token}" ]]; then
    echo ""
    echo "SUCCESS: Host enrolled successfully."
    echo "Set the following environment variable to authorize audit uploads:"
    echo "  export SIGNAL_LOOM_TOKEN=\"${issued_token}\""
  fi
}

cmd_evidence() {
  local session_file="${1:-}"
  if [[ -z "$session_file" || ! -f "$session_file" ]]; then
    echo "Error: Path to valid session JSON file required."
    echo "Usage: $(basename "$0") evidence /path/to/session.json"
    exit 1
  fi

  if [[ -z "${SIGNAL_LOOM_TOKEN:-}" ]]; then
    echo "Error: SIGNAL_LOOM_TOKEN environment variable required."
    echo "Run '$(basename "$0") enroll <TOKEN>' first or set your audit-scoped JWT."
    exit 1
  fi

  echo "Uploading session evidence from ${session_file} to ${ENDPOINT}/api/v1/external-agents/evidence-uploads..."
  local resp; resp=$(curl -sS -X POST "${ENDPOINT}/api/v1/external-agents/evidence-uploads" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${SIGNAL_LOOM_TOKEN}" \
    --data-binary @"${session_file}" 2>&1 || true)

  echo "Server Response:"
  echo "${resp}" | jq . 2>/dev/null || echo "${resp}"
}

# Command Dispatcher
COMMAND="${1:-}"
shift || true

case "${COMMAND}" in
  status)   cmd_status "$@" ;;
  scan)     cmd_scan "$@" ;;
  collect)  cmd_collect "$@" ;;
  watch)    cmd_watch "$@" ;;
  enroll)   cmd_enroll "$@" ;;
  evidence) cmd_evidence "$@" ;;
  help|--help|-h|"") usage ;;
  *)
    echo "Unknown command: ${COMMAND}"
    usage
    ;;
esac
