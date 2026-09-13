#!/usr/bin/env bash
# ==============================================================================
# AgentMaxxing Linux Host Sensor — Startup & Confinement Supervisor
# ==============================================================================
# Launches the external AgentMaxxing Linux agent strictly confined inside the
# nono 0.73.0 Landlock/network sandbox after binary digest verification.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
NONO_BIN="${NONO_BIN:-/usr/bin/nono}"
AGENT_BINARY="${AGENT_BINARY:-/opt/agentmaxxing/bin/agent}"
PROFILE_PATH="${PROFILE_PATH:-/opt/agentmaxxing/profile.json}"
LOG_TAG="agentmaxxing-sensor-start"

log_info() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] [INFO] [$LOG_TAG] $*" >&2
}

log_crit() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] [CRITICAL] [$LOG_TAG] $*" >&2
}

# 1. Run the binary digest and preflight gate
log_info "Executing binary digest and preflight verification gate..."
if [[ -f "$SCRIPT_DIR/digest_gate.sh" ]]; then
    NONO_BIN="$NONO_BIN" \
    AGENT_BINARY="$AGENT_BINARY" \
    PROFILE_PATH="$PROFILE_PATH" \
    "$SCRIPT_DIR/digest_gate.sh" || {
        log_crit "Preflight gate failed. Aborting startup."
        exit 1
    }
fi

# 2. Resolve profile path
if [[ ! -f "$PROFILE_PATH" ]]; then
    FALLBACK_PROFILE="$SCRIPT_DIR/../profile.json"
    if [[ -f "$FALLBACK_PROFILE" ]]; then
        PROFILE_PATH="$(realpath "$FALLBACK_PROFILE")"
        log_info "Using relative profile path: $PROFILE_PATH"
    else
        log_crit "Confinement profile not found at '$PROFILE_PATH'"
        exit 1
    fi
fi

# 3. Strip sensitive credential environment variables before spawning sandbox
DENY_VARS=(
    "SSH_AUTH_SOCK"
    "SSH_ASKPASS"
    "AWS_ACCESS_KEY_ID"
    "AWS_SECRET_ACCESS_KEY"
    "AWS_SESSION_TOKEN"
    "GITHUB_TOKEN"
    "GH_TOKEN"
    "GH_ENTERPRISE_TOKEN"
    "KUBECONFIG"
    "VAULT_TOKEN"
    "GNUPGHOME"
    "GPG_TTY"
    "PINENTRY_USER_DATA"
)

for var_name in "${DENY_VARS[@]}"; do
    if [[ -n "${!var_name:-}" ]]; then
        log_info "Stripping sensitive environment variable: $var_name"
        unset "$var_name"
    fi
done

# 4. Prepare required runtime state directories if accessible
mkdir -p /var/lib/agentmaxxing/work /var/lib/agentmaxxing/output /var/lib/agentmaxxing/audit /run/agentmaxxing 2>/dev/null || true

# Set XDG_STATE_HOME to audit spool to isolate nono internal state
if [[ -w "/var/lib/agentmaxxing/audit" ]]; then
    export XDG_STATE_HOME="/var/lib/agentmaxxing/audit"
fi

# 5. Execute agent under nono confinement
log_info "Launching agent binary '$AGENT_BINARY' under nono 0.73.0 confinement profile '$PROFILE_PATH'..."
exec "$NONO_BIN" run \
    --silent \
    --no-diagnostics \
    --profile "$PROFILE_PATH" \
    -- \
    "$AGENT_BINARY" "$@"
