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
#   impl-agent-log.sh claim [--force] [--ttl <sec>] <resource> [reason...]
#   impl-agent-log.sh release [--force] <resource> [status...]
#   impl-agent-log.sh claims [--all|--expired]
#   impl-agent-log.sh discover <severity> <topic> <details...>
#   impl-agent-log.sh msg <target|all> <message...>
#   impl-agent-log.sh post <EVENT> <TOPIC> <message...>
#   impl-agent-log.sh read [N|all] [--event <ev>] [--agent <id>] [--topic <top>]
#   impl-agent-log.sh tail [tail-args...]
#   impl-agent-log.sh status
#
# Environment variables:
#   IMPL_AGENT_LOG        Path to shared log file (default: /tmp/impl-agent.log)
#   IMPL_AGENT_LOCK       Path to lock file (default: /tmp/impl-agent.log.lock)
#   IMPL_AGENT_CLAIM_TTL  Default claim lease TTL in seconds (default: 900)
#   AGENT_ID              Agent identifier (default: AGY_CONVERSATION_ID or auto-generated UUID)
#   AGENT_ROLE            Agent role description (default: DeepCoderWorkerL0)

ZSH_VERSION=${ZSH_VERSION:-}
set -eo pipefail

DEFAULT_LOG="/tmp/impl-agent.log"
DEFAULT_LOCK="/tmp/impl-agent.log.lock"
DEFAULT_TTL="${IMPL_AGENT_CLAIM_TTL:-900}"

LOG_FILE="${IMPL_AGENT_LOG:-$DEFAULT_LOG}"
LOCK_FILE="${IMPL_AGENT_LOCK:-$DEFAULT_LOCK}"
CLI_TTL=""

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

  if [[ ! -f "$LOCK_FILE" ]]; then
    touch "$LOCK_FILE" 2>/dev/null || true
    chmod 0666 "$LOCK_FILE" 2>/dev/null || true
  fi

  if [[ ! -f "$LOG_FILE" ]]; then
    # Protect initial creation under lock so concurrent inits don't clobber each other
    if command -v flock >/dev/null 2>&1; then
      (
        flock -x -w 5 200 || exit 1
        if [[ ! -s "$LOG_FILE" ]]; then
          cat << 'EOF' > "$LOG_FILE"
# ==============================================================================
# OSRAMP / SIGNAL LOOM SHARED AGENT COMMUNICATION LOG
# Format: <ISO-8601-UTC> [<AGENT_ID>] [<EVENT_TYPE>] [<TOPIC>] <MESSAGE>
# Event types: INIT, ANNOUNCE, HEARTBEAT, CLAIM, RELEASE, DISCOVERY, MSG, POST
# Lock: /tmp/impl-agent.log.lock via flock
# ==============================================================================
EOF
          chmod 0666 "$LOG_FILE" 2>/dev/null || true
        fi
      ) 200>>"$LOCK_FILE" 2>/dev/null || true
    else
      if [[ ! -s "$LOG_FILE" ]]; then
        cat << 'EOF' > "$LOG_FILE" 2>/dev/null || true
# ==============================================================================
# OSRAMP / SIGNAL LOOM SHARED AGENT COMMUNICATION LOG
# Format: <ISO-8601-UTC> [<AGENT_ID>] [<EVENT_TYPE>] [<TOPIC>] <MESSAGE>
# Event types: INIT, ANNOUNCE, HEARTBEAT, CLAIM, RELEASE, DISCOVERY, MSG, POST
# Lock: /tmp/impl-agent.log.lock via flock
# ==============================================================================
EOF
        chmod 0666 "$LOG_FILE" 2>/dev/null || true
      fi
    fi
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
    if ! (
      flock -x -w 5 200 || {
        echo "Error: timeout acquiring log lock: $LOCK_FILE" >&2
        exit 1
      }
      echo "$entry" >> "$LOG_FILE"
      chmod 0666 "$LOG_FILE" 2>/dev/null || true
    ) 200>>"$LOCK_FILE"; then
      return 1
    fi
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
  claim [flags] <res> [reason..] Claim a resource to prevent concurrent collision
                                   Flags: --force, --ttl <seconds>
  release [flags] <res> [status] Release a claimed resource
                                   Flags: --force
  claims [--all|--expired]       List active or expired claims
  discover <sev> <topic> <msg>   Report an implementation error, bug, or demo data finding
  msg <target|all> <message...>  Send a broadcast or targeted agent message
  post <event> <topic> <msg...>  Post a generic structured event line
  read [N|all] [options...]      Print log entries (supports --event, --agent, --topic)
  tail [tail-args...]            Follow the log file
  status                         Overview of active agents and claims

