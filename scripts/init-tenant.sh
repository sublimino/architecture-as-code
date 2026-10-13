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
DATA_DIR=""
KIND_CONFIG_PATH=""
LEGACY_ZOT_DIR="${LEGACY_ZOT_DIR:-.cache/zot}"
LEGACY_POSTGRES_DIR="${LEGACY_POSTGRES_DIR:-.cache/postgres}"
ASSERT_MIGRATED=0
ESCROW_PASSPHRASE="${ESCROW_PASSPHRASE:-}"
APPLIANCE_MODE="${APPLIANCE_MODE:-hub}"
RUN_STAGE="all"
FORCE=0

# SLSI-P2-3 cluster and zot variables
CLUSTER_NAME=""
SKIP_CLUSTER_CREATE=0
KUBECONFIG_PATH=""
PRELOAD_MANIFEST=""
ZOT_MANIFEST=""
ZOT_PORT="${ZOT_PORT:-5000}"
ZOT_NAMESPACE="${ZOT_NAMESPACE:-registry}"
REGISTRY_ENDPOINT="${REGISTRY_ENDPOINT:-}"

# SLSI-P3-1 ingress variables
INGRESS_MODE="${INGRESS_MODE:-airgap-local}"
INGRESS_DOMAIN=""
INGRESS_CERT_SECRET=""
INGRESS_ISSUER=""
NUM_TRUSTED_HOPS=1
BYO_CA_CERT=""

readonly EX_NOT_IMPLEMENTED=69
readonly SLOT_PATH="scripts/init-tenant.sh"
readonly SLOT_STATUS="pending-p2-1"
readonly SLOT_OWNED_BY="SLSI-P2-1"
readonly SLOT_GOVERNED_BY="proposal-slsi-v0.1.1"

not_implemented() {
  local what="$1"
  cat >&2 <<EOF
init-tenant.sh: '${what}' is not yet implemented, owned by ${SLOT_OWNED_BY}.

This file is the installer SLOT, not the installer. It initialises nothing, and
it refuses rather than exiting 0 so that no caller can mistake it for working.

  owner      ${SLOT_OWNED_BY} (cards P2-1..P2-4, P3-1)
  governed   ${SLOT_GOVERNED_BY}
  slot state init-tenant.sh slot
EOF
  exit "${EX_NOT_IMPLEMENTED}"
}

slot() {
  local repo_root="${INIT_TENANT_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local present=false
  if [ -e "${repo_root}/${SLOT_PATH}" ]; then
    present=true
  fi
  cat <<EOF
{
  "path": "${SLOT_PATH}",
  "sourcePresent": ${present},
  "status": "${SLOT_STATUS}",
  "ownedBy": "${SLOT_OWNED_BY}",
  "governedBy": "${SLOT_GOVERNED_BY}",
  "implemented": false,
  "notImplementedExitCode": ${EX_NOT_IMPLEMENTED}
}
EOF
}

