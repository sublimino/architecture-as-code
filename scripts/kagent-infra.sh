#!/usr/bin/env bash
# scripts/kagent-infra.sh — Kagent v0.9.9 Infrastructure Lifecycle (Demo 5)
# Manages Kagent CRDs, controller, bundled PostgreSQL, tool-server, and UI.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/wait.sh
source "${REPO_ROOT}/scripts/lib/wait.sh"

KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.kind/kubeconfig}"
if [ -f "${KUBECONFIG_PATH}" ]; then
  export KUBECONFIG="${KUBECONFIG_PATH}"
fi

NS="kagent"
ACTION="${1:-up}"

case "${ACTION}" in
  up)
    echo "==> Deploying Kagent CRDs..."
    kubectl apply -k "${REPO_ROOT}/d2-signalloom/infra/kagent/crds"
    wait_k8s_exists crd agents.kagent.dev 30
    wait_k8s_exists crd modelconfigs.kagent.dev 30
    wait_k8s_exists crd mcpservers.kagent.dev 30

    echo "==> Deploying Kagent Control Plane to namespace '${NS}'..."
    kubectl apply -k "${REPO_ROOT}/d2-signalloom/infra/kagent/local"
    wait_k8s_exists namespace "${NS}" 30

    echo "==> Waiting for Kagent control plane components..."
    wait_rollout kagent-postgres -n "${NS}" 120
    wait_rollout kagent-tool-server -n "${NS}" 120
    wait_rollout kagent-ui -n "${NS}" 120
    wait_rollout kagent-controller -n "${NS}" 120

    echo "==> Kagent infrastructure is healthy and ready!"
    kubectl get pods -n "${NS}" -o wide
    ;;

  down)
    echo "==> Removing Kagent Control Plane from namespace '${NS}'..."
    if kubectl get namespace "${NS}" >/dev/null 2>&1; then
      kubectl delete namespace "${NS}" --timeout=60s || true
    fi

    echo "==> Removing Kagent CRDs..."
    kubectl delete -k "${REPO_ROOT}/d2-signalloom/infra/kagent/crds" --ignore-not-found --timeout=30s || true
    echo "==> Kagent infrastructure removed."
    ;;

  status)
    echo "=== Kagent Infrastructure Status ==="
    echo "Namespace: ${NS}"
    if kubectl get namespace "${NS}" >/dev/null 2>&1; then
      kubectl get pods -n "${NS}"
      echo ""
      echo "=== CRDs ==="
      kubectl get crds | grep -E 'kagent|mcp' || true
    else
      echo "Namespace '${NS}' does not exist (not deployed)."
    fi
    ;;

  *)
    echo "Usage: $0 [up|down|status]" >&2
    exit 1
    ;;
esac
