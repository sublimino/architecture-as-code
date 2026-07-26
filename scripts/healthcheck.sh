#!/usr/bin/env bash
# healthcheck.sh — verify the shared cluster foundation before any demo starts.
set -euo pipefail

timeout="${CLUSTER_HEALTHCHECK_TIMEOUT:-5m}"

echo "checking Kubernetes API server"
kubectl get nodes >/dev/null || {
  echo "cluster healthcheck failed: Kubernetes API server is unreachable" >&2
  exit 1
}

echo "checking Kubernetes node readiness"
if ! kubectl wait --for=condition=Ready nodes --all --timeout="$timeout"; then
  echo "cluster healthcheck failed: one or more Kubernetes nodes are not Ready" >&2
  exit 1
fi

resources=(
  Kustomization/flux-system/flux-system
  ResourceSet/flux-system/policies
  ResourceSet/flux-system/infra
)

for resource in "${resources[@]}"; do
  kind="${resource%%/*}"
  remainder="${resource#*/}"
  namespace="${remainder%%/*}"
  name="${remainder##*/}"
  echo "checking ${kind}/${name} in ${namespace}"
  kubectl -n "$namespace" wait "${kind}/${name}" --for=condition=ready --timeout="$timeout"
done

echo "cluster foundation is healthy; no demos are running"