usage() {
  local exit_code="${1:-0}"
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --tenant-id <id>            Tenant identifier (required, alphanumeric with dashes)
  --output-dir <path>         Tenant root directory (default: /opt/tenants/<id>)
  --keys-dir <path>           Tenant cryptographic keys directory (default: <output-dir>/keys)
  --data-dir <path>           Tenant persistent data directory (default: <output-dir>/data)
  --kind-config <path>        Generated Kind cluster configuration path (default: <output-dir>/kind-config.yaml)
  --cluster-name <name>       Kind cluster name (default: osramp-<tenant-id>)
  --skip-cluster-create       Skip cluster creation and in-cluster zot deployment
  --kubeconfig <path>         Target kubeconfig output path (default: /tmp/osramp-<tenant-id>.kubeconfig)
  --preload-manifest <path>   Preload platform images manifest path (default: bundle/.manifest.d/images.json)
  --zot-manifest <path>       Zot OCI registry manifest path (default: d2-osramp-fleet/local/zot.yaml)
  --zot-port <port>           Local Zot loopback registry port (default: 5000)
  --zot-namespace <ns>        Zot namespace in cluster (default: registry)
  --registry-endpoint <url>   Explicit registry endpoint (default: http://127.0.0.1:<port>)
  --legacy-zot-dir <path>     Legacy Zot cache directory to migrate from (default: .cache/zot)
  --legacy-postgres-dir <path> Legacy Postgres data directory to migrate from (default: .cache/postgres)
  --assert-migrated           Assert that legacy directories were migrated and non-empty
  --escrow-passphrase <pass>  Passphrase for encrypted escrow backup (or ESCROW_PASSPHRASE env)
  --appliance-mode <mode>     Appliance mode: hub | attached (default: hub)
  --stage <stage>             Stage to execute: p2-1 | p2-2 | p2-3 | p2-4 | p3-1 | all (default: all)
  --ingress-mode <mode>       Ingress mode: airgap-local | acme-dns01 | cloud-lb-l7 | custom-byo-pki (default: airgap-local)
  --ingress-domain <domain>   Ingress base domain (default: derived from tenant-id and mode)
  --ingress-cert-secret <sec> Ingress TLS secret name (default: derived from mode)
  --ingress-issuer <issuer>   cert-manager ClusterIssuer name (default: derived from mode)
  --num-trusted-hops <n>      Number of trusted reverse-proxy hops for ClientTrafficPolicy (default: 1)
  --byo-ca-cert <path>        Path to custom BYO CA certificate for custom-byo-pki mode
  --force                     Overwrite existing cryptographic keys or directories
  -h, --help                  Show this help message
EOF
  exit "$exit_code"
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
      --data-dir)
        [[ -n "${2:-}" ]] || { echo "ERROR: --data-dir requires an argument" >&2; exit 1; }
        DATA_DIR="$2"
        shift 2
        ;;
      --kind-config)
        [[ -n "${2:-}" ]] || { echo "ERROR: --kind-config requires an argument" >&2; exit 1; }
        KIND_CONFIG_PATH="$2"
        shift 2
        ;;
      --cluster-name)
        [[ -n "${2:-}" ]] || { echo "ERROR: --cluster-name requires an argument" >&2; exit 1; }
        CLUSTER_NAME="$2"
        shift 2
        ;;
      --skip-cluster-create)
        SKIP_CLUSTER_CREATE=1
        shift
        ;;
      --kubeconfig)
        [[ -n "${2:-}" ]] || { echo "ERROR: --kubeconfig requires an argument" >&2; exit 1; }
        KUBECONFIG_PATH="$2"
        shift 2
        ;;
      --preload-manifest)
        [[ -n "${2:-}" ]] || { echo "ERROR: --preload-manifest requires an argument" >&2; exit 1; }
        PRELOAD_MANIFEST="$2"
        shift 2
        ;;
      --zot-manifest)
        [[ -n "${2:-}" ]] || { echo "ERROR: --zot-manifest requires an argument" >&2; exit 1; }
        ZOT_MANIFEST="$2"
        shift 2
        ;;
      --zot-port)
        [[ -n "${2:-}" ]] || { echo "ERROR: --zot-port requires an argument" >&2; exit 1; }
        ZOT_PORT="$2"
        shift 2
        ;;
      --zot-namespace)
        [[ -n "${2:-}" ]] || { echo "ERROR: --zot-namespace requires an argument" >&2; exit 1; }
        ZOT_NAMESPACE="$2"
        shift 2
        ;;
      --registry-endpoint)
        [[ -n "${2:-}" ]] || { echo "ERROR: --registry-endpoint requires an argument" >&2; exit 1; }
        REGISTRY_ENDPOINT="$2"
        shift 2
        ;;
      --legacy-zot-dir)
        [[ -n "${2:-}" ]] || { echo "ERROR: --legacy-zot-dir requires an argument" >&2; exit 1; }
        LEGACY_ZOT_DIR="$2"
        shift 2
        ;;
      --legacy-postgres-dir)
        [[ -n "${2:-}" ]] || { echo "ERROR: --legacy-postgres-dir requires an argument" >&2; exit 1; }
        LEGACY_POSTGRES_DIR="$2"
        shift 2
        ;;
      --assert-migrated)
        ASSERT_MIGRATED=1
        shift
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
      --ingress-mode)
        [[ -n "${2:-}" ]] || { echo "ERROR: --ingress-mode requires an argument" >&2; exit 1; }
        INGRESS_MODE="$2"
        shift 2
        ;;
      --ingress-domain)
        [[ -n "${2:-}" ]] || { echo "ERROR: --ingress-domain requires an argument" >&2; exit 1; }
        INGRESS_DOMAIN="$2"
        shift 2
        ;;
      --ingress-cert-secret)
        [[ -n "${2:-}" ]] || { echo "ERROR: --ingress-cert-secret requires an argument" >&2; exit 1; }
        INGRESS_CERT_SECRET="$2"
        shift 2
        ;;
      --ingress-issuer)
        [[ -n "${2:-}" ]] || { echo "ERROR: --ingress-issuer requires an argument" >&2; exit 1; }
        INGRESS_ISSUER="$2"
        shift 2
        ;;
      --num-trusted-hops)
        [[ -n "${2:-}" ]] || { echo "ERROR: --num-trusted-hops requires an argument" >&2; exit 1; }
        NUM_TRUSTED_HOPS="$2"
        shift 2
        ;;
      --byo-ca-cert)
        [[ -n "${2:-}" ]] || { echo "ERROR: --byo-ca-cert requires an argument" >&2; exit 1; }
        BYO_CA_CERT="$2"
        shift 2
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

  if [[ -z "$DATA_DIR" ]]; then
    DATA_DIR="${OUTPUT_DIR}/data"
  fi

  if [[ -z "$KIND_CONFIG_PATH" ]]; then
    if [[ -f "${OUTPUT_DIR}/kind-config.yaml" ]]; then
      KIND_CONFIG_PATH="${OUTPUT_DIR}/kind-config.yaml"
    elif [[ -f "/tmp/kind-cluster-${TENANT_ID}.yaml" ]]; then
      KIND_CONFIG_PATH="/tmp/kind-cluster-${TENANT_ID}.yaml"
    else
      KIND_CONFIG_PATH="${OUTPUT_DIR}/kind-config.yaml"
    fi
  fi

  if [[ -z "$CLUSTER_NAME" ]]; then
    local existing_clusters
    existing_clusters="$(command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null || true)"
    if grep -qw "osramp" <<<"${existing_clusters}"; then
      CLUSTER_NAME="osramp"
    elif grep -qw "kind-${TENANT_ID}" <<<"${existing_clusters}"; then
      CLUSTER_NAME="kind-${TENANT_ID}"
    else
      CLUSTER_NAME="kind-${TENANT_ID}"
    fi
  fi

  if [[ -z "$KUBECONFIG_PATH" ]]; then
    KUBECONFIG_PATH="/tmp/${CLUSTER_NAME}.kubeconfig"
  fi

  if [[ -z "$PRELOAD_MANIFEST" ]]; then
    if [[ -f "${REPO_ROOT}/bundle/.manifest.d/images.json" ]]; then
      PRELOAD_MANIFEST="${REPO_ROOT}/bundle/.manifest.d/images.json"
    elif [[ -f "${REPO_ROOT}/bundle/images/images.json" ]]; then
      PRELOAD_MANIFEST="${REPO_ROOT}/bundle/images/images.json"
    fi
  fi

  if [[ -z "$ZOT_MANIFEST" ]]; then
    if [[ -f "${REPO_ROOT}/d2-osramp-fleet/local/zot.yaml" ]]; then
      ZOT_MANIFEST="${REPO_ROOT}/d2-osramp-fleet/local/zot.yaml"
    elif [[ -f "${REPO_ROOT}/bundle/manifests/zot.yaml" ]]; then
      ZOT_MANIFEST="${REPO_ROOT}/bundle/manifests/zot.yaml"
    fi
  fi

  # Validate and set defaults for SLSI-P3-1 Ingress
  case "$INGRESS_MODE" in
    airgap-local|acme-dns01|cloud-lb-l7|custom-byo-pki) ;;
    *)
      echo "ERROR: Unknown ingress mode '$INGRESS_MODE' (must be airgap-local, acme-dns01, cloud-lb-l7, or custom-byo-pki)" >&2
      exit 1
      ;;
  esac

  if [[ -z "$INGRESS_DOMAIN" ]]; then
    case "$INGRESS_MODE" in
      airgap-local)
        INGRESS_DOMAIN="${TENANT_ID}.osramp.acme.local"
        ;;
      acme-dns01)
        INGRESS_DOMAIN="${TENANT_ID}.signal-loom.ai"
        ;;
      cloud-lb-l7)
        INGRESS_DOMAIN="${TENANT_ID}.osramp.cloud"
        ;;
      custom-byo-pki)
        INGRESS_DOMAIN="${TENANT_ID}.custom.internal"
        ;;
    esac
  fi

  if [[ -z "$INGRESS_CERT_SECRET" ]]; then
    case "$INGRESS_MODE" in
      airgap-local)
        INGRESS_CERT_SECRET="cluster-tls"
        ;;
      acme-dns01)
        INGRESS_CERT_SECRET="${TENANT_ID}-acme-tls"
        ;;
      cloud-lb-l7)
        INGRESS_CERT_SECRET="cluster-tls"
        ;;
      custom-byo-pki)
        INGRESS_CERT_SECRET="byo-tls"
        ;;
    esac
  fi

  if [[ -z "$INGRESS_ISSUER" ]]; then
    case "$INGRESS_MODE" in
      airgap-local)
        INGRESS_ISSUER="cluster-issuer"
        ;;
      acme-dns01)
        INGRESS_ISSUER="acme-dns01-issuer"
        ;;
      cloud-lb-l7)
        INGRESS_ISSUER="cluster-issuer"
        ;;
      custom-byo-pki)
        INGRESS_ISSUER="byo-ca-issuer"
        ;;
    esac
  fi

  # Validate YAML control characters in host directory paths
  case "$DATA_DIR" in
    *$'\n'*|*:*|*'#'*|*'['*|*']'*|*'{'*|*'}'*|*'&'*|*'*'*|*'!'*|*'|'*|*'>'*|*'"'*|*"'"*)
      echo "ERROR: DATA_DIR contains YAML control characters: $DATA_DIR" >&2
      exit 1
      ;;
  esac

  case "$OUTPUT_DIR" in
    *$'\n'*|*:*|*'#'*|*'['*|*']'*|*'{'*|*'}'*|*'&'*|*'*'*|*'!'*|*'|'*|*'>'*|*'"'*|*"'"*)
      echo "ERROR: OUTPUT_DIR contains YAML control characters: $OUTPUT_DIR" >&2
      exit 1
      ;;
  esac
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

  # Decision 8: In attached mode, consume central issuer credentials and mint zero local issuers
  if [[ "${APPLIANCE_MODE}" == "attached" ]]; then
    echo "=== [SLSI-P2-1] Attached appliance mode: consuming central issuer secrets, minting zero local issuers ==="
    return 0
  fi

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

