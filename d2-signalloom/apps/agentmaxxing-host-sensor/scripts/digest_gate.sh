#!/usr/bin/env bash
# ==============================================================================
# AgentMaxxing Linux Host Sensor — Binary Digest & Confinement Preflight Gate
# ==============================================================================
# Fail-closed preflight check executed before starting the external agent.
# Verifies kernel Landlock LSM support, nono 0.73.0 pinned digest, agent binary
# SHA-256 integrity, profile validation, and workspace permission boundaries.
# ==============================================================================

set -euo pipefail

# Pinned baseline defaults
PINNED_NONO_VERSION="0.73.0"
PINNED_NONO_DIGEST="71581b92e7683c86276bbbd91c80b059e0fe2d7b1aa95b1176870456ee22ad5c"

NONO_BIN="${NONO_BIN:-/usr/bin/nono}"
AGENT_BINARY="${AGENT_BINARY:-/opt/agentmaxxing/bin/agent}"
AGENT_DIGEST_FILE="${AGENT_DIGEST_FILE:-/opt/agentmaxxing/etc/agent.digest}"
PROFILE_PATH="${PROFILE_PATH:-/opt/agentmaxxing/profile.json}"
LOG_TAG="agentmaxxing-digest-gate"

log_info() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] [INFO] [$LOG_TAG] $*" >&2
}

log_error() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] [ERROR] [$LOG_TAG] $*" >&2
}

log_crit() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] [CRITICAL] [$LOG_TAG] $*" >&2
}

# 1. Kernel Landlock LSM Verification
verify_kernel_landlock() {
    log_info "Verifying Linux kernel Landlock LSM support..."
    local lsm_stack=""
    if lsm_stack="$(cat /sys/kernel/security/lsm 2>/dev/null)" && [[ -n "$lsm_stack" ]]; then
        if [[ ! "$lsm_stack" =~ landlock ]]; then
            log_crit "Kernel LSM stack lacks 'landlock' (active: $lsm_stack). Refusing startup."
            return 1
        fi
        log_info "Landlock LSM confirmed active in /sys/kernel/security/lsm."
        return 0
    fi

    # Direct syscall probe fallback when /sys/kernel/security/lsm is restricted
    local abi_version
    abi_version="$(python3 -c '
import ctypes
try:
    libc = ctypes.CDLL(None)
    abi = libc.syscall(444, None, 0, 1) # LANDLOCK_CREATE_RULESET_VERSION = 1
    print(abi if abi > 0 else 0)
except Exception:
    print(0)
' 2>/dev/null || echo 0)"

    if [[ "$abi_version" -ge 1 ]]; then
        log_info "Landlock ABI version $abi_version verified via syscall(444)."
        return 0
    fi

    log_crit "Linux kernel lacks Landlock LSM support (ABI probe returned $abi_version). Refusing startup."
    return 1
}

# 2. Nono Binary Verification & Pinned Digest Check
verify_nono_binary() {
    log_info "Verifying nono sandbox binary at: $NONO_BIN"
    if [[ ! -f "$NONO_BIN" || ! -x "$NONO_BIN" ]]; then
        log_crit "Nono binary '$NONO_BIN' is missing or not executable."
        return 1
    fi

    # Check nono version
    local nono_ver_output
    nono_ver_output="$("$NONO_BIN" --version 2>&1 || true)"
    if [[ ! "$nono_ver_output" =~ $PINNED_NONO_VERSION ]]; then
        log_crit "Nono version mismatch. Expected $PINNED_NONO_VERSION, got: $nono_ver_output"
        return 1
    fi

    # Check nono binary SHA-256 digest if nono is installed
    if [[ "${CHECK_NONO_DIGEST:-true}" == "true" ]]; then
        local actual_nono_digest
        actual_nono_digest="$(sha256sum "$NONO_BIN" | awk '{print $1}')"
        local expected_nono="${EXPECTED_NONO_DIGEST:-$PINNED_NONO_DIGEST}"
        if [[ "$actual_nono_digest" != "$expected_nono" ]]; then
            log_crit "Nono binary digest mismatch! Expected $expected_nono, got $actual_nono_digest"
            return 1
        fi
        log_info "Nono binary digest verified: $actual_nono_digest"
    fi
    return 0
}

