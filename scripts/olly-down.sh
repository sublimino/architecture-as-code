#!/usr/bin/env bash
# olly-down.sh — Remove Olly Sentinel replica from the cluster.
# Patches the ResourceSet inputs to empty (stops Flux recreating), then
# clears all finalizers and deletes the namespace.

set -eo pipefail

NAMESPACE="olly-replica"
RESOURCESET="olly"
FLUX_NS="flux-system"

if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "==> Namespace '${NAMESPACE}' does not exist — already removed."
  exit 0
fi

echo "==> Saving ResourceSet inputs for later restoration..."
kubectl get resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
  -o jsonpath='{.spec.inputs}' > /tmp/.olly-resourceset-inputs.json 2>/dev/null

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

echo "==> Clearing CRD instance finalizers (Elasticsearch, Redpanda)..."
for crd in elasticsearches.elasticsearch.k8s.elastic.co redpandas.cluster.redpanda.com; do
  kubectl get "${crd}" -n "${NAMESPACE}" -o name 2>/dev/null | \
    xargs -I {} kubectl patch {} -n "${NAMESPACE}" --type merge \
    -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
done

echo "==> Clearing PVC finalizers..."
kubectl get pvc -n "${NAMESPACE}" -o name 2>/dev/null | \
  xargs -I {} kubectl patch {} -n "${NAMESPACE}" --type json \
  -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true

echo "==> Deleting namespace '${NAMESPACE}'..."
kubectl delete namespace "${NAMESPACE}" --timeout=30s 2>/dev/null || true

# Wait for termination
for i in $(seq 1 20); do
  kubectl get namespace "${NAMESPACE}" &>/dev/null || break
  # Clear any stragglers
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
  echo "    Namespace still Terminating — force-finalizing via API..."
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

echo "==> Olly removed from cluster."
echo "    ResourceSet inputs saved to /tmp/.olly-resourceset-inputs.json"
echo "    Run olly-up.sh to restore."
