#!/usr/bin/env bash
# olly-up.sh — Restore Olly Sentinel replica to the cluster.
# Triggers the Flux ResourceSet to reconcile, which recreates the namespace
# and all Olly workloads.
# Requires: images already loaded into kind (run `make images` if needed).

set -euo pipefail

NAMESPACE="olly-replica"
RESOURCESET="olly"
FLUX_NS="flux-system"

if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "==> Namespace '${NAMESPACE}' already exists."
  echo "    Checking if workloads are running..."
  kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | head -10
  echo ""
  echo "    To force re-reconciliation, delete the namespace first with olly-down.sh"
  exit 0
fi

echo "==> Triggering ResourceSet '${RESOURCESET}' reconciliation..."
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

echo "==> Waiting for Kustomizations to reconcile..."
for i in $(seq 1 12); do
  READY=$(kubectl get kustomizations -n "${NAMESPACE}" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if echo "${READY}" | grep -qv "False" && [ -n "${READY}" ]; then
    echo "    Kustomizations Ready."
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
