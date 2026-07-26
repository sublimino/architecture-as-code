#!/usr/bin/env bash
# olly-down.sh — Remove Olly Sentinel replica from the cluster.
# Removes Flux Kustomization finalizers to allow clean namespace deletion,
# then deletes the olly-replica namespace entirely.
# The ResourceSet in flux-system is left intact (it will recreate on resume).

set -euo pipefail

NAMESPACE="olly-replica"
RESOURCESET="olly"
FLUX_NS="flux-system"

if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "==> Namespace '${NAMESPACE}' does not exist — already removed."
  exit 0
fi

echo "==> Suspending and removing finalizers from Kustomizations in ${NAMESPACE}..."
for ks in $(kubectl get kustomizations -n "${NAMESPACE}" -o name 2>/dev/null); do
  kubectl patch "${ks}" -n "${NAMESPACE}" --type merge \
    -p '{"spec":{"suspend":true},"metadata":{"finalizers":null}}' 2>/dev/null || true
done

echo "==> Removing finalizers from CRD instances (Elasticsearch, Redpanda)..."
for crd in elasticsearches.elasticsearch.k8s.elastic.co redpandas.cluster.redpanda.com; do
  kubectl get "${crd}" -n "${NAMESPACE}" -o name 2>/dev/null | \
    xargs -I {} kubectl patch {} -n "${NAMESPACE}" --type merge \
    -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
done

echo "==> Deleting namespace '${NAMESPACE}'..."
kubectl delete namespace "${NAMESPACE}" --timeout=30s 2>/dev/null || true

# If namespace is stuck Terminating, clear any remaining finalizers
sleep 3
if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "    Namespace still terminating — clearing remaining finalizers..."
  kubectl get kustomizations -n "${NAMESPACE}" -o name 2>/dev/null | \
    xargs -I {} kubectl patch {} -n "${NAMESPACE}" --type merge \
    -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  for crd in elasticsearches.elasticsearch.k8s.elastic.co redpandas.cluster.redpanda.com; do
    kubectl get "${crd}" -n "${NAMESPACE}" -o name 2>/dev/null | \
      xargs -I {} kubectl patch {} -n "${NAMESPACE}" --type merge \
      -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done
  for i in $(seq 1 15); do
    kubectl get namespace "${NAMESPACE}" &>/dev/null || break
    sleep 2
  done
fi

if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "WARNING: namespace ${NAMESPACE} still in Terminating state."
  echo "         Resources are gone but namespace finalizer is stuck."
  echo "         Functionally, Olly is removed from the cluster."
else
  echo "==> Namespace '${NAMESPACE}' fully deleted."
fi

echo "==> Olly removed from cluster."
echo "    Run olly-up.sh to restore (triggers ResourceSet '${RESOURCESET}' reconciliation)."
