#!/usr/bin/env bash
# scripts/impl-agent-log.sh — shared communication log between agents
#
# Provides an append-only, concurrency-safe, structured shared log at
# /tmp/impl-agent.log for multi-agent coordination, claims, discoveries,
# and direct/broadcast messaging.
#
# Usage:
#   impl-agent-log.sh init
#   impl-agent-log.sh announce [role] [details...]
#   impl-agent-log.sh heartbeat [details...]
#   impl-agent-log.sh claim <resource> [reason...]
#   impl-agent-log.sh release <resource> [status...]
#   impl-agent-log.sh claims
#   impl-agent-log.sh discover <severity> <topic> <details...>
#   impl-agent-log.sh msg <target|all> <message...>
#   impl-agent-log.sh post <EVENT> <TOPIC> <message...>
#   impl-agent-log.sh read [N|all]
#   impl-agent-log.sh tail [tail-args...]
#   impl-agent-log.sh status
#
# Environment variables:
#   IMPL_AGENT_LOG   Path to shared log file (default: /tmp/impl-agent.log)
#   IMPL_AGENT_LOCK  Path to lock file (default: /tmp/impl-agent.log.lock)
#   AGENT_ID         Agent identifier (default: AGY_CONVERSATION_ID or auto-generated UUID)
#   AGENT_ROLE       Agent role description (default: DeepCoderWorkerL0)

ZSH_VERSION=${ZSH_VERSION:-}
set -eo pipefail

DEFAULT_LOG="/tmp/impl-agent.log"
DEFAULT_LOCK="/tmp/impl-agent.log.lock"

LOG_FILE="${IMPL_AGENT_LOG:-$DEFAULT_LOG}"
LOCK_FILE="${IMPL_AGENT_LOCK:-$DEFAULT_LOCK}"

# Auto-detect or generate an agent identifier
detect_agent_id() {
  if [[ -n "${AGENT_ID:-}" ]]; then
    echo "$AGENT_ID"
    return
  fi
  if [[ -n "${AGY_CONVERSATION_ID:-}" ]]; then
    echo "$AGY_CONVERSATION_ID"
    return
  fi
  # Fallback to persistent ID per session or random UUID
  local uuid
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
  fi
  if [[ -z "$uuid" ]]; then
    uuid="agent-$(od -vAn -N4 -tu4 < /dev/urandom 2>/dev/null | tr -d ' ' || echo "$$")"
  fi
  echo "$uuid"
}

CURRENT_AGENT_ID="$(detect_agent_id)"
CURRENT_ROLE="${AGENT_ROLE:-DeepCoderWorkerL0}"

# Ensure log and lock file exist and have wide read/write permissions
ensure_log_ready() {
  local dir
  dir="$(dirname "$LOG_FILE")"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" 2>/dev/null || true
  fi

  if [[ ! -f "$LOG_FILE" ]]; then
    touch "$LOG_FILE" 2>/dev/null || true
    chmod 0666 "$LOG_FILE" 2>/dev/null || true
    # Header format definition
    cat << 'EOF' > "$LOG_FILE" 2>/dev/null || true
# ==============================================================================
# OSRAMP / SIGNAL LOOM SHARED AGENT COMMUNICATION LOG
# Format: <ISO-8601-UTC> [<AGENT_ID>] [<EVENT_TYPE>] [<TOPIC>] <MESSAGE>
# Event types: INIT, ANNOUNCE, HEARTBEAT, CLAIM, RELEASE, DISCOVERY, MSG, POST
# Lock: /tmp/impl-agent.log.lock via flock
# ==============================================================================
EOF
  fi

  if [[ ! -f "$LOCK_FILE" ]]; then
    touch "$LOCK_FILE" 2>/dev/null || true
    chmod 0666 "$LOCK_FILE" 2>/dev/null || true
  fi
}

