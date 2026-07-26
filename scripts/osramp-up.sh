#!/usr/bin/env bash
# osramp-up.sh — Restore OSRAMP application to the cluster.
# Triggers the Flux ResourceSet to reconcile, recreating frontend + backend
# namespaces and all OSRAMP workloads.
# Requires: images already loaded into kind (run `make images` if needed).

set -euo pipefail

NAMESPACES=("frontend" "backend")
RESOURCESET="apps"
FLUX_NS="flux-system"

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
  echo "    To force re-reconciliation, run osramp-down.sh first."
  exit 0
fi

echo "==> Triggering ResourceSet '${RESOURCESET}' reconciliation..."
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

echo "==> Waiting for Kustomizations to reconcile..."
for ns in "${NAMESPACES[@]}"; do
  for i in $(seq 1 12); do
    READY=$(kubectl get kustomizations -n "${ns}" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if echo "${READY}" | grep -qv "False" && [ -n "${READY}" ]; then
      echo "    ${ns}: Kustomizations Ready."
      break
    fi
    sleep 10
  done
done

echo "==> Recreating workload signing key (not Flux-managed)..."
make -C "$(git rev-parse --show-toplevel)" workload-key 2>/dev/null || \
  echo "    WARNING: could not run 'make workload-key' — osramp-multipurpose will fail without it."

echo "==> Pod status:"
for ns in "${NAMESPACES[@]}"; do
  echo "    --- ${ns} ---"
  kubectl get pods -n "${ns}" --no-headers 2>/dev/null | \
    awk '{printf "    %-55s %-7s %s\n", $1, $3, $4}'
done

echo ""
echo "==> OSRAMP restored (frontend + backend)."
echo "    If pods show ErrImageNeverPull, run: make images"
