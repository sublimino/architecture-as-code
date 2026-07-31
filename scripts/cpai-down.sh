#!/usr/bin/env bash
# cpai-down.sh — Remove the CPAI runtime demo namespace.
# Does not touch other demos or shared infrastructure.
set -euo pipefail

echo "==> Removing cpai namespace"
kubectl delete namespace cpai --ignore-not-found --wait=false
echo "==> CPAI demo removed"
