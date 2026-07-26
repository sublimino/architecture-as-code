#!/usr/bin/env bash
# signalloom-up.sh — Durably restore Signal Loom frontend to the cluster.
# Restores the signalloom-apps ResourceSet inputs and triggers reconciliation.

set -eo pipefail

NAMESPACE="fe-signalloom"
RESOURCESET="signalloom-apps"
FLUX_NS="flux-system"
INPUTS_FILE="/tmp/.signalloom-apps-resourceset-inputs.json"

DEFAULT_INPUTS='[{"artifactSubjectGitRef":"local","artifactSubjectWorkflow":"local","component":"fe-signalloom","environment":"local","tag":"latest","tenant":"fe-signalloom"}]'

if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "==> Namespace '${NAMESPACE}' already exists."
  kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | \
    awk '{printf "    %-50s %s\n", $1, $3}' | head -10
  echo ""
  echo "    To force re-deploy, run signalloom-down.sh first."
  exit 0
fi

if [ -f "${INPUTS_FILE}" ] && [ -s "${INPUTS_FILE}" ]; then
  INPUTS=$(cat "${INPUTS_FILE}")
  echo "==> Restoring ResourceSet inputs from saved file..."
else
  INPUTS="${DEFAULT_INPUTS}"
  echo "==> Using default ResourceSet inputs (no saved file found)..."
fi

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
echo "==> Signal Loom restored."