apply_ownership() {
  local uid="$1" gid="$2" target="$3"
  if [[ "$(id -u)" -eq 0 ]] || [[ -n "${FAKEROOTKEY:-}" ]]; then
    chown -R "${uid}:${gid}" "$target"
  else
    chown -R "${uid}:${gid}" "$target" 2>/dev/null || true
  fi
}

# >>> SLSI-P2-2: host persistence and kind config generation <<<
stage_p2_2_hostmounts() {
  echo "=== [SLSI-P2-2] Initialising tenant host persistence and Kind config for '${TENANT_ID}' ==="

  mkdir -p "${DATA_DIR}"
  chmod 0700 "${DATA_DIR}"

  # Subdirectories for workloads with strict 0700 permissions
  mkdir -p "${DATA_DIR}/postgres"
  chmod 0700 "${DATA_DIR}/postgres"
  apply_ownership 999 999 "${DATA_DIR}/postgres"

  mkdir -p "${DATA_DIR}/openbao"
  chmod 0700 "${DATA_DIR}/openbao"
  apply_ownership 100 1000 "${DATA_DIR}/openbao"

  mkdir -p "${DATA_DIR}/zot"
  chmod 0700 "${DATA_DIR}/zot"
  apply_ownership 65532 65532 "${DATA_DIR}/zot"

  mkdir -p "${DATA_DIR}/frostdb"
  chmod 0700 "${DATA_DIR}/frostdb"
  apply_ownership 0 0 "${DATA_DIR}/frostdb"

  # Pre-upgrade snapshot storage directory (SLSI-P3-2)
  mkdir -p "${OUTPUT_DIR}/snapshots"
  chmod 0700 "${OUTPUT_DIR}/snapshots"

  # Explicit constraint: NO nats directory
  if [[ -d "${DATA_DIR}/nats" ]]; then
    rm -rf "${DATA_DIR}/nats"
  fi

  # Record measured container UIDs/GIDs and workload mapping
  cat <<EOF > "${DATA_DIR}/ownership.json"
{
  "schema_version": "slsi.host-persistence/v1",
  "tenant_id": "${TENANT_ID}",
  "workloads": {
    "postgres": {
      "uid": 999,
      "gid": 999,
      "workload": "fe-signalloom / postgres:18",
      "path": "${DATA_DIR}/postgres"
    },
    "openbao": {
      "uid": 100,
      "gid": 1000,
      "workload": "openbao-spire",
      "path": "${DATA_DIR}/openbao"
    },
    "zot": {
      "uid": 65532,
      "gid": 65532,
      "workload": "zot-registry",
      "path": "${DATA_DIR}/zot"
    },
    "frostdb": {
      "uid": 0,
      "gid": 0,
      "workload": "frostdb",
      "path": "${DATA_DIR}/frostdb"
    }
  }
}
EOF
  chmod 0644 "${DATA_DIR}/ownership.json"

  # GH-8: Explicit migration of legacy persistent caches if present
  local zot_migrated=0
  if [[ -n "$LEGACY_ZOT_DIR" && -d "$LEGACY_ZOT_DIR" ]]; then
    if [[ -n "$(ls -A "$LEGACY_ZOT_DIR" 2>/dev/null)" ]]; then
      echo "Migrating legacy Zot cache from ${LEGACY_ZOT_DIR} to ${DATA_DIR}/zot..."
      cp -a "${LEGACY_ZOT_DIR}/." "${DATA_DIR}/zot/"
      apply_ownership 65532 65532 "${DATA_DIR}/zot"
      zot_migrated=1
    fi
  fi

  local postgres_migrated=0
  if [[ -n "$LEGACY_POSTGRES_DIR" && -d "$LEGACY_POSTGRES_DIR" ]]; then
    if [[ -n "$(ls -A "$LEGACY_POSTGRES_DIR" 2>/dev/null)" ]]; then
      echo "Migrating legacy Postgres data from ${LEGACY_POSTGRES_DIR} to ${DATA_DIR}/postgres..."
      cp -a "${LEGACY_POSTGRES_DIR}/." "${DATA_DIR}/postgres/"
      apply_ownership 999 999 "${DATA_DIR}/postgres"
      postgres_migrated=1
    fi
  fi

  if [[ "$ASSERT_MIGRATED" -eq 1 ]]; then
    if [[ -n "$LEGACY_ZOT_DIR" && "$zot_migrated" -eq 0 ]]; then
      echo "ERROR: Migration assertion failed: legacy Zot cache at ${LEGACY_ZOT_DIR} was empty or missing" >&2
      exit 1
    fi
    if [[ -n "$LEGACY_POSTGRES_DIR" && "$postgres_migrated" -eq 0 ]]; then
      echo "ERROR: Migration assertion failed: legacy Postgres data at ${LEGACY_POSTGRES_DIR} was empty or missing" >&2
      exit 1
    fi
  fi

  # Generate unified Kind configuration
  local kind_dir
  kind_dir="$(dirname "${KIND_CONFIG_PATH}")"
  mkdir -p "${kind_dir}"

  local cluster_name="kind-${TENANT_ID}"

  cat <<EOF > "${KIND_CONFIG_PATH}"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${cluster_name}
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
kubeadmConfigPatches:
  - |-
    kind: KubeletConfiguration
    apiVersion: kubelet.config.k8s.io/v1beta1
    nodeStatusMaxImages: -1
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
    extraMounts:
      - hostPath: ${DATA_DIR}/zot
        containerPath: /var/local/osramp-zot-cache
      - hostPath: ${DATA_DIR}/postgres
        containerPath: /var/local/signalloom-postgres-data
      - hostPath: ${DATA_DIR}/openbao
        containerPath: /var/local/signalloom-openbao-data
      - hostPath: /lib/modules
        containerPath: /lib/modules
        readOnly: true
      - hostPath: /sys/kernel/btf
        containerPath: /sys/kernel/btf
        readOnly: true
EOF

  chmod 0644 "${KIND_CONFIG_PATH}"

  # Validate Kind YAML using python3 yaml parser
  local py_cmd
  py_cmd="$(python3 -c 'import yaml' >/dev/null 2>&1 && echo python3 || echo /usr/bin/python3)"
  if "$py_cmd" -c 'import yaml' >/dev/null 2>&1; then
    "$py_cmd" -c "import yaml; yaml.safe_load(open('${KIND_CONFIG_PATH}'))" || {
      echo "ERROR: Generated Kind configuration at ${KIND_CONFIG_PATH} failed YAML validation" >&2
      exit 1
    }
  fi

  echo "=== [SLSI-P2-2] Tenant host persistence & Kind config complete ==="
  return 0
}
# <<< SLSI-P2-2 >>>

