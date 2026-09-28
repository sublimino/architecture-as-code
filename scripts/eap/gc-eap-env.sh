#!/usr/bin/env bash
# ==============================================================================
# scripts/eap/gc-eap-env.sh
# Signal Loom EAP Post-Teardown Garbage Collector & Residual Detector
#
# Inspects tailnet nodes, serve entries, namespaces, and Dex client origins
# for a specified tenant hash. Removes any residual resources found, and
# EXITS NON-ZERO (1) if any residual resources existed before GC ran, so that
# teardown pipeline defects remain visible rather than laundered.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS_CLI="$SCRIPT_DIR/tailscale-eap-env.sh"
MOCK_DIR="${TAILSCALE_MOCK_DIR:-/tmp/tailscale-eap-mock}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <company-name> | --hash <customer-hash>

Options:
  --hash <8-hex>      Inspect and GC by 8-character customer hash directly
  -h, --help          Show this message
EOF
}

COMPANY=""
HASH=""

if [[ $# -eq 0 ]]; then
  echo "ERROR: Missing required argument" >&2
  usage >&2
  exit 2
fi

if [[ "$1" == "--hash" ]]; then
  HASH="${2:-}"
  if [[ ! "$HASH" =~ ^[0-9a-f]{8}$ ]]; then
    echo "ERROR: --hash requires an 8-char lowercase hex hash, got '$HASH'" >&2
    exit 2
  fi
elif [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
else
  COMPANY="$1"
  HASH="$("$TS_CLI" hash "$COMPANY")"
fi

HOST="sl-eap-${HASH}"
NAMESPACE="eap-${HASH}"

echo "==> Inspecting residual resources for tenant '$HASH' ($HOST)..."

RESIDUALS=()

# 1. Check Mock directory residuals
if [[ -d "$MOCK_DIR/$HOST" ]]; then
  RESIDUALS+=("mock_dir:$MOCK_DIR/$HOST")
fi

# 2. Check Tailscale node / serve entries in live mode
if [[ "${TAILSCALE_MOCK:-0}" != "1" ]] && command -v tailscale >/dev/null 2>&1; then
  if tailscale status --json 2>/dev/null | grep -q "$HOST"; then
    RESIDUALS+=("tailscale_node:$HOST")
  fi
  if tailscale serve status --json 2>/dev/null | grep -q "$HOST"; then
    RESIDUALS+=("tailscale_serve:$HOST")
  fi
fi

# 3. Check Kubernetes resources if kubectl is available
if command -v kubectl >/dev/null 2>&1; then
  if kubectl get httproute "$HOST" -n fe-signalloom >/dev/null 2>&1; then
    RESIDUALS+=("k8s_httproute:fe-signalloom/$HOST")
  fi
  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    RESIDUALS+=("k8s_namespace:$NAMESPACE")
  fi
fi

RESIDUAL_COUNT="${#RESIDUALS[@]}"

if [[ "$RESIDUAL_COUNT" -gt 0 ]]; then
  echo "WARNING: Residual resources detected before GC for $HASH:" >&2
  for r in "${RESIDUALS[@]}"; do
    echo "  - $r" >&2
  done

  echo "==> Cleaning up residual resources..."
  # Clean mock state if present
  if [[ -d "$MOCK_DIR/$HOST" ]]; then
    rm -rf "$MOCK_DIR/$HOST"
  fi

  # Evict tailscale if live
  if [[ "${TAILSCALE_MOCK:-0}" != "1" ]] && command -v tailscale >/dev/null 2>&1; then
    "$TS_CLI" teardown --hash "$HASH" >/dev/null 2>&1 || true
  fi

  # Delete k8s objects if present
  if command -v kubectl >/dev/null 2>&1; then
    kubectl delete httproute "$HOST" -n fe-signalloom --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi

  echo "RESIDUAL_FOUND: $RESIDUAL_COUNT residual item(s) cleaned up for $HASH"
  exit 1
else
  echo "NO_RESIDUE: No residual resources found for eap-$HASH."
  exit 0
fi
