#!/usr/bin/env bash
# ==============================================================================
# Signal Loom: Nono Capability Probe & FAIL-CLOSED Execution Wrapper (SP-5)
# Component: d2-signalloom/apps/fe-signalloom-agents/probe-nono-capability.sh
#
# Invariant (SP-5, corrected): enforcement evidence may only be emitted when
# enforcement is REAL. The previous version detected that nono/Landlock was
# absent, logged "executing unconfined", then ran a status:"healthy" heartbeat
# loop forever — producing audit evidence of containment while nothing was
# contained. That is the exact "evidence without enforcement" failure this
# rewrite removes.
#
# Behaviour now:
#   * Nono present AND Landlock enforceable  -> the workload (a supplied command,
#     or the default heartbeat loop) runs WRAPPED in real `nono run` with a
#     kernel Landlock allow-list. Only then does telemetry carry
#     nono_capability_available:true and sandboxing:"landlock".
#   * Nono absent OR Landlock not enforceable -> FAIL CLOSED: emit a single
#     explicit status:"unenforced", enforcement:"none" record (which can never
#     be mistaken for a healthy/enforced heartbeat), emit NO landlock evidence,
#     NO healthy heartbeat, and exit NON-ZERO so Kubernetes CrashLoops the pod
#     instead of running it unconfined.
#
# The allow-list is injectable for testing (NONO_READ_PATHS / NONO_ALLOW_PATHS).
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration defaults
# ------------------------------------------------------------------------------
AGENT_ID="${AGENT_ID:-agent-nono-evidenced}"
AGENT_NAME="${AGENT_NAME:-Demo Agent (Nono Evidenced)}"
WORKLOAD_PROFILE="${WORKLOAD_PROFILE:-nono-evidenced}"
SPIFFE_SOCKET="${SPIFFE_SOCKET:-/run/spire/sockets/agent.sock}"
SPIFFE_ID="${SPIFFE_ID:-spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/${AGENT_ID}}"
NONO_FORCE_FALLBACK="${NONO_FORCE_FALLBACK:-0}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-10}"

# Landlock allow-list (space-separated). Read-only exec paths and read+write
# paths. Deliberately excludes /etc, /root and / so credential files are denied
# by the kernel. Override via env for tests / specialised workloads.
NONO_READ_PATHS="${NONO_READ_PATHS:-/usr /lib /lib64 /bin}"
NONO_ALLOW_PATHS="${NONO_ALLOW_PATHS:-/tmp}"

iso_timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# ------------------------------------------------------------------------------
# Landlock LSM + nono binary enforceability probe.
# Returns 0 ONLY when a real sandbox can be installed, 1 otherwise. There is no
# "assume available on 5.13+" guess here: enforceability is proven by asking the
# nono binary itself, so a false positive cannot grant fake evidence.
# ------------------------------------------------------------------------------
resolve_nono_bin() {
  if command -v nono >/dev/null 2>&1; then
    command -v nono
    return 0
  fi
  if [[ -n "${NONO_BIN:-}" && -x "${NONO_BIN}" ]]; then
    printf '%s\n' "${NONO_BIN}"
    return 0
  fi
  return 1
}

nono_enforceable() { # sets NONO_BIN_RESOLVED on success
  if [[ "${NONO_FORCE_FALLBACK}" == "1" || "${NONO_FORCE_FALLBACK}" == "true" ]]; then
    return 1
  fi
  local bin
  bin="$(resolve_nono_bin)" || return 1
  # Authoritative check: nono verifies its own installation AND that the kernel
  # can enforce the sandbox. "verified" in the output is the only accept signal.
  local out
  out="$("${bin}" setup --check-only 2>&1)" || return 1
  [[ "${out}" == *"verified"* ]] || return 1
  NONO_BIN_RESOLVED="${bin}"
  return 0
}

# ------------------------------------------------------------------------------
# Telemetry
# ------------------------------------------------------------------------------
emit_detected() {
  echo "{\"timestamp\":\"$(iso_timestamp)\",\"event\":\"nono_probe\",\"status\":\"enforced\",\"nono_capability_available\":true,\"binary\":\"${NONO_BIN_RESOLVED}\",\"sandboxing\":\"landlock\",\"enforcement\":\"landlock\",\"agent_id\":\"${AGENT_ID}\"}"
}