Options:
  --log <path>                   Path to log file (or set \$IMPL_AGENT_LOG)
  --lock <path>                  Path to lock file (or set \$IMPL_AGENT_LOCK)
  --agent <id>                   Set Agent ID (or set \$AGENT_ID)
  --role <role>                  Set Agent Role (or set \$AGENT_ROLE)
  --ttl <seconds>                Default lease TTL in seconds (default: 900)
  --force                        Force claim override or release
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

# Helper: extract current active claim line for a specific resource
get_active_claim() {
  local target_res="$1"
  ensure_log_ready
  awk -v target="$target_res" '
    function extract_field(line, tag) {
      prefix = " [" tag "] ["
      s = index(line, prefix)
      if (s == 0) return ""
      rem = substr(line, s + length(prefix))
      e = index(rem, "] ")
      if (e > 0) return substr(rem, 1, e - 1)
      if (substr(rem, length(rem)) == "]") return substr(rem, 1, length(rem) - 1)
      return ""
    }
    /^#/ { next }
    /\[CLAIM\]/ {
      res = extract_field($0, "CLAIM")
      if (res != "") {
        claims[res] = $0
      }
    }
    /\[RELEASE\]/ {
      res = extract_field($0, "RELEASE")
      if (res != "") {
        delete claims[res]
      }
    }
    END {
      if (target in claims) {
        print claims[target]
      }
    }
  ' "$LOG_FILE"
}

cmd_claim() {
  local force=0
  local ttl=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)
        force=1
        shift
        ;;
      --ttl)
        ttl="$2"
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done

  local resource="${1:-}"
  if [[ -z "$resource" ]]; then
    echo "Error: 'claim' requires a resource path or name" >&2
    return 2
  fi
  shift
  local reason="${*:-Working on resource}"

  local effective_ttl="${ttl:-$CLI_TTL}"
  if [[ -z "$effective_ttl" ]]; then
    effective_ttl="$DEFAULT_TTL"
  fi
  if [[ "$effective_ttl" == "never" ]]; then
    effective_ttl=0
  fi

  ensure_log_ready

  local existing
  existing="$(get_active_claim "$resource")"

  if [[ -n "$existing" ]]; then
    local claim_ts="" claim_agent=""
    if [[ "$existing" =~ ^([0-9T:Z-]+)[[:space:]]+\[([^]]+)\] ]]; then
      claim_ts="${BASH_REMATCH[1]}"
      claim_agent="${BASH_REMATCH[2]}"
    fi

    local recorded_ttl="$DEFAULT_TTL"
    if [[ "$existing" =~ \[ttl=([0-9]+)\] ]]; then
      recorded_ttl="${BASH_REMATCH[1]}"
    fi

    local now claim_epoch age is_expired=0
    now=$(date -u +%s)
    claim_epoch=$(date -u -d "$claim_ts" +%s 2>/dev/null || echo 0)
    if [[ "$claim_epoch" -gt 0 ]]; then
      age=$(( now - claim_epoch ))
    else
      age=0
    fi
    if [[ "$recorded_ttl" -gt 0 && "$age" -gt "$recorded_ttl" ]]; then
      is_expired=1
    fi

    if [[ "$CURRENT_AGENT_ID" == "$claim_agent" ]]; then
      # Same agent renewing its own claim
      append_log_entry "CLAIM" "$resource" "[ttl=${effective_ttl}] (renewed) $reason"
      return 0
    elif [[ "$is_expired" -eq 1 ]]; then
      # Prior claim expired
      echo "Notice: Previous claim by [${claim_agent}] expired (${age}s > ${recorded_ttl}s). Acquiring claim." >&2
      append_log_entry "CLAIM" "$resource" "[ttl=${effective_ttl}] (lease-acquired:expired-from:${claim_agent}) $reason"
      return 0
    elif [[ "$force" -eq 1 ]]; then
      # Force override
      echo "Notice: Overriding active claim by [${claim_agent}] via --force." >&2
      append_log_entry "CLAIM" "$resource" "[ttl=${effective_ttl}] (force-takeover:from:${claim_agent}) $reason"
      return 0
    else
      # Real conflict
      echo "Conflict warning: Resource [${resource}] is already claimed by [${claim_agent}] (${age}s ago, TTL: ${recorded_ttl}s):" >&2
      echo "  $existing" >&2
      echo "Use --force to override claim or wait for TTL expiration." >&2
      return 1
    fi
  else
    # Fresh claim
    append_log_entry "CLAIM" "$resource" "[ttl=${effective_ttl}] $reason"
  fi
}

