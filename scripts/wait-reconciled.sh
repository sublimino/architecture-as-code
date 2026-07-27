#!/usr/bin/env bash
# Wait for the shared cluster foundation: fleet sync, policy/infra ResourceSets,
# and shared infrastructure Kustomizations. Demo resources are deliberately
# excluded and start only through their explicit lifecycle targets.
set -euo pipefail

resources=(
  Kustomization/flux-system/flux-system
  ResourceSet/flux-system/policies
  ResourceSet/flux-system/infra
  Kustomization/cert-manager/infra-controllers
  Kustomization/cert-manager/infra-configs
  Kustomization/ingress/infra-controllers
  Kustomization/ingress/infra-configs
  Kustomization/monitoring/infra-controllers
  Kustomization/monitoring/infra-configs
  Kustomization/trivy-system/infra-controllers
  Kustomization/trivy-system/infra-configs
)

wait_for_resource() {
  local resource="$1"
  local kind namespace name

  kind=$(echo "$resource" | cut -d/ -f1)
  namespace=$(echo "$resource" | cut -d/ -f2)
  name=$(echo "$resource" | cut -d/ -f3)

  echo "waiting for ${kind}/${name} in ${namespace}"
  kubectl -n "$namespace" wait "$kind/$name" --for=condition=ready --timeout=10m
}

resource_pids=()
resource_names=()
failed_resources=()

for resource in "${resources[@]}"; do
  wait_for_resource "$resource" &
  resource_pids+=("$!")
  resource_names+=("$resource")
done

for i in "${!resource_pids[@]}"; do
  # Guard `wait` so errexit does not stop us before we can report every failed
  # or timed-out resource in the batch.
  if ! wait "${resource_pids[$i]}"; then
    echo "FATAL: reconciliation wait failed for ${resource_names[$i]}" >&2
    failed_resources+=("${resource_names[$i]}")
  fi
done

if ((${#failed_resources[@]} > 0)); then
  echo "FATAL: reconciliation did not converge for resource(s): ${failed_resources[*]}" >&2
  exit 1
fi

echo "reconciliation converged"