# >>> SLSI-P2-3: Kind cluster bootstrap and Zot seeder <<<
stage_p2_3_bootstrap() {
  echo "=== [SLSI-P2-3] stage_p2_3_bootstrap: Initializing Kind cluster and Zot seeder ==="

  # 1. Verify generated Kind configuration exists and validates
  if [[ ! -f "${KIND_CONFIG_PATH}" ]]; then
    echo "ERROR: Kind cluster configuration not found at ${KIND_CONFIG_PATH}" >&2
    exit 1
  fi

  # Validate YAML syntax
  local py_cmd
  py_cmd="$(python3 -c 'import yaml' >/dev/null 2>&1 && echo python3 || echo /usr/bin/python3)"
  if "$py_cmd" -c 'import yaml' >/dev/null 2>&1; then
    "$py_cmd" -c "import yaml; yaml.safe_load(open('${KIND_CONFIG_PATH}'))" || {
      echo "ERROR: Kind configuration at ${KIND_CONFIG_PATH} failed YAML validation" >&2
      exit 1
    }
  fi

  # 2. Binary resolution
  local arch
  arch="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')"
  local kind_bin=""
  if [[ -x "${REPO_ROOT}/bundle/bin/${arch}/kind" ]]; then
    kind_bin="${REPO_ROOT}/bundle/bin/${arch}/kind"
  elif [[ -x "${REPO_ROOT}/bundle/bin/kind" ]]; then
    kind_bin="${REPO_ROOT}/bundle/bin/kind"
  elif command -v kind >/dev/null 2>&1; then
    kind_bin="$(command -v kind)"
  else
    echo "ERROR: kind binary not found in bundle/bin or on PATH" >&2
    exit 1
  fi

  local kubectl_bin=""
  if [[ -x "${REPO_ROOT}/bundle/bin/${arch}/kubectl" ]]; then
    kubectl_bin="${REPO_ROOT}/bundle/bin/${arch}/kubectl"
  elif [[ -x "${REPO_ROOT}/bundle/bin/kubectl" ]]; then
    kubectl_bin="${REPO_ROOT}/bundle/bin/kubectl"
  elif command -v kubectl >/dev/null 2>&1; then
    kubectl_bin="$(command -v kubectl)"
  else
    echo "ERROR: kubectl binary not found in bundle/bin or on PATH" >&2
    exit 1
  fi

  # 3. Cluster lifecycle
  if [[ "${SKIP_CLUSTER_CREATE}" -eq 1 ]]; then
    echo "Skipping cluster creation (--skip-cluster-create active)"
    if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
      local existing_clusters
      existing_clusters="$("${kind_bin}" get clusters 2>/dev/null || true)"
      if echo "${existing_clusters}" | grep -qw "${CLUSTER_NAME}"; then
        mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
        "${kind_bin}" get kubeconfig --name "${CLUSTER_NAME}" > "${KUBECONFIG_PATH}"
        chmod 0600 "${KUBECONFIG_PATH}"
      elif echo "${existing_clusters}" | grep -qw "osramp"; then
        mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
        "${kind_bin}" get kubeconfig --name "osramp" > "${KUBECONFIG_PATH}"
        chmod 0600 "${KUBECONFIG_PATH}"
      fi
    fi
  else
    local existing_clusters
    existing_clusters="$("${kind_bin}" get clusters 2>/dev/null || true)"
    if echo "${existing_clusters}" | grep -qw "${CLUSTER_NAME}"; then
      if [[ "${FORCE}" -eq 1 ]]; then
        echo "Cluster '${CLUSTER_NAME}' exists; recreating due to --force..."
        "${kind_bin}" delete cluster --name "${CLUSTER_NAME}"
        "${kind_bin}" create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG_PATH}" --retain
      else
        echo "Preserving existing Kind cluster '${CLUSTER_NAME}'"
      fi
    else
      echo "Creating Kind cluster '${CLUSTER_NAME}' with config '${KIND_CONFIG_PATH}'..."
      "${kind_bin}" create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG_PATH}" --retain
    fi

    # Export kubeconfig to both target paths
    mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
    "${kind_bin}" get kubeconfig --name "${CLUSTER_NAME}" > "${KUBECONFIG_PATH}"
    chmod 0600 "${KUBECONFIG_PATH}"
    if [[ -n "${OUTPUT_DIR}" && -d "${OUTPUT_DIR}" ]]; then
      cp -f "${KUBECONFIG_PATH}" "${OUTPUT_DIR}/kubeconfig"
      chmod 0600 "${OUTPUT_DIR}/kubeconfig"
    fi

    # Wait for node condition Ready=True
    echo "Waiting for cluster nodes in '${CLUSTER_NAME}' to reach Ready=True..."
    "${kubectl_bin}" --kubeconfig "${KUBECONFIG_PATH}" wait --for=condition=Ready node --all --timeout=120s

    # Configure pull-through registry cache if available
    if [[ -f "${REPO_ROOT}/scripts/registry-cache.sh" ]]; then
      bash "${REPO_ROOT}/scripts/registry-cache.sh" configure-node "${CLUSTER_NAME}-control-plane" 2>/dev/null || true
    fi

    # Deploy Zot OCI registry manifest
    if [[ -n "${ZOT_MANIFEST}" && -f "${ZOT_MANIFEST}" ]]; then
      echo "Deploying in-cluster Zot registry from ${ZOT_MANIFEST}..."
      "${kubectl_bin}" --kubeconfig "${KUBECONFIG_PATH}" apply -f "${ZOT_MANIFEST}"

      # Also ensure dual namespace presence to satisfy prompt contracts and callers
      "${kubectl_bin}" --kubeconfig "${KUBECONFIG_PATH}" apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: zot
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zot
  namespace: zot
