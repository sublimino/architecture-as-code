#!/usr/bin/env bash
# osramp-down.sh — Remove OSRAMP application from the cluster.
# Patches the ResourceSet inputs to empty (stops Flux recreating), then
# clears all finalizers and deletes frontend + backend namespaces.
# Infrastructure (inf-bao, inf-signalloom, monitoring, etc.) is left intact.

set -eo pipefail

NAMESPACES=("frontend" "backend")
RESOURCESET="apps"
FLUX_NS="flux-system"

echo "==> Saving ResourceSet inputs for later restoration..."
kubectl get resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
  -o jsonpath='{.spec.inputs}' > /tmp/.osramp-resourceset-inputs.json 2>/dev/null

echo "==> Patching ResourceSet '${RESOURCESET}' to empty inputs (stops recreation)..."
kubectl patch resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
  --type merge -p '{"spec":{"inputs":[]}}'
kubectl annotate resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite

sleep 2

for ns in "${NAMESPACES[@]}"; do
  if ! kubectl get namespace "${ns}" &>/dev/null; then
    echo "==> Namespace '${ns}' does not exist — skipping."
    continue
  fi

  echo "==> Clearing all finalizers in ${ns}..."
  for kind in kustomizations helmreleases helmcharts helmrepositories ocirepositories; do
    kubectl get "${kind}" -n "${ns}" -o name 2>/dev/null | \
      xargs -I {} kubectl patch {} -n "${ns}" --type json \
      -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
  done
  kubectl get pvc -n "${ns}" -o name 2>/dev/null | \
    xargs -I {} kubectl patch {} -n "${ns}" --type json \
    -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true

  echo "==> Deleting namespace '${ns}'..."
  kubectl delete namespace "${ns}" --timeout=30s 2>/dev/null || true
done

# Wait for termination
sleep 3
for ns in "${NAMESPACES[@]}"; do
  for i in $(seq 1 15); do
    kubectl get namespace "${ns}" &>/dev/null || break
    # Clear stragglers on retries
    if [ "$i" -eq 5 ] || [ "$i" -eq 10 ]; then
      for kind in kustomizations helmreleases helmcharts helmrepositories ocirepositories; do
        kubectl get "${kind}" -n "${ns}" -o name 2>/dev/null | \
          xargs -I {} kubectl patch {} -n "${ns}" --type json \
          -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
      done
      kubectl get pvc -n "${ns}" -o name 2>/dev/null | \
        xargs -I {} kubectl patch {} -n "${ns}" --type json \
        -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    fi
    sleep 2
  done
done

echo "==> Verifying removal..."
for ns in "${NAMESPACES[@]}"; do
  if kubectl get namespace "${ns}" &>/dev/null; then
    echo "    ${ns}: still Terminating — force-finalizing via API..."
    kubectl get ns "${ns}" -o json 2>/dev/null | \
      python3 -c "import sys,json; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; json.dump(ns,sys.stdout)" | \
      kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - &>/dev/null || true
    sleep 3
  fi
  if kubectl get namespace "${ns}" &>/dev/null; then
    echo "    WARNING: ${ns} still Terminating after force-finalize."
  else
    echo "    ${ns}: fully deleted."
  fi
done

echo "==> OSRAMP removed from cluster (frontend + backend)."
echo "    ResourceSet inputs saved to /tmp/.osramp-resourceset-inputs.json"
echo "    Run osramp-up.sh to restore."
