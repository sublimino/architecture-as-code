#!/usr/bin/env bash
# olly-up.sh — Restore Olly Sentinel replica to the cluster.
# Restores the ResourceSet inputs and triggers reconciliation.
# Requires: images already loaded into kind (run `make images` if needed).

set -eo pipefail

# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"

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
wait_k8s_exists namespace "${NAMESPACE}" 120

echo "==> Waiting for Kustomizations to become Ready..."
wait_flux_ready kustomization olly-controllers -n "${NAMESPACE}" 300
wait_flux_ready kustomization olly-configs -n "${NAMESPACE}" 300

echo "==> Pod status in ${NAMESPACE}:"
kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | \
  awk '{printf "    %-55s %-7s %s\n", $1, $3, $4}'

echo ""
echo "==> Olly restored."
echo "    If pods show ErrImageNeverPull, run: make images"
