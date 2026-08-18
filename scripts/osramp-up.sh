#!/usr/bin/env bash
# osramp-up.sh — Restore OSRAMP application to the cluster.
# Restores the ResourceSet inputs and triggers reconciliation.
# Requires: images already loaded into kind (run `make images` if needed).

set -eo pipefail

NAMESPACES=("frontend" "backend")
RESOURCESET="apps"
FLUX_NS="flux-system"
INPUTS_FILE="/tmp/.osramp-resourceset-inputs.json"

# Default inputs if saved file doesn't exist
DEFAULT_INPUTS='[{"artifactSubjectGitRef":"local","artifactSubjectWorkflow":"local","environment":"local","tag":"latest","tenant":"frontend"},{"artifactSubjectGitRef":"local","artifactSubjectWorkflow":"local","environment":"local","tag":"latest","tenant":"backend"}]'

# Check if already up
ALL_EXIST=true
for ns in "${NAMESPACES[@]}"; do
  if ! kubectl get namespace "${ns}" &>/dev/null; then
    ALL_EXIST=false
    break
  fi
done

if [ "${ALL_EXIST}" = true ]; then
  echo "==> All OSRAMP namespaces already exist."
  for ns in "${NAMESPACES[@]}"; do
    echo "    --- ${ns} ---"
    kubectl get pods -n "${ns}" --no-headers 2>/dev/null | head -5
  done
  echo ""
  echo "    To force re-deploy, run osramp-down.sh first."
  exit 0
fi

# Determine inputs to restore
if [ -f "${INPUTS_FILE}" ] && [ -s "${INPUTS_FILE}" ]; then
  INPUTS=$(cat "${INPUTS_FILE}")
  echo "==> Restoring ResourceSet inputs from saved file..."
else
  INPUTS="${DEFAULT_INPUTS}"
  echo "==> Using default ResourceSet inputs (no saved file found)..."
fi

# The ResourceSet ships with fluxcd.controlplane.io/reconcile: disabled, which
# the controller checks (obj.IsDisabled()) and returns on BEFORE building. That
# is the operator's actual off-switch; `inputs: []` is not one, because an empty
# input list makes BuildResourceSet render once against a nil map and stall on
# the first `<< inputs.tenant >>`. Patching inputs without clearing this first
# is a silent no-op — the patch succeeds and the controller still skips.
echo "==> Enabling reconciliation for ResourceSet '${RESOURCESET}'..."
kubectl annotate resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
  fluxcd.controlplane.io/reconcile-

echo "==> Patching ResourceSet '${RESOURCESET}' with inputs..."
kubectl patch resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
  --type merge -p "{\"spec\":{\"inputs\":${INPUTS}}}"

echo "==> Triggering immediate reconciliation..."
kubectl annotate resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite

echo "==> Waiting for namespaces to appear..."
for ns in "${NAMESPACES[@]}"; do
  for i in $(seq 1 60); do
    if kubectl get namespace "${ns}" &>/dev/null; then
      echo "    ${ns}: created (${i}s)."
      break
    fi
    sleep 1
  done
  if ! kubectl get namespace "${ns}" &>/dev/null; then
    echo "WARNING: ${ns} did not appear within 60s."
  fi
done

echo "==> Waiting for Kustomizations to become Ready..."
for ns in "${NAMESPACES[@]}"; do
  for i in $(seq 1 18); do
    READY_COUNT=$(kubectl get kustomizations -n "${ns}" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || true)
    TOTAL=$(kubectl get kustomizations -n "${ns}" --no-headers 2>/dev/null | wc -l || true)
    if [ "${READY_COUNT}" -eq "${TOTAL}" ] && [ "${TOTAL}" -gt 0 ]; then
      echo "    ${ns}: Kustomizations Ready."
      break
    fi
    sleep 10
  done
done

echo "==> Pod status:"
for ns in "${NAMESPACES[@]}"; do
  echo "    --- ${ns} ---"
  kubectl get pods -n "${ns}" --no-headers 2>/dev/null | \
    awk '{printf "    %-55s %-7s %s\n", $1, $3, $4}'
done

echo ""
echo "==> OSRAMP restored (frontend + backend)."
echo "    If pods show ErrImageNeverPull, run: make images"