cmd_release() {
  local force=0
  if [[ "$1" == "--force" ]]; then
    force=1
    shift
  fi

  local resource="${1:-}"
  if [[ -z "$resource" ]]; then
    echo "Error: 'release' requires a resource path or name" >&2
    return 2
  fi
  shift
  local status="${*:-Completed}"

  ensure_log_ready

  local existing
  existing="$(get_active_claim "$resource")"
  if [[ -n "$existing" ]]; then
    local claim_agent=""
    if [[ "$existing" =~ ^[0-9T:Z-]+[[:space:]]+\[([^]]+)\] ]]; then
      claim_agent="${BASH_REMATCH[1]}"
    fi
    if [[ -n "$claim_agent" && "$claim_agent" != "$CURRENT_AGENT_ID" && "$force" -eq 0 ]]; then
      echo "Error: Resource [${resource}] is claimed by [${claim_agent}], not [${CURRENT_AGENT_ID}]." >&2
      echo "Use --force to release another agent's claim." >&2
      return 1
    fi
  fi

  append_log_entry "RELEASE" "$resource" "$status"
}

cmd_claims() {
  local show_all=0
  local show_expired=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        show_all=1
        shift
        ;;
      --expired)
        show_expired=1
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  ensure_log_ready
  local raw_claims
  raw_claims="$(awk '
    function extract_field(line, tag) {
      prefix = " [" tag "] ["
      s = index(line, prefix)
      if (s == 0) return ""
      rem = substr(line, s + length(prefix))
      e = index(rem, "] ")
      if (e > 0) return substr(rem, 1, e - 1)
      if (substr(rem, length(rem)) == "]") return substr(rem, 1, length(rem) - 1)
      return ""
    }
    /^#/ { next }
    /\[CLAIM\]/ {
      res = extract_field($0, "CLAIM")
      if (res != "") {
        claims[res] = $0
      }
    }
    /\[RELEASE\]/ {
      res = extract_field($0, "RELEASE")
      if (res != "") {
        delete claims[res]
      }
    }
    END {
      for (r in claims) {
        print claims[r]
      }
    }
  ' "$LOG_FILE")"

  if [[ -z "$raw_claims" ]]; then
    return 0
  fi

  local now
  now=$(date -u +%s)

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local claim_ts=""
    if [[ "$line" =~ ^([0-9T:Z-]+) ]]; then
      claim_ts="${BASH_REMATCH[1]}"
    fi
    local claim_ttl="$DEFAULT_TTL"
    if [[ "$line" =~ \[ttl=([0-9]+)\] ]]; then
      claim_ttl="${BASH_REMATCH[1]}"
    fi
    local claim_epoch age is_expired=0
    claim_epoch=$(date -u -d "$claim_ts" +%s 2>/dev/null || echo 0)
    if [[ "$claim_epoch" -gt 0 ]]; then
      age=$(( now - claim_epoch ))
    else
      age=0
    fi
    if [[ "$claim_ttl" -gt 0 && "$age" -gt "$claim_ttl" ]]; then
      is_expired=1
    fi

    if [[ "$show_expired" -eq 1 ]]; then
      if [[ "$is_expired" -eq 1 ]]; then
        echo "$line [EXPIRED: age=${age}s ttl=${claim_ttl}s]"
      fi
    elif [[ "$show_all" -eq 1 ]]; then
      if [[ "$is_expired" -eq 1 ]]; then
        echo "$line [EXPIRED: age=${age}s ttl=${claim_ttl}s]"
      else
        echo "$line"
      fi
    else
      # Default: show active, unexpired claims
      if [[ "$is_expired" -eq 0 ]]; then
        echo "$line"
      fi
    fi
  done <<< "$raw_claims"
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
  local clean_target="${target#@}"
  append_log_entry "MSG" "@${clean_target}" "$msg"
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
  local event_filter=""
  local agent_filter=""
  local topic_filter=""
  local count="50"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --event)
        event_filter="$2"
        shift 2
        ;;
      --agent)
        agent_filter="$2"
        shift 2
        ;;
      --topic)
        topic_filter="$2"
        shift 2
        ;;
      -n)
        count="$2"
        shift 2
        ;;
      all)
        count="all"
        shift
        ;;
      [0-9]*)
        count="$1"
        shift
        ;;
      *)
        echo "Error: unrecognized read option: $1" >&2
        return 2
        ;;
    esac
  done

  # Validate count
  if [[ "$count" != "all" && ! "$count" =~ ^[0-9]+$ ]]; then
    echo "Error: read count must be a positive integer or 'all', got '$count'" >&2
    return 2
  fi

  if [[ -n "$event_filter" || -n "$agent_filter" || -n "$topic_filter" ]]; then
    local stream
    stream="$(awk -v ev="$event_filter" -v ag="$agent_filter" -v top="$topic_filter" '
      /^#/ { next }
      {
        line = $0
        if (ev != "") {
          if (index(line, "[" ev "]") == 0) next
        }
        if (ag != "") {
          if (index(line, "[" ag "]") == 0 && index(line, "[agent:" ag "]") == 0) next
        }
        if (top != "") {
          if (index(line, "[" top "]") == 0 && index(line, "[@" top "]") == 0) next
        }
        print line
      }
    ' "$LOG_FILE")"
    if [[ "$count" == "all" ]]; then
      echo "$stream"
    else
      echo "$stream" | tail -n "$count"
    fi
  else
    if [[ "$count" == "all" ]]; then
      cat "$LOG_FILE"
    else
      tail -n "$count" "$LOG_FILE"
    fi
  fi
}

