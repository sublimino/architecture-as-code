#!/usr/bin/env bash
# ==============================================================================
# scripts/export-diagnostics.sh — Signal Loom Local Audit Bundler & Telemetry Streamer
# ==============================================================================
# Packages appliance audit trails, Witness attestations, OpenBao logs, and FrostDB
# segments into an encrypted archive:
#   /opt/tenants/<id>/audit/diagnostics-<timestamp>.tar.enc
#
# Egress policy:
# - Default: ZERO outbound network egress. Air-gapped appliance isolation.
# - Optional: Transmits to Signal Loom Hub only if both --hub-endpoint and
#   --hub-token are explicitly provided.
# ==============================================================================

set -euo pipefail

# Global defaults
TENANT_ID="${TENANT_ID:-}"
OUTPUT_DIR=""
AUDIT_DIR=""
PASSPHRASE="${DIAGNOSTICS_PASSPHRASE:-}"
HUB_ENDPOINT=""
HUB_TOKEN=""
INCLUDE_LOGS=0
DRY_RUN=0
FORCE=0
STAGING_DIR=""

usage() {
  local exit_code="${1:-0}"
  cat <<EOF
Usage: $(basename "$0") [options]

Local audit bundler and telemetry streamer for Signal Loom design partner appliance.

Options:
  --tenant-id <id>            Tenant identifier (required, alphanumeric with dashes)
  --output-dir <path>         Tenant root directory (default: /opt/tenants/<id>)
  --audit-dir <path>          Output audit directory (default: <output-dir>/audit)
  --passphrase <pass>         Passphrase for AES-256-CBC PBKDF2 encryption (or DIAGNOSTICS_PASSPHRASE env)
  --hub-endpoint <url>        Optional Signal Loom Hub streaming endpoint
  --hub-token <token>         Optional authentication bearer token for Hub streaming
  --include-logs              Include pod logs if Kubernetes cluster is accessible
  --dry-run                   Validate audit sources without writing encrypted archive
  --force                     Overwrite existing diagnostic bundle if timestamp collision
  -h, --help                  Show this help message
EOF
  exit "$exit_code"
}

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
      --audit-dir)
        [[ -n "${2:-}" ]] || { echo "ERROR: --audit-dir requires an argument" >&2; exit 1; }
        AUDIT_DIR="$2"
        shift 2
        ;;
      --passphrase)
        [[ -n "${2:-}" ]] || { echo "ERROR: --passphrase requires an argument" >&2; exit 1; }
        PASSPHRASE="$2"
        shift 2
        ;;
      --hub-endpoint)
        [[ -n "${2:-}" ]] || { echo "ERROR: --hub-endpoint requires an argument" >&2; exit 1; }
        HUB_ENDPOINT="$2"
        shift 2
        ;;
      --hub-token)
        [[ -n "${2:-}" ]] || { echo "ERROR: --hub-token requires an argument" >&2; exit 1; }
        HUB_TOKEN="$2"
        shift 2
        ;;
      --include-logs)
        INCLUDE_LOGS=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      -h|--help)
        usage 0
        ;;
      *)
        echo "ERROR: Unknown option: $1" >&2
        usage 1
        ;;
    esac
  done

  if [[ -z "$TENANT_ID" ]]; then
    echo "ERROR: --tenant-id is required" >&2
    exit 1
  fi

  if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="/opt/tenants/${TENANT_ID}"
  fi

  if [[ -z "$AUDIT_DIR" ]]; then
    AUDIT_DIR="${OUTPUT_DIR}/audit"
  fi

  if [[ -z "$PASSPHRASE" ]]; then
    # Generate deterministic tenant fallback passphrase if none provided
    PASSPHRASE="slsi-diagnostics-${TENANT_ID}"
  fi
}