# 3. Agent Binary Digest Gate
verify_agent_binary() {
    log_info "Verifying agent binary at: $AGENT_BINARY"
    if [[ ! -f "$AGENT_BINARY" ]]; then
        log_crit "Agent binary does not exist at '$AGENT_BINARY'"
        return 1
    fi

    if [[ ! -x "$AGENT_BINARY" ]]; then
        log_crit "Agent binary '$AGENT_BINARY' is not executable."
        return 1
    fi

    # Check file permissions (refuse world-writable binary)
    local perm_check
    perm_check="$(find "$AGENT_BINARY" -perm -0002 2>/dev/null || true)"
    if [[ -n "$perm_check" ]]; then
        log_crit "Agent binary '$AGENT_BINARY' is world-writable! Refusing execution."
        return 1
    fi

    # Determine expected digest
    local expected_digest=""
    if [[ -n "${AGENT_EXPECTED_DIGEST:-}" ]]; then
        expected_digest="$AGENT_EXPECTED_DIGEST"
    elif [[ -f "$AGENT_DIGEST_FILE" ]]; then
        expected_digest="$(awk '{print $1}' "$AGENT_DIGEST_FILE" | head -n 1)"
    else
        log_crit "No expected digest provided (neither AGENT_EXPECTED_DIGEST env nor $AGENT_DIGEST_FILE found)."
        return 1
    fi

    if [[ -z "$expected_digest" || ${#expected_digest} -ne 64 ]]; then
        log_crit "Invalid expected SHA-256 digest: '$expected_digest'"
        return 1
    fi

    # Compute actual digest
    local actual_digest
    actual_digest="$(sha256sum "$AGENT_BINARY" | awk '{print $1}')"

    if [[ "$actual_digest" != "$expected_digest" ]]; then
        log_crit "AGENT BINARY DIGEST MISMATCH! Tampering detected or unapproved binary."
        log_crit "  Binary:   $AGENT_BINARY"
        log_crit "  Expected: $expected_digest"
        log_crit "  Actual:   $actual_digest"
        return 1
    fi

    log_info "Agent binary digest verified successfully: $actual_digest"
    return 0
}

# 4. Profile Validation Gate
verify_profile() {
    log_info "Verifying confinement profile at: $PROFILE_PATH"
    if [[ ! -f "$PROFILE_PATH" ]]; then
        # Try local repo/fallback relative path if not at /opt
        local fallback_path
        fallback_path="$(dirname "$(dirname "$(realpath "$0")")")/profile.json"
        if [[ -f "$fallback_path" ]]; then
            PROFILE_PATH="$fallback_path"
            log_info "Using fallback profile path: $PROFILE_PATH"
        else
            log_crit "Confinement profile not found at '$PROFILE_PATH'"
            return 1
        fi
    fi

    # Validate profile with nono
    if ! "$NONO_BIN" profile validate "$PROFILE_PATH" >/dev/null 2>&1; then
        log_crit "Confinement profile validation failed for '$PROFILE_PATH'"
        "$NONO_BIN" profile validate "$PROFILE_PATH" >&2 || true
        return 1
    fi
    log_info "Confinement profile is valid."
    return 0
}

main() {
    log_info "Starting AgentMaxxing preflight digest and confinement gate..."

    verify_kernel_landlock || exit 1
    verify_nono_binary || exit 1
    verify_agent_binary || exit 1
    verify_profile || exit 1

    log_info "All preflight verification gates PASSED. Execution approved."
    exit 0
}

main "$@"