cmd_tail() {
  ensure_log_ready
  tail "$@" -f "$LOG_FILE"
}

cmd_status() {
  ensure_log_ready
  echo "=== Shared Agent Log Status ==="
  echo "Log path:  $LOG_FILE"
  echo "Lock path: $LOCK_FILE"
  echo "Log size:  $(wc -c < "$LOG_FILE" 2>/dev/null || echo 0) bytes ($(wc -l < "$LOG_FILE" 2>/dev/null || echo 0) lines)"
  echo ""
  echo "--- Active Claims ---"
  local active_claims
  active_claims="$(cmd_claims)"
  if [[ -z "$active_claims" ]]; then
    echo "  (No active claims)"
  else
    echo "$active_claims"
  fi

  local expired_claims
  expired_claims="$(cmd_claims --expired)"
  if [[ -n "$expired_claims" ]]; then
    echo ""
    echo "--- Expired Claims ---"
    echo "$expired_claims"
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
  local registered
  registered="$(awk '
    /^#/ { next }
    /^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[^]]*\][ \t]+\[agent:([^]]+)\]/ {
      match($0, /^\[[^]]+\][ \t]+\[agent:([^]]+)\]/, m)
      if (m[1] != "") { agents[m[1]] = 1 }
      next
    }
    /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ \t]+[ \t]+\[([^]]+)\]/ {
      match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ \t]+[ \t]+\[([^]]+)\]/, m)
      if (m[1] != "" && m[1] != "system") { agents[m[1]] = 1 }
      next
    }
    END {
      for (a in agents) {
        print a
      }
    }
  ' "$LOG_FILE" | sort -u)"
  if [[ -z "$registered" ]]; then
    echo "  (No agents registered)"
  else
    echo "$registered"
  fi
}

main() {
  local force=0
  local ttl=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --log)
        LOG_FILE="$2"
        LOCK_FILE="${2}.lock"
        shift 2
        ;;
      --lock)
        LOCK_FILE="$2"
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
      --ttl)
        CLI_TTL="$2"
        ttl="$2"
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
      local claim_args=()
      if [[ "$force" -eq 1 ]]; then
        claim_args+=(--force)
      fi
      if [[ -n "$ttl" ]]; then
        claim_args+=(--ttl "$ttl")
      fi
      cmd_claim "${claim_args[@]}" "$@"
      ;;
    release)
      if [[ "$force" -eq 1 ]]; then
        cmd_release --force "$@"
      else
        cmd_release "$@"
      fi
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