main() {
  parse_args "$@"

  local timestamp
  timestamp="$(date -u +%Y%m%d%H%M%S)"

  echo "=== [SLSI-P3-3] Packaging Diagnostics for Tenant '${TENANT_ID}' ==="

  mkdir -p "${AUDIT_DIR}"
  chmod 0700 "${AUDIT_DIR}"

  STAGING_DIR="$(mktemp -d "/tmp/slsi-diag-${TENANT_ID}-${timestamp}-XXXXXX")"
  chmod 0700 "${STAGING_DIR}"

  # Register cleanup trap
  trap 'if [[ -n "${STAGING_DIR:-}" && -d "${STAGING_DIR}" ]]; then rm -rf "${STAGING_DIR}" "${STAGING_DIR}.tar.gz"; fi' EXIT

  echo "=== [1/4] Collecting audit trails and evidence sources ==="
  local collected_sources=0

  # 1. Witness attestations
  if [[ -d "${AUDIT_DIR}/witness" ]]; then
    echo "Gathering Witness attestations..."
    mkdir -p "${STAGING_DIR}/witness"
    cp -a "${AUDIT_DIR}/witness/"* "${STAGING_DIR}/witness/" 2>/dev/null || true
    collected_sources=$((collected_sources + 1))
  fi

  # 2. OpenBao audit logs
  if [[ -d "${OUTPUT_DIR}/data/openbao" ]]; then
    echo "Gathering OpenBao audit logs..."
    mkdir -p "${STAGING_DIR}/openbao"
    if [[ -f "${OUTPUT_DIR}/data/openbao/audit.log" ]]; then
      cp -a "${OUTPUT_DIR}/data/openbao/audit.log" "${STAGING_DIR}/openbao/audit.log"
      collected_sources=$((collected_sources + 1))
    fi
  fi

  # 3. FrostDB segments
  if [[ -d "${OUTPUT_DIR}/data/frostdb" ]]; then
    echo "Gathering FrostDB telemetry segments..."
    mkdir -p "${STAGING_DIR}/frostdb"
    cp -a "${OUTPUT_DIR}/data/frostdb/"* "${STAGING_DIR}/frostdb/" 2>/dev/null || true
    collected_sources=$((collected_sources + 1))
  fi

  # 4. Ingress summaries & configurations
  if [[ -d "${OUTPUT_DIR}/ingress" ]]; then
    echo "Gathering Ingress configurations..."
    mkdir -p "${STAGING_DIR}/ingress"
    cp -a "${OUTPUT_DIR}/ingress/"* "${STAGING_DIR}/ingress/" 2>/dev/null || true
    collected_sources=$((collected_sources + 1))
  fi

  # 5. Snapshots history
  if [[ -d "${OUTPUT_DIR}/snapshots" ]]; then
    echo "Gathering Day-2 snapshot manifests..."
    mkdir -p "${STAGING_DIR}/snapshots"
    find "${OUTPUT_DIR}/snapshots" -name "*.json" -exec cp --parents {} "${STAGING_DIR}/" \; 2>/dev/null || true
  fi

  # 6. Pod logs if requested
  if [[ "$INCLUDE_LOGS" -eq 1 ]] && command -v kubectl >/dev/null 2>&1; then
    echo "Capturing Kubernetes pod logs..."
    mkdir -p "${STAGING_DIR}/logs"
    kubectl get pods -A --no-headers 2>/dev/null > "${STAGING_DIR}/logs/pods-overview.txt" || true
  fi

  echo "=== [2/4] Generating cryptographic manifest and checksums ==="
  local manifest_file="${STAGING_DIR}/diagnostics-manifest.json"
  cat <<EOF > "${manifest_file}"
{
  "schema_version": "slsi.diagnostics/v1",
  "tenant_id": "${TENANT_ID}",
  "timestamp": "${timestamp}",
  "collected_sources_count": ${collected_sources},
  "egress_mode": "$(if [[ -n "$HUB_ENDPOINT" ]]; then echo "hub_streaming"; else echo "airgap_local"; fi)",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  chmod 0600 "${manifest_file}"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry-run mode: skipping packaging and encryption."
    echo "=== Diagnostics preflight validation successful (${collected_sources} sources collected) ==="
    return 0
  fi

  echo "=== [3/4] Packaging and Encrypting (AES-256-CBC PBKDF2) ==="
  local tarball_plain="${STAGING_DIR}.tar.gz"
  tar -C "${STAGING_DIR}" -czf "${tarball_plain}" .

  local encrypted_archive="${AUDIT_DIR}/diagnostics-${timestamp}.tar.enc"
  if [[ -f "${encrypted_archive}" && "$FORCE" -ne 1 ]]; then
    echo "ERROR: Target archive already exists: ${encrypted_archive}" >&2
    exit 1
  fi

  openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
    -in "${tarball_plain}" \
    -out "${encrypted_archive}" \
    -pass "pass:${PASSPHRASE}"

  chmod 0600 "${encrypted_archive}"

  # Emit sha256 checksum
  local checksum_file="${AUDIT_DIR}/diagnostics-${timestamp}.sha256"
  sha256sum "${encrypted_archive}" > "${checksum_file}"
  chmod 0600 "${checksum_file}"

  echo "Encrypted diagnostics bundle written to: ${encrypted_archive} (mode 0600)"
  echo "Checksum recorded at: ${checksum_file}"

  echo "=== [4/4] Network Egress Policy Enforcement ==="
  if [[ -n "$HUB_ENDPOINT" && -n "$HUB_TOKEN" ]]; then
    echo "Transmitting diagnostics bundle to Signal Loom Hub: ${HUB_ENDPOINT}..."
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -X POST "${HUB_ENDPOINT}/api/v1/telemetry/diagnostics" \
        -H "Authorization: Bearer ${HUB_TOKEN}" \
        -H "Content-Type: application/octet-stream" \
        -H "X-Tenant-ID: ${TENANT_ID}" \
        --data-binary "@${encrypted_archive}" \
        --connect-timeout 10 \
        --max-time 60 >/dev/null 2>&1 || {
          echo "WARNING: Hub transmission failed; local encrypted bundle remains securely retained." >&2
        }
    fi
  else
    echo "Default air-gap egress policy: ZERO network packets transmitted."
    echo "Outbound streaming is disabled. Encrypted archive is stored locally."
  fi

  echo "=== [SLSI-P3-3] Diagnostics Packaging Complete for '${TENANT_ID}' ==="
  return 0
}

main "$@"