# Append a line safely with flock
append_log_entry() {
  local event="$1"
  local topic="$2"
  local message="$3"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  ensure_log_ready

  local entry="${ts} [${CURRENT_AGENT_ID}] [${event}] [${topic}] ${message}"

  if command -v flock >/dev/null 2>&1; then
    (
      flock -x -w 5 200 || {
        echo "Error: timeout acquiring log lock: $LOCK_FILE" >&2
        return 1
      }
      echo "$entry" >> "$LOG_FILE"
      chmod 0666 "$LOG_FILE" 2>/dev/null || true
    ) 200>"$LOCK_FILE"
  else
    # Simple atomic append fallback
    echo "$entry" >> "$LOG_FILE"
  fi

  echo "$entry"
}

usage() {
  cat << EOF
Usage: $(basename "$0") [options] <command> [arguments...]

Commands:
  init                           Initialize the log file and headers
  announce [role] [details...]   Register agent presence on the shared bus
  heartbeat [details...]         Record liveness & ongoing progress
  claim <resource> [reason...]   Claim a file/subsystem to prevent concurrent collision
  release <resource> [status...] Release a previously claimed resource
  claims                         List currently active, unreleased claims
  discover <sev> <topic> <msg>   Report an implementation error, bug, or demo data finding
  msg <target|all> <message...>  Send a broadcast or targeted agent message
  post <event> <topic> <msg...>  Post a generic structured event line
  read [N|all]                   Print the last N log entries (default: 50)
  tail [args...]                 Follow the log file
  status                         Overview of active agents and claims

Options:
  --log <path>                   Path to log file (or set \$IMPL_AGENT_LOG)
  --agent <id>                   Set Agent ID (or set \$AGENT_ID)
  --role <role>                  Set Agent Role (or set \$AGENT_ROLE)
  --force                        Force claim override
  -h, --help                     Show this help message
EOF
}

cmd_init() {
  ensure_log_ready
  append_log_entry "INIT" "system" "Log channel initialized or confirmed at $LOG_FILE"
}

cmd_announce() {
  local role="${1:-$CURRENT_ROLE}"
  shift || true
  local details="$*"
  if [[ -z "$details" ]]; then
    local branch
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    details="Online on branch=${branch} cwd=$(pwd)"
  fi
  append_log_entry "ANNOUNCE" "agent" "role=${role} ${details}"
}

cmd_heartbeat() {
  local details="$*"
  if [[ -z "$details" ]]; then
    details="Active and running"
  fi
  append_log_entry "HEARTBEAT" "agent" "${details}"
}

cmd_claim() {
  local force=0
  if [[ "$1" == "--force" ]]; then
    force=1
    shift
  fi

  local resource="${1:-}"
  if [[ -z "$resource" ]]; then
    echo "Error: 'claim' requires a resource path or name" >&2
    return 2
  fi
  shift
  local reason="${*:-Working on resource}"

  ensure_log_ready

  # Check existing active claims
  local existing
  existing="$(cmd_claims | grep -F "[${resource}]" || true)"
  if [[ -n "$existing" && "$force" -eq 0 ]]; then
    echo "Conflict warning: Resource [${resource}] is already claimed:" >&2
    echo "  $existing" >&2
    echo "Use --force to override claim." >&2
    return 1
  fi

  append_log_entry "CLAIM" "$resource" "$reason"
}

cmd_release() {
  local resource="${1:-}"
  if [[ -z "$resource" ]]; then
    echo "Error: 'release' requires a resource path or name" >&2
    return 2
  fi
  shift
  local status="${*:-Completed}"
  append_log_entry "RELEASE" "$resource" "$status"
}

cmd_claims() {
  ensure_log_ready
  # Parse log: track latest status (CLAIM vs RELEASE) per resource
  awk '
    /^#/ { next }
    /\[CLAIM\]/ {
      match($0, /\[CLAIM\] \[([^]]+)\]/, m)
      if (m[1] != "") {
        claims[m[1]] = $0
      }
    }
    /\[RELEASE\]/ {
      match($0, /\[RELEASE\] \[([^]]+)\]/, m)
      if (m[1] != "") {
        delete claims[m[1]]
      }
    }
    END {
      for (r in claims) {
        print claims[r]
      }
    }
  ' "$LOG_FILE"
}

