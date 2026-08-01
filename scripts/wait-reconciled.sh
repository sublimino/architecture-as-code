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
)

if [[ "${ENABLE_OBSERVABILITY:-true}" == "true" ]]; then
  resources+=(
    Kustomization/monitoring/infra-controllers
    Kustomization/monitoring/infra-configs
    Kustomization/trivy-system/infra-controllers
    Kustomization/trivy-system/infra-configs
  )
fi

wait_for_resource() {
  local resource="$1"
  local kind namespace name

  kind=$(echo "$resource" | cut -d/ -f1)
  namespace=$(echo "$resource" | cut -d/ -f2)
  name=$(echo "$resource" | cut -d/ -f3)

  echo "waiting for ${kind}/${name} in ${namespace}"

  # Flux creates these objects (and their namespaces) asynchronously after the
  # foundation is applied. `kubectl wait` errors immediately on a missing
  # object/namespace, so on a cold cluster it loses a race against Flux and
  # fails the gate even though reconciliation would converge (e.g. trivy-system
  # depends on the ServiceMonitor CRD that the monitoring stack installs later).
  # Poll for existence first, then wait for readiness, within one bounded budget.
  local deadline=$(( SECONDS + 720 ))
  until kubectl -n "$namespace" get "$kind/$name" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      echo "FATAL: ${kind}/${name} in ${namespace} never appeared" >&2
      return 1
    fi
    sleep 5
  done

  local remaining=$(( deadline - SECONDS ))
  (( remaining < 30 )) && remaining=30
  kubectl -n "$namespace" wait "$kind/$name" --for=condition=ready --timeout="${remaining}s"
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
