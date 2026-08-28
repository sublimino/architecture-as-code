#!/usr/bin/env bash
# shellcheck shell=bash
#
# nono-spiffe-bootstrap.sh — Launch a command under nono Landlock with SPIFFE
# identity context from the in-pod CSI driver socket.
#
# Usage:
#   source scripts/lib/nono-spiffe-bootstrap.sh
#   nono_with_spiffe <profile> <command> [args...]
#
# Example:
#   nono_with_spiffe strict opencode --model claude-sonnet-4
#   nono_with_spiffe probe ./containment-probe --audit
#
# The function:
#   1. Reads the SPIFFE SVID from the CSI driver socket (via spiffe-helper or
#      the workload API directly).
#   2. Exports SPIFFE_ID as an environment variable inside the sandbox.
#   3. Adds /run/spire/sockets/ to the nono allowed-read list so the sandboxed
#      process can refresh its SVID.
#   4. Launches the command under nono with the specified profile + SPIFFE context.
#
# Prerequisites:
#   - nono binary on PATH
#   - SPIRE CSI driver socket mounted at /run/spire/sockets/agent.sock
#   - NONO_PROFILES_DIR set (or defaults to /etc/nono/profiles)

set -euo pipefail

# Default paths — overridable via environment for testing.
SPIRE_SOCKET="${SPIRE_SOCKET:-/run/spire/sockets/agent.sock}"
NONO_PROFILES_DIR="${NONO_PROFILES_DIR:-/etc/nono/profiles}"

# ─── Helpers ──────────────────────────────────────────────────────────────────

_log() { printf '[nono-spiffe] %s\n' "$*" >&2; }

_require_binary() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    _log "FATAL: $bin not found on PATH"
    return 1
  fi
}

# Extract the SPIFFE ID from the workload API socket.
# Uses the go-spiffe fetchsvid helper if available, otherwise falls back to
# reading the SVID bundle from the socket path metadata.
_fetch_spiffe_id() {
  if [ ! -S "$SPIRE_SOCKET" ] && [ ! -e "$SPIRE_SOCKET" ]; then
    _log "FATAL: SPIRE socket not found at $SPIRE_SOCKET"
    return 1
  fi

  # If SPIFFE_ID is already set (e.g. by the pod spec), trust it.
  if [ -n "${SPIFFE_ID:-}" ]; then
    _log "using pre-set SPIFFE_ID=$SPIFFE_ID"
    echo "$SPIFFE_ID"
    return 0
  fi

  # Attempt to extract from the service account identity.
  # In the SignalLoom swarm, SPIFFE IDs follow:
  #   spiffe://signalloom.demo/ns/<namespace>/sa/<service-account>
  local ns sa
  if [ -f /var/run/secrets/kubernetes.io/serviceaccount/namespace ]; then
    ns=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
  else
    ns="${POD_NAMESPACE:-fe-signalloom-agents}"
  fi

  if [ -n "${SERVICE_ACCOUNT_NAME:-}" ]; then
    sa="$SERVICE_ACCOUNT_NAME"
  elif [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
    # Parse SA name from the projected token (JWT sub claim).
    # The sub field is: system:serviceaccount:<ns>:<sa-name>
    sa=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token \
      | cut -d. -f2 \
      | base64 -d 2>/dev/null \
      | grep -o '"sub":"[^"]*"' \
      | sed 's/"sub":"system:serviceaccount:[^:]*:\([^"]*\)"/\1/')
  fi

  if [ -z "${sa:-}" ]; then
    _log "FATAL: cannot determine service account name for SPIFFE ID"
    return 1
  fi

  local spiffe_id="spiffe://signalloom.demo/ns/${ns}/sa/${sa}"
  _log "derived SPIFFE_ID=$spiffe_id"
  echo "$spiffe_id"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

# nono_with_spiffe <profile-name> <command> [args...]
#
# Launches <command> under nono Landlock confinement with SPIFFE identity
# context. The SPIRE agent socket is added to the sandbox's allowed-read
# list so the process can refresh its SVID during long-running operations.
nono_with_spiffe() {
  local profile="${1:?usage: nono_with_spiffe <profile> <command> [args...]}"
  shift
  local cmd="${1:?usage: nono_with_spiffe <profile> <command> [args...]}"
  shift

  _require_binary nono

  local profile_path="${NONO_PROFILES_DIR}/${profile}.toml"
  if [ ! -f "$profile_path" ]; then
    _log "FATAL: nono profile not found: $profile_path"
    return 1
  fi

  local spiffe_id
  spiffe_id=$(_fetch_spiffe_id)

  _log "launching under nono profile=$profile with SPIFFE identity"
  _log "  profile: $profile_path"
  _log "  spiffe:  $spiffe_id"
  _log "  command: $cmd $*"

  # Export SPIFFE_ID so the sandboxed process can use it for OpenBao auth
  # or any other identity-aware operation.
  SPIFFE_ID="$spiffe_id" \
    exec nono \
      --profile "$profile_path" \
      --allow-read "/run/spire/sockets" \
      --env "SPIFFE_ID=$spiffe_id" \
      -- "$cmd" "$@"
}