cmd_discover() {
  local sev="${1:-}"
  local topic="${2:-}"
  if [[ -z "$sev" || -z "$topic" ]]; then
    echo "Error: 'discover' requires <severity> and <topic>" >&2
    return 2
  fi
  shift 2
  local details="$*"
  if [[ -z "$details" ]]; then
    echo "Error: 'discover' requires details/description" >&2
    return 2
  fi
  append_log_entry "DISCOVERY" "$topic" "severity=${sev} ${details}"
}

cmd_msg() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    echo "Error: 'msg' requires <target>" >&2
    return 2
  fi
  shift
  local msg="$*"
  if [[ -z "$msg" ]]; then
    echo "Error: 'msg' requires a message body" >&2
    return 2
  fi
  append_log_entry "MSG" "@${target}" "$msg"
}

cmd_post() {
  local event="${1:-}"
  local topic="${2:-}"
  if [[ -z "$event" || -z "$topic" ]]; then
    echo "Error: 'post' requires <event> and <topic>" >&2
    return 2
  fi
  shift 2
  local msg="$*"
  if [[ -z "$msg" ]]; then
    echo "Error: 'post' requires a message body" >&2
    return 2
  fi
  append_log_entry "$event" "$topic" "$msg"
}

cmd_read() {
  ensure_log_ready
  local count="${1:-50}"
  if [[ "$count" == "all" ]]; then
    cat "$LOG_FILE"
  else
    tail -n "$count" "$LOG_FILE"
  fi
}

cmd_tail() {
  ensure_log_ready
  tail -f "$LOG_FILE" "$@"
}

cmd_status() {
  ensure_log_ready
  echo "=== Shared Agent Log Status ==="
  echo "Log path:  $LOG_FILE"
  echo "Lock path: $LOCK_FILE"
  echo "Log size:  $(wc -c < "$LOG_FILE" 2>/dev/null || echo 0) bytes ($(wc -l < "$LOG_FILE" 2>/dev/null || echo 0) lines)"
  echo ""
  echo "--- Active Claims ---"
  local claims
  claims="$(cmd_claims)"
  if [[ -z "$claims" ]]; then
    echo "  (No active claims)"
  else
    echo "$claims"
  fi
  echo ""
  echo "--- Recent Discoveries ---"
  local discoveries
  discoveries="$(grep '\[DISCOVERY\]' "$LOG_FILE" | tail -n 5 || true)"
  if [[ -z "$discoveries" ]]; then
    echo "  (No discoveries recorded)"
  else
    echo "$discoveries"
  fi
  echo ""
  echo "--- Registered Agents ---"
  grep -E '\[ANNOUNCE\]|\[HEARTBEAT\]' "$LOG_FILE" | awk '{print $2}' | tr -d '[]' | sort -u || true
}

main() {
  local force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --log)
        LOG_FILE="$2"
        LOCK_FILE="${2}.lock"
        shift 2
        ;;
      --agent)
        CURRENT_AGENT_ID="$2"
        shift 2
        ;;
      --role)
        CURRENT_ROLE="$2"
        shift 2
        ;;
      --force)
        force=1
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -eq 0 ]]; then
    usage
    return 2
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    init)
      cmd_init "$@"
      ;;
    announce)
      cmd_announce "$@"
      ;;
    heartbeat)
      cmd_heartbeat "$@"
      ;;
    claim)
      if [[ "$force" -eq 1 ]]; then
        cmd_claim --force "$@"
      else
        cmd_claim "$@"
      fi
      ;;
    release)
      cmd_release "$@"
      ;;
    claims)
      cmd_claims "$@"
      ;;
    discover)
      cmd_discover "$@"
      ;;
    msg)
      cmd_msg "$@"
      ;;
    post)
      cmd_post "$@"
      ;;
    read)
      cmd_read "$@"
      ;;
    tail)
      cmd_tail "$@"
      ;;
    status)
      cmd_status "$@"
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