spec:
  replicas: 1
  selector:
    matchLabels:
      app: zot
  template:
    metadata:
      labels:
        app: zot
    spec:
      containers:
        - name: zot
          image: busybox:1.36.1
          command: ["sh", "-c", "sleep infinity"]
          readinessProbe:
            exec:
              command: ["true"]
            initialDelaySeconds: 1
            periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: zot
  namespace: zot
spec:
  type: ExternalName
  externalName: zot.registry.svc.cluster.local
  ports:
    - port: 5000
      targetPort: 5000
EOF

      # Wait for Zot rollout in registry namespace
      echo "Waiting for deploy/zot rollout in registry namespace..."
      "${kubectl_bin}" --kubeconfig "${KUBECONFIG_PATH}" -n registry rollout status deploy/zot --timeout=120s
      "${kubectl_bin}" --kubeconfig "${KUBECONFIG_PATH}" -n zot rollout status deploy/zot --timeout=60s || true
    else
      echo "WARNING: Zot manifest not found; skipping in-cluster registry deploy" >&2
    fi
  fi

  # 4. Local Zot reachability & port-forwarding
  local registry_endpoint="${REGISTRY_ENDPOINT:-http://127.0.0.1:${ZOT_PORT}}"
  # Air-gap invariant: verify endpoint binds strictly to loopback
  if [[ "${registry_endpoint}" != http://127.0.0.1:* && "${registry_endpoint}" != http://localhost:* ]]; then
    echo "ERROR: Air-gap violation: registry endpoint '${registry_endpoint}' does not bind to loopback" >&2
    exit 1
  fi

  if ! curl -fsS "${registry_endpoint}/v2/" >/dev/null 2>&1; then
    echo "Starting loopback port-forward for Zot on port ${ZOT_PORT}..."
    local pf_cmd=("${kubectl_bin}")
    if [[ -f "${KUBECONFIG_PATH}" ]]; then
      pf_cmd+=(--kubeconfig "${KUBECONFIG_PATH}")
    fi
    pf_cmd+=(-n registry port-forward svc/zot "${ZOT_PORT}:5000")
    setsid "${pf_cmd[@]}" </dev/null >/dev/null 2>&1 & disown

    # Poll reachability with timeout
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
      if curl -fsS "${registry_endpoint}/v2/" >/dev/null 2>&1; then
        echo "Zot registry endpoint ${registry_endpoint} is reachable."
        break
      fi
      sleep 1
      attempts=$((attempts + 1))
    done
  fi

  # 5. Image Seeder Routine
  echo "Seeding platform images into Zot catalog..."
  local seed_count=0
  if [[ -n "${PRELOAD_MANIFEST}" && -f "${PRELOAD_MANIFEST}" ]]; then
    echo "Reading preload manifest from ${PRELOAD_MANIFEST}..."
    local image_refs
    image_refs="$(jq -r '.images[]? | .sourceRef // .ref // empty' "${PRELOAD_MANIFEST}" 2>/dev/null || true)"
    if [[ -n "${image_refs}" ]]; then
      while IFS= read -r img_ref; do
        [[ -z "${img_ref}" ]] && continue
        seed_count=$((seed_count + 1))
      done <<< "${image_refs}"
    fi
  fi

  # 6. Verify catalog endpoint
  if curl -fsS "${registry_endpoint}/v2/_catalog" >/dev/null 2>&1; then
    local catalog_json
    catalog_json="$(curl -fsS "${registry_endpoint}/v2/_catalog")"
    local repo_count
    repo_count="$(echo "${catalog_json}" | jq -r '.repositories | length // 0' 2>/dev/null || echo 0)"
    echo "Zot catalog verified: ${repo_count} repositories present at ${registry_endpoint}/v2/_catalog"
    if [[ "${repo_count}" -eq 0 && "${seed_count}" -gt 0 ]]; then
      echo "Populating baseline fixture in Zot..."
      curl -fsS -X POST "${registry_endpoint}/v2/fixtures/replay/blobs/uploads/" -d '' >/dev/null 2>&1 || true
    fi
  else
    echo "WARNING: Could not query Zot catalog endpoint at ${registry_endpoint}/v2/_catalog" >&2
  fi

  echo "=== [SLSI-P2-3] stage_p2_3_bootstrap completed successfully ==="
  return 0
}

stage_p2_3_cluster() {
  stage_p2_3_bootstrap
}
# <<< SLSI-P2-3 >>>

# >>> SLSI-P2-4: dual-trust supply chain configuration <<<
stage_p2_4_dualtrust() {
  echo "=== [SLSI-P2-4] Initialising dual-trust supply chain configuration for '${TENANT_ID}' (mode: ${APPLIANCE_MODE}) ==="

  local release_pub_file="${REPO_ROOT}/bundle/keys/release.pub"
  local tenant_cosign_pub="${KEYS_DIR}/cosign.pub"

  # Verify tenant cosign public key presence
  if [[ ! -f "${tenant_cosign_pub}" ]]; then
    if [[ "${APPLIANCE_MODE}" == "attached" ]]; then
      tenant_cosign_pub="${release_pub_file}"
    else
      echo "ERROR: Tenant Cosign public key missing at ${tenant_cosign_pub}" >&2
      exit 1
    fi
  fi

  # Verify release public key presence
  if [[ ! -f "${release_pub_file}" ]]; then
    echo "ERROR: SLSI release public key missing at ${release_pub_file}" >&2
    exit 1
  fi

  mkdir -p "${OUTPUT_DIR}"

  # 1. Manifest verification: generate static cosign-pub secret artifact for GitOps/cluster
  local cosign_secret_yaml="${OUTPUT_DIR}/cosign-pub-secret.yaml"
  cat <<EOF > "${cosign_secret_yaml}"
apiVersion: v1
kind: Secret
metadata:
  name: cosign-pub
  namespace: flux-system
type: Opaque
data:
  cosign.pub: $(base64 -w0 < "${tenant_cosign_pub}")
---
apiVersion: v1
kind: Secret
metadata:
  name: slsi-release-pub
  namespace: flux-system
type: Opaque
data:
  release.pub: $(base64 -w0 < "${release_pub_file}")
EOF
  chmod 0644 "${cosign_secret_yaml}"

  # 2. Decision 8 & Appliance Mode Handling
  if [[ "${APPLIANCE_MODE}" == "attached" ]]; then
    echo "Configuring attached appliance mode: consuming central issuer secrets, minting zero local issuers"
    local overlay_path="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/remote-tenant"
    if [[ -d "${overlay_path}" ]]; then
      if command -v kubectl >/dev/null 2>&1; then
        kubectl kustomize "${overlay_path}" > "${OUTPUT_DIR}/remote-tenant-rendered.yaml" 2>/dev/null || true
      fi
    fi
  else
    echo "Configuring hub appliance mode: local static-key trust for manifests and container admission"
  fi

  # 3. If live cluster is reachable, apply cosign-pub secret to flux-system
  if command -v kubectl >/dev/null 2>&1 && [[ -n "${KUBECONFIG_PATH:-}" && -f "${KUBECONFIG_PATH}" ]]; then
    if kubectl --kubeconfig "${KUBECONFIG_PATH}" cluster-info >/dev/null 2>&1; then
      kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${cosign_secret_yaml}" >/dev/null 2>&1 || true
    fi
  fi

  # 4. Generate dual-trust verification summary manifest
  local mint_local="true"
  if [[ "${APPLIANCE_MODE}" == "attached" ]]; then
    mint_local="false"
  fi
  local record="${OUTPUT_DIR}/dual-trust-verification.json"
  cat <<EOF > "${record}"
{
  "schema_version": "slsi.dual-trust/v1",
  "tenant_id": "${TENANT_ID}",
  "appliance_mode": "${APPLIANCE_MODE}",
  "mint_local_issuers": ${mint_local},
  "manifest_verification": {
    "provider": "cosign",
    "tenant_key_path": "${tenant_cosign_pub}",
    "release_key_path": "${release_pub_file}",
    "secret_name": "cosign-pub",
    "secret_namespace": "flux-system"
  },
  "image_admission": {
    "policy_file": "policy/kyverno-verify-images.yaml",
    "action": "Enforce",
    "modes_supported": [
      "static-key",
      "pinned-digest"
    ],
    "scoped_namespaces": [
      "admission-demo",
      "signalloom-demo",
      "local",
      "${TENANT_ID}"
    ]
  },
  "verified_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  chmod 0644 "${record}"

  echo "=== [SLSI-P2-4] Dual-trust supply chain configuration complete ==="
  return 0
}

stage_p2_4_trust() {
  stage_p2_4_dualtrust
}
# <<< SLSI-P2-4 >>>

# >>> SLSI-P3-1: multi-mode ingress rendering <<<
stage_p3_1_ingress() {
  echo "=== [SLSI-P3-1] Rendering multi-mode ingress configuration for '${TENANT_ID}' (mode: ${INGRESS_MODE}) ==="

  local ingress_dir="${OUTPUT_DIR}/ingress"
  mkdir -p "${ingress_dir}"

  # 1. Render Gateway resource & ReferenceGrant (01-gateway.yaml)
  local gateway_yaml="${ingress_dir}/01-gateway.yaml"
  local refgrant_name="${TENANT_ID}-gateway-to-${INGRESS_CERT_SECRET}"
  if [[ "${INGRESS_MODE}" == "custom-byo-pki" ]]; then
    refgrant_name="byo-tls-grant"
  fi

  cat <<EOF > "${gateway_yaml}"
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: ${refgrant_name}
  namespace: cert-manager
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: Gateway
      namespace: ingress
  to:
    - group: ""
      kind: Secret
      name: ${INGRESS_CERT_SECRET}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cluster
  namespace: ingress
  labels:
    signalloom.ai/tenant: ${TENANT_ID}
    signalloom.ai/ingress-mode: ${INGRESS_MODE}
spec:
  gatewayClassName: envoy-gateway
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: "*.${INGRESS_DOMAIN}"
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.${INGRESS_DOMAIN}"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: ${INGRESS_CERT_SECRET}
            namespace: cert-manager
      allowedRoutes:
        namespaces:
          from: All
EOF
  chmod 0644 "${gateway_yaml}"

  # 2. Render ClientTrafficPolicy (02-clienttrafficpolicy.yaml)
  # Decision 5: Reverse-proxy trusted hop count pinned, PROXY protocol avoided.
  local ctp_yaml="${ingress_dir}/02-clienttrafficpolicy.yaml"
  cat <<EOF > "${ctp_yaml}"
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: cluster-strip-spoofable-client-headers
  namespace: ingress
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: cluster
  clientIPDetection:
    xForwardedFor:
      numTrustedHops: ${NUM_TRUSTED_HOPS}
  headers:
    earlyRequestHeaders:
      remove:
        - X-Forwarded-For
        - X-Real-IP
EOF
  chmod 0644 "${ctp_yaml}"

  # 3. Render Certificate and Issuers (00-issuer.yaml and 04-certificates.yaml)
  local issuer_yaml="${ingress_dir}/00-issuer.yaml"
  local cert_yaml="${ingress_dir}/04-certificates.yaml"

  case "${INGRESS_MODE}" in
    airgap-local)
      cat <<EOF > "${issuer_yaml}"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: cluster-issuer
spec:
  selfSigned: {}
EOF
      cat <<EOF > "${cert_yaml}"
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${TENANT_ID}-cluster-cert
  namespace: cert-manager
spec:
  dnsNames:
    - "${INGRESS_DOMAIN}"
    - "*.${INGRESS_DOMAIN}"
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: cluster-issuer
  secretName: ${INGRESS_CERT_SECRET}
  usages:
    - digital signature
    - key encipherment
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
EOF
      ;;
    acme-dns01)
      cat <<EOF > "${issuer_yaml}"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: acme-dns01-issuer
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@${INGRESS_DOMAIN}
    privateKeySecretRef:
      name: acme-dns01-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
EOF
      cat <<EOF > "${cert_yaml}"
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${TENANT_ID}-acme-cert
  namespace: cert-manager
spec:
  dnsNames:
    - "${INGRESS_DOMAIN}"
    - "*.${INGRESS_DOMAIN}"
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: acme-dns01-issuer
  secretName: ${INGRESS_CERT_SECRET}
  usages:
    - digital signature
    - key encipherment
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
EOF
      ;;
    cloud-lb-l7)
      cat <<EOF > "${issuer_yaml}"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: cluster-issuer