emit_unenforced() {
  # Fail-closed telemetry. NOTE: no "healthy", no "landlock" evidence, no
  # nono_capability_available:true — this record can never be mistaken for an
  # enforced heartbeat by any downstream collector.
  echo "{\"timestamp\":\"$(iso_timestamp)\",\"event\":\"nono_probe\",\"status\":\"unenforced\",\"nono_capability_available\":false,\"enforcement\":\"none\",\"lifecycle_state\":\"refused\",\"error\":\"nono/Landlock not enforceable on this substrate; refusing to run unconfined (fail-closed)\",\"agent_id\":\"${AGENT_ID}\"}"
}

# ------------------------------------------------------------------------------
# Build the nono run flag vector from the allow-list.
# ------------------------------------------------------------------------------
nono_flags() {
  # CWD is expected to be inside an allowed path (the image sets WORKDIR to one,
  # e.g. /tmp or /workspace), so no --allow-cwd is needed. nono refuses to start
  # if the working directory is not covered — that is itself fail-closed.
  local -a flags=(run -s --no-audit)
  local p
  for p in ${NONO_READ_PATHS}; do flags+=(-r "${p}"); done
  for p in ${NONO_ALLOW_PATHS}; do flags+=(-a "${p}"); done
  printf '%s\n' "${flags[@]}"
}

# ------------------------------------------------------------------------------
# CLI flags
# ------------------------------------------------------------------------------
DRY_RUN=false
CHECK_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-d) DRY_RUN=true; shift ;;
    --check|-c)   CHECK_ONLY=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--dry-run|--check] [--] [COMMAND [ARGS...]]"
      echo "Signal Loom nono capability probe & fail-closed execution wrapper."
      echo "Exits non-zero when nono/Landlock cannot be enforced."
      exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

# ------------------------------------------------------------------------------
# Probe + dispatch
# ------------------------------------------------------------------------------
if ! nono_enforceable; then
  emit_unenforced
  # Fail-closed in every mode, including readiness probes: an unenforceable
  # substrate is not "ready".
  exit 1
fi

emit_detected

if [[ "${DRY_RUN}" == "true" || "${CHECK_ONLY}" == "true" ]]; then
  exit 0
fi

mapfile -t NONO_RUN_FLAGS < <(nono_flags)

if [[ $# -gt 0 ]]; then
  # Supplied command, wrapped in real nono.
  exec "${NONO_BIN_RESOLVED}" "${NONO_RUN_FLAGS[@]}" -- "$@"
fi

# Default workload: the heartbeat loop, itself confined under real nono. The
# loop runs inside the sandbox (a child /bin/sh), so its healthy heartbeats are
# emitted by a genuinely contained process. SIGTERM/SIGINT/SIGHUP reach the
# sandboxed child for graceful shutdown.
export AGENT_ID AGENT_NAME WORKLOAD_PROFILE SPIFFE_ID HEARTBEAT_INTERVAL
export SESSION_ID="audit-sess-${AGENT_ID}-$(date +%s)"
HEARTBEAT_SCRIPT='
set -eu
seq=0
trap "echo \"[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${AGENT_ID}] Graceful shutdown received\"; exit 0" TERM INT HUP
while true; do
  seq=$((seq + 1))
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "{\"timestamp\":\"${now}\",\"agent_id\":\"${AGENT_ID}\",\"name\":\"${AGENT_NAME}\",\"profile\":\"${WORKLOAD_PROFILE}\",\"spiffe_id\":\"${SPIFFE_ID}\",\"status\":\"healthy\",\"lifecycle_state\":\"active\",\"heartbeat_seq\":${seq},\"nono_capability_available\":true,\"enforcement\":\"landlock\",\"audit_session_id\":\"${SESSION_ID}\"}"
  sleep "${HEARTBEAT_INTERVAL}" &
  wait $!
done
'
exec "${NONO_BIN_RESOLVED}" "${NONO_RUN_FLAGS[@]}" -- /bin/sh -c "${HEARTBEAT_SCRIPT}"
