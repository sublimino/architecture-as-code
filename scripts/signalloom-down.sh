#!/usr/bin/env bash
# signalloom-down.sh — Durably remove Signal Loom frontend from the cluster.
# Empties the signalloom-apps ResourceSet inputs, clears all finalizers,
# deletes fe-signalloom namespace. Shared Bao infra is untouched.

set -eo pipefail

NAMESPACE="fe-signalloom"
RESOURCESET="signalloom-apps"
FLUX_NS="flux-system"

if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "==> Namespace '${NAMESPACE}' does not exist — already removed."
  exit 0
fi

echo "==> Saving ResourceSet inputs for later restoration..."
kubectl get resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
  -o jsonpath='{.spec.inputs}' > /tmp/.signalloom-apps-resourceset-inputs.json 2>/dev/null

echo "==> Patching ResourceSet '${RESOURCESET}' to empty inputs (stops recreation)..."
kubectl patch resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
  --type merge -p '{"spec":{"inputs":[]}}'
kubectl annotate resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite

sleep 2

echo "==> Clearing all Flux-managed finalizers in ${NAMESPACE}..."
for kind in kustomizations helmreleases helmcharts helmrepositories ocirepositories; do
  kubectl get "${kind}" -n "${NAMESPACE}" -o name 2>/dev/null | \
    xargs -I {} kubectl patch {} -n "${NAMESPACE}" --type json \
    -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
done

echo "==> Clearing PVC finalizers..."
kubectl get pvc -n "${NAMESPACE}" -o name 2>/dev/null | \
  xargs -I {} kubectl patch {} -n "${NAMESPACE}" --type json \
  -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true

echo "==> Deleting namespace '${NAMESPACE}'..."
kubectl delete namespace "${NAMESPACE}" --timeout=30s 2>/dev/null || true

for i in $(seq 1 15); do
  kubectl get namespace "${NAMESPACE}" &>/dev/null || break
  if [ "$i" -eq 5 ] || [ "$i" -eq 10 ]; then
    for kind in kustomizations helmreleases helmcharts helmrepositories ocirepositories; do
      kubectl get "${kind}" -n "${NAMESPACE}" -o name 2>/dev/null | \
        xargs -I {} kubectl patch {} -n "${NAMESPACE}" --type json \
        -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    done
    kubectl get pvc -n "${NAMESPACE}" -o name 2>/dev/null | \
      xargs -I {} kubectl patch {} -n "${NAMESPACE}" --type json \
      -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
  fi
  sleep 2
done

if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "    Force-finalizing namespace via API..."
  kubectl get ns "${NAMESPACE}" -o json 2>/dev/null | \
    python3 -c "import sys,json; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; json.dump(ns,sys.stdout)" | \
    kubectl replace --raw "/api/v1/namespaces/${NAMESPACE}/finalize" -f - &>/dev/null || true
  sleep 3
fi

if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "WARNING: namespace ${NAMESPACE} still Terminating after force-finalize."
else
  echo "==> Namespace '${NAMESPACE}' fully deleted."
fi

echo "==> Signal Loom removed from cluster (shared Bao infra untouched)."
echo "    Run signalloom-up.sh to restore."
