#!/usr/bin/env bash
# olly-up.sh — Restore Olly Sentinel replica to the cluster.
# Restores the ResourceSet inputs and triggers reconciliation.
# Requires: images already loaded into kind (run `make images` if needed).

set -eo pipefail

NAMESPACE="olly-replica"
RESOURCESET="olly"
FLUX_NS="flux-system"
INPUTS_FILE="/tmp/.olly-resourceset-inputs.json"

# Default inputs if saved file doesn't exist
DEFAULT_INPUTS='[{"artifactSubjectGitRef":"local","artifactSubjectWorkflow":"local","environment":"local","tag":"latest","tenant":"olly-replica"}]'

if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "==> Namespace '${NAMESPACE}' already exists."
  kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | \
    awk '{printf "    %-50s %s\n", $1, $3}' | head -10
  echo ""
  echo "    To force re-deploy, run olly-down.sh first."
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

# The ResourceSet ships disabled via fluxcd.controlplane.io/reconcile, which the
# controller checks (obj.IsDisabled()) and returns on BEFORE building. Patching
# inputs without clearing it first is a silent no-op. See the comment on the
# same line in scripts/osramp-up.sh and the header of tenants/base/olly.yaml.
echo "==> Enabling reconciliation for ResourceSet '${RESOURCESET}'..."
kubectl annotate resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
  fluxcd.controlplane.io/reconcile-

echo "==> Patching ResourceSet '${RESOURCESET}' with inputs..."
kubectl patch resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
  --type merge -p "{\"spec\":{\"inputs\":${INPUTS}}}"

echo "==> Triggering immediate reconciliation..."
kubectl annotate resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite

echo "==> Waiting for namespace '${NAMESPACE}' to appear..."
for i in $(seq 1 60); do
  if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
    echo "    Namespace created (${i}s)."
    break
  fi
  sleep 1
done

if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "ERROR: namespace did not appear within 60s."
  echo "       Check: kubectl get resourceset ${RESOURCESET} -n ${FLUX_NS}"
  exit 1
fi

echo "==> Waiting for Kustomizations to become Ready..."
for i in $(seq 1 18); do
  READY_COUNT=$(kubectl get kustomizations -n "${NAMESPACE}" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || true)
  TOTAL=$(kubectl get kustomizations -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l || true)
  if [ "${READY_COUNT}" -eq "${TOTAL}" ] && [ "${TOTAL}" -gt 0 ]; then
    echo "    All ${TOTAL} Kustomization(s) Ready."
    break
  fi
  sleep 10
done

echo "==> Pod status in ${NAMESPACE}:"
kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | \
  awk '{printf "    %-55s %-7s %s\n", $1, $3, $4}'

echo ""
echo "==> Olly restored."
echo "    If pods show ErrImageNeverPull, run: make images"