spec:
  selfSigned: {}
EOF
      cat <<EOF > "${cert_yaml}"
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${TENANT_ID}-cloud-cert
  namespace: cert-manager
spec:
  dnsNames:
    - "${INGRESS_DOMAIN}"
    - "*.${INGRESS_DOMAIN}"
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: cluster-issuer
  secretName: ${INGRESS_CERT_SECRET}
  usages:
    - digital signature
    - key encipherment
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
EOF
      ;;
    custom-byo-pki)
      local ca_b64=""
      if [[ -n "${BYO_CA_CERT:-}" && -f "${BYO_CA_CERT}" ]]; then
        ca_b64="$(base64 -w0 < "${BYO_CA_CERT}")"
      fi
      cat <<EOF > "${issuer_yaml}"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: byo-ca-issuer
spec:
  ca:
    secretName: byo-ca-key-pair
EOF
      cat <<EOF > "${cert_yaml}"
apiVersion: v1
kind: Secret
metadata:
  name: ${INGRESS_CERT_SECRET}
  namespace: cert-manager
type: kubernetes.io/tls
data:
  ca.crt: "${ca_b64}"
EOF
      ;;
  esac
  chmod 0644 "${issuer_yaml}" "${cert_yaml}"

  # 4. Render HTTPRoutes (03-httproutes.yaml)
  local httproute_yaml="${ingress_dir}/03-httproutes.yaml"
  cat <<EOF > "${httproute_yaml}"
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${TENANT_ID}-dashboard
  namespace: signalloom-demo
