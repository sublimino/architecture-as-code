#!/usr/bin/env bash
# ==============================================================================
# scripts/init-tenant.sh — Signal Loom Appliance Self-Initialisation Pipeline
# ==============================================================================
# Pipeline entry point for zero-touch air-gapped tenant appliance bootstrap.
#
# Stages:
#   SLSI-P2-1: Zero-state cryptographic bootstrap (keys + encrypted escrow)
#   SLSI-P2-2: Host persistence directories & Kind cluster configuration
#   SLSI-P2-3: Kind cluster creation & in-cluster Zot registry image preload
#   SLSI-P2-4: Dual-trust supply chain admission policy & OCIRepository verification
#   SLSI-P3-1: Multi-mode Envoy Gateway ingress configuration
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Global defaults
TENANT_ID="${TENANT_ID:-}"
OUTPUT_DIR=""
KEYS_DIR=""
ESCROW_PASSPHRASE="${ESCROW_PASSPHRASE:-}"
APPLIANCE_MODE="${APPLIANCE_MODE:-hub}"
RUN_STAGE="all"
FORCE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --tenant-id <id>            Tenant identifier (required, alphanumeric with dashes)
  --output-dir <path>         Tenant root directory (default: /opt/tenants/<id>)
  --keys-dir <path>           Tenant cryptographic keys directory (default: <output-dir>/keys)
  --escrow-passphrase <pass>  Passphrase for encrypted escrow backup (or ESCROW_PASSPHRASE env)
  --appliance-mode <mode>     Appliance mode: hub | attached (default: hub)
  --stage <stage>             Stage to execute: p2-1 | p2-2 | p2-3 | p2-4 | p3-1 | all (default: all)
  --force                     Overwrite existing cryptographic keys or directories
  -h, --help                  Show this help message
EOF
  exit 1
}

# Parse CLI options
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tenant-id)
        [[ -n "${2:-}" ]] || { echo "ERROR: --tenant-id requires an argument" >&2; exit 1; }
        TENANT_ID="$2"
        shift 2
        ;;
      --output-dir)
        [[ -n "${2:-}" ]] || { echo "ERROR: --output-dir requires an argument" >&2; exit 1; }
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --keys-dir)
        [[ -n "${2:-}" ]] || { echo "ERROR: --keys-dir requires an argument" >&2; exit 1; }
        KEYS_DIR="$2"
        shift 2
        ;;
      --escrow-passphrase)
        [[ -n "${2:-}" ]] || { echo "ERROR: --escrow-passphrase requires an argument" >&2; exit 1; }
        ESCROW_PASSPHRASE="$2"
        shift 2
        ;;
      --appliance-mode)
        [[ -n "${2:-}" ]] || { echo "ERROR: --appliance-mode requires an argument" >&2; exit 1; }
        APPLIANCE_MODE="$2"
        shift 2
        ;;
      --stage)
        [[ -n "${2:-}" ]] || { echo "ERROR: --stage requires an argument" >&2; exit 1; }
        RUN_STAGE="$2"
        shift 2
        ;;
      --force)
        FORCE=1
        shift
        ;;
      -h|--help)
        usage
        ;;
      *)
        echo "ERROR: Unknown option: $1" >&2
        usage
        ;;
    esac
  done

  if [[ -z "$TENANT_ID" ]]; then
    echo "ERROR: --tenant-id is required" >&2
    exit 1
  fi

  if [[ ! "$TENANT_ID" =~ ^[a-zA-Z0-9][-a-zA-Z0-9_]*$ ]]; then
    echo "ERROR: Invalid tenant-id '$TENANT_ID' (must be alphanumeric with dashes/underscores)" >&2
    exit 1
  fi

  if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="/opt/tenants/${TENANT_ID}"
  fi

  if [[ -z "$KEYS_DIR" ]]; then
    KEYS_DIR="${OUTPUT_DIR}/keys"
  fi
}

# Resolve cryptographic helper binaries
resolve_binaries() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64) arch="amd64" ;;
    aarch64) arch="arm64" ;;
  esac

  # Cosign resolution
  if [[ -x "${REPO_ROOT}/bundle/bin/${arch}/cosign" ]]; then
    COSIGN_BIN="${REPO_ROOT}/bundle/bin/${arch}/cosign"
  elif command -v cosign >/dev/null 2>&1; then
    COSIGN_BIN="$(command -v cosign)"
  else
    echo "ERROR: cosign binary not found in bundle/bin/${arch}/ or on PATH" >&2
    exit 1
  fi

  # ed25519-keygen resolution
  ED25519_KEYGEN_BIN=""
  if [[ -x "${REPO_ROOT}/bundle/bin/${arch}/ed25519-keygen" ]]; then
    ED25519_KEYGEN_BIN="${REPO_ROOT}/bundle/bin/${arch}/ed25519-keygen"
  elif command -v ed25519-keygen >/dev/null 2>&1; then
    ED25519_KEYGEN_BIN="$(command -v ed25519-keygen)"
  fi
}

