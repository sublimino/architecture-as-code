#!/usr/bin/env bash
# osramp-down.sh — Remove OSRAMP application from the cluster.
# Removes Flux Kustomization finalizers and deletes frontend + backend namespaces.
# Infrastructure (inf-bao, inf-signalloom, monitoring, etc.) is left intact.

set -euo pipefail

NAMESPACES=("frontend" "backend")
RESOURCESET="apps"
FLUX_NS="flux-system"

for ns in "${NAMESPACES[@]}"; do
  if ! kubectl get namespace "${ns}" &>/dev/null; then
    echo "==> Namespace '${ns}' does not exist — skipping."
    continue
  fi

  echo "==> Suspending and removing finalizers from Kustomizations in ${ns}..."
  for ks in $(kubectl get kustomizations -n "${ns}" -o name 2>/dev/null); do
    kubectl patch "${ks}" -n "${ns}" --type merge \
      -p '{"spec":{"suspend":true},"metadata":{"finalizers":null}}' 2>/dev/null || true
  done

  echo "==> Deleting namespace '${ns}'..."
  kubectl delete namespace "${ns}" --timeout=30s 2>/dev/null || true
done

# Wait for namespace termination
sleep 3
for ns in "${NAMESPACES[@]}"; do
  if kubectl get namespace "${ns}" &>/dev/null; then
    echo "    ${ns}: still terminating — clearing finalizers..."
    kubectl get kustomizations -n "${ns}" -o name 2>/dev/null | \
      xargs -I {} kubectl patch {} -n "${ns}" --type merge \
      -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    for i in $(seq 1 10); do
      kubectl get namespace "${ns}" &>/dev/null || break
      sleep 2
    done
  fi
done

echo "==> Verifying removal..."
for ns in "${NAMESPACES[@]}"; do
  if kubectl get namespace "${ns}" &>/dev/null; then
    echo "    WARNING: ${ns} still Terminating (resources gone, finalizer stuck)"
  else
    echo "    ${ns}: fully deleted."
  fi
done

echo "==> OSRAMP removed from cluster (frontend + backend)."
echo "    Run osramp-up.sh to restore (triggers ResourceSet '${RESOURCESET}' reconciliation)."
