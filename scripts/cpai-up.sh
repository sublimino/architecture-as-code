#!/usr/bin/env bash
# cpai-up.sh — Deploy the CPAI runtime proxy into its own namespace.
# Idempotent: safe to re-run. Does not touch other demos.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Applying CPAI runtime manifests to cpai namespace"
kubectl apply -k d2-cpai/apps/cpai-runtime/local

# The image tag is :latest with imagePullPolicy IfNotPresent, so a re-apply
# after `make cpai-images` produces no manifest diff and would keep serving the
# stale pod. Force a fresh pod so a freshly built+signed image is always picked
# up. Harmless on first deploy (the new deployment simply gets one more revision).
echo "==> Forcing rollout so a freshly built image is picked up"
kubectl -n cpai rollout restart deployment/cpai-runtime

echo "==> Waiting for cpai-runtime deployment to roll out"
kubectl -n cpai rollout status deployment/cpai-runtime --timeout=120s

echo "==> CPAI runtime is up in namespace 'cpai'"
kubectl -n cpai get pods -l app.kubernetes.io/name=cpai-runtime