# >>> SLSI-P2-1: zero-state key minting and encrypted escrow <<<
stage_p2_1_keys() {
  echo "=== [SLSI-P2-1] Initialising tenant cryptographic keypairs for '${TENANT_ID}' ==="

  # Guard: enforce umask for secret material
  umask 077

  mkdir -p "${KEYS_DIR}"
  chmod 0700 "${KEYS_DIR}"

  # Export KEYS_DIR to activate repository keys isolation seam without touching scripts/lib/keys.sh (GH-6)
  export KEYS_DIR="${KEYS_DIR}"

  # Check pre-existing keys
  if [[ -f "${KEYS_DIR}/cosign.key" ]]; then
    if [[ "$FORCE" -eq 0 ]]; then
      echo "ERROR: Cryptographic keys already exist at ${KEYS_DIR}. Pass --force to overwrite." >&2
      exit 1
    else
      rm -f "${KEYS_DIR}/cosign.key" "${KEYS_DIR}/cosign.pub" \
            "${KEYS_DIR}/witness.pem" "${KEYS_DIR}/witness-pub.pem" "${KEYS_DIR}/witness-key.pem" \
            "${KEYS_DIR}/orbit-approval.pem" "${KEYS_DIR}/orbit-approval-pub.pem" "${KEYS_DIR}/orbit-approval.key" \
            "${KEYS_DIR}/signing-config.json" "${KEYS_DIR}/segment-signing-policy.json"
    fi
  fi

  resolve_binaries

  echo "Minting Cosign ECDSA P-256 keypair..."
  (
    cd "${KEYS_DIR}"
    COSIGN_PASSWORD="" "$COSIGN_BIN" generate-key-pair >/dev/null 2>&1
  )
  chmod 0600 "${KEYS_DIR}/cosign.key"
  chmod 0644 "${KEYS_DIR}/cosign.pub"

  echo "Minting Witness Ed25519 keypair..."
  if [[ -n "$ED25519_KEYGEN_BIN" ]]; then
    "$ED25519_KEYGEN_BIN" generate --key "${KEYS_DIR}/witness.pem" --pub "${KEYS_DIR}/witness-pub.pem"
  else
    openssl genpkey -algorithm ed25519 -out "${KEYS_DIR}/witness.pem" >/dev/null 2>&1
    openssl pkey -pubin -in "${KEYS_DIR}/witness.pem" -pubout -out "${KEYS_DIR}/witness-pub.pem" >/dev/null 2>&1
  fi
  chmod 0600 "${KEYS_DIR}/witness.pem"
  chmod 0644 "${KEYS_DIR}/witness-pub.pem"
  # Provide compatibility link for witness-key.pem
  cp -p "${KEYS_DIR}/witness.pem" "${KEYS_DIR}/witness-key.pem"
  chmod 0600 "${KEYS_DIR}/witness-key.pem"

  echo "Minting Orbit approval Ed25519 keypair..."
  if [[ -n "$ED25519_KEYGEN_BIN" ]]; then
    "$ED25519_KEYGEN_BIN" generate --key "${KEYS_DIR}/orbit-approval.pem" --pub "${KEYS_DIR}/orbit-approval-pub.pem"
  else
    openssl genpkey -algorithm ed25519 -out "${KEYS_DIR}/orbit-approval.pem" >/dev/null 2>&1
    openssl pkey -pubin -in "${KEYS_DIR}/orbit-approval.pem" -pubout -out "${KEYS_DIR}/orbit-approval-pub.pem" >/dev/null 2>&1
  fi
  chmod 0600 "${KEYS_DIR}/orbit-approval.pem"
  chmod 0644 "${KEYS_DIR}/orbit-approval-pub.pem"
  # Provide compatibility link for orbit-approval.key
  cp -p "${KEYS_DIR}/orbit-approval.pem" "${KEYS_DIR}/orbit-approval.key"
  chmod 0600 "${KEYS_DIR}/orbit-approval.key"

  echo "Generating signing configuration..."
  cat <<'EOF' > "${KEYS_DIR}/signing-config.json"
{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json", "rekorTlogConfig":{}, "tsaConfig":{}}
EOF
  chmod 0644 "${KEYS_DIR}/signing-config.json"

  echo "Generating segment signing policy..."
  local witness_key_id
  if [[ -n "$ED25519_KEYGEN_BIN" ]]; then
    witness_key_id="$("$ED25519_KEYGEN_BIN" key-id --pub "${KEYS_DIR}/witness-pub.pem")"
  else
    witness_key_id="$(openssl pkey -pubin -in "${KEYS_DIR}/witness-pub.pem" -outform DER | sha256sum | awk '{print $1}')"
  fi

  if [[ -z "$witness_key_id" ]]; then
    echo "ERROR: Failed to derive key ID from ${KEYS_DIR}/witness-pub.pem" >&2
    exit 1
  fi

  cat <<EOF > "${KEYS_DIR}/segment-signing-policy.json"
{
  "schema_version": "signalloom.segment.signing-policy/v1",
  "expected_key_ids": [
    "${witness_key_id}"
  ]
}
EOF
  chmod 0644 "${KEYS_DIR}/segment-signing-policy.json"

  echo "Generating encrypted escrow backup bundle..."
  if [[ -z "$ESCROW_PASSPHRASE" ]]; then
    echo "ERROR: Escrow passphrase is required for key backup. Set --escrow-passphrase or ESCROW_PASSPHRASE." >&2
    exit 1
  fi

  local escrow_bundle="${OUTPUT_DIR}/${TENANT_ID}-escrow.tar.enc"
  mkdir -p "${OUTPUT_DIR}"
  (
    cd "${KEYS_DIR}"
    tar -cf - cosign.key witness.pem witness-key.pem orbit-approval.pem orbit-approval.key | \
      openssl enc -aes-256-cbc -pbkdf2 -salt -out "${escrow_bundle}" -pass "pass:${ESCROW_PASSPHRASE}"
  )
  chmod 0600 "${escrow_bundle}"
  # Also store a copy inside keys dir for local retention
  if [[ "${KEYS_DIR}" != "${OUTPUT_DIR}" ]]; then
    cp -p "${escrow_bundle}" "${KEYS_DIR}/${TENANT_ID}-escrow.tar.enc"
    chmod 0600 "${KEYS_DIR}/${TENANT_ID}-escrow.tar.enc"
  fi

  echo "=== [SLSI-P2-1] Tenant cryptographic bootstrap complete ==="
  return 0
}
# <<< SLSI-P2-1 >>>

# >>> SLSI-P2-2: host persistence and kind config generation <<<
stage_p2_2_hostmounts() {
  echo "=== [SLSI-P2-2] stage_p2_2_hostmounts: stubbed, owned by SLSI-P2-2 ==="
  return 0
}
# <<< SLSI-P2-2 >>>

# >>> SLSI-P2-3: kind boot and zot seeding <<<
stage_p2_3_cluster() {
  echo "=== [SLSI-P2-3] stage_p2_3_cluster: stubbed, owned by SLSI-P2-3 ==="
  return 0
}
# <<< SLSI-P2-3 >>>

# >>> SLSI-P2-4: dual-trust verification wiring <<<
stage_p2_4_trust() {
  echo "=== [SLSI-P2-4] stage_p2_4_trust: stubbed, owned by SLSI-P2-4 ==="
  return 0
}
# <<< SLSI-P2-4 >>>

# >>> SLSI-P3-1: multi-mode ingress rendering <<<
stage_p3_1_ingress() {
  echo "=== [SLSI-P3-1] stage_p3_1_ingress: stubbed, owned by SLSI-P3-1 ==="
  return 0
}
# <<< SLSI-P3-1 >>>

main() {
  parse_args "$@"

  case "$RUN_STAGE" in
    p2-1|keys)
      stage_p2_1_keys
      ;;
    p2-2|hostmounts)
      stage_p2_2_hostmounts
      ;;
    p2-3|cluster)
      stage_p2_3_cluster
      ;;
    p2-4|trust)
      stage_p2_4_trust
      ;;
    p3-1|ingress)
      stage_p3_1_ingress
      ;;
    all)
      stage_p2_1_keys
      stage_p2_2_hostmounts
      stage_p2_3_cluster
      stage_p2_4_trust
      stage_p3_1_ingress
      ;;
    *)
      echo "ERROR: Unknown stage '$RUN_STAGE'" >&2
      exit 1
      ;;
  esac
}

main "$@"
