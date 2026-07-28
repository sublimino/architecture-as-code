#!/usr/bin/env bash
# cpai-up.sh — Deploy the CPAI runtime proxy into its own namespace.
# Idempotent: safe to re-run. Does not touch other demos.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Applying CPAI runtime manifests to cpai namespace"
kubectl apply -k d2-cpai/apps/cpai-runtime/local

echo "==> Waiting for cpai-runtime deployment to roll out"
kubectl -n cpai rollout status deployment/cpai-runtime --timeout=120s

echo "==> CPAI runtime is up in namespace 'cpai'"
kubectl -n cpai get pods -l app.kubernetes.io/name=cpai-runtime