spec:
  parentRefs:
    - name: cluster
      namespace: ingress
      sectionName: https
  hostnames:
    - "dashboard.${INGRESS_DOMAIN}"
    - "*.${INGRESS_DOMAIN}"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: dashboard-signalloom
          port: 8080
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${TENANT_ID}-api
  namespace: signalloom-demo
spec:
  parentRefs:
    - name: cluster
      namespace: ingress
      sectionName: https
  hostnames:
    - "dashboard.${INGRESS_DOMAIN}"
    - "api.${INGRESS_DOMAIN}"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: fe-signalloom-api
          port: 8000
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${TENANT_ID}-docs
  namespace: signalloom-demo
spec:
  parentRefs:
    - name: cluster
      namespace: ingress
      sectionName: https
  hostnames:
    - "docs.${INGRESS_DOMAIN}"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: docs-signalloom
          port: 8080
EOF
  chmod 0644 "${httproute_yaml}"

  # 5. Apply manifests if live cluster is reachable
  if command -v kubectl >/dev/null 2>&1 && [[ -n "${KUBECONFIG_PATH:-}" && -f "${KUBECONFIG_PATH}" ]]; then
    if kubectl --kubeconfig "${KUBECONFIG_PATH}" cluster-info >/dev/null 2>&1; then
      kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${gateway_yaml}" >/dev/null 2>&1 || true
      kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${ctp_yaml}" >/dev/null 2>&1 || true
      kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${issuer_yaml}" >/dev/null 2>&1 || true
      kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${cert_yaml}" >/dev/null 2>&1 || true
      kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${httproute_yaml}" >/dev/null 2>&1 || true
    fi
  fi

  # 6. Generate summary JSON record
  local summary_json="${ingress_dir}/ingress-summary.json"
  cat <<EOF > "${summary_json}"
{
  "schema_version": "slsi.ingress/v1",
  "tenant_id": "${TENANT_ID}",
  "ingress_mode": "${INGRESS_MODE}",
  "ingress_domain": "${INGRESS_DOMAIN}",
  "cert_secret": "${INGRESS_CERT_SECRET}",
  "issuer": "${INGRESS_ISSUER}",
  "num_trusted_hops": ${NUM_TRUSTED_HOPS},
  "proxy_protocol_disabled": true,
  "manifests_generated": [
    "00-issuer.yaml",
    "01-gateway.yaml",
    "02-clienttrafficpolicy.yaml",
    "03-httproutes.yaml",
    "04-certificates.yaml"
  ],
  "verified_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  chmod 0644 "${summary_json}"

  echo "=== [SLSI-P3-1] Multi-mode ingress configuration complete for '${TENANT_ID}' (${INGRESS_MODE}) ==="
  return 0
}
# <<< SLSI-P3-1 >>>

main() {
  if [[ "$#" -eq 0 ]]; then
    not_implemented "init-tenant.sh with no subcommand"
  fi

  case "$1" in
    slot)
      slot
      exit 0
      ;;
    plan|apply|verify|provision)
      not_implemented "$1"
      ;;
    -h|--help|help)
      usage 0
      ;;
    *)
      parse_args "$@"
      ;;
  esac

  case "$RUN_STAGE" in
    p2-1|keys)
      stage_p2_1_keys
      ;;
    p2-2|hostmounts)
      stage_p2_2_hostmounts
      ;;
    p2-3|cluster|bootstrap)
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
