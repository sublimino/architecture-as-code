#!/usr/bin/env bash
# Push a host-built image through the local Zot port-forward.
#
# Reuses an already-open forward on the local port when one is reachable (e.g.
# when invoked under with-zot-portforward.sh for a batch build), and otherwise
# opens a short-lived forward just for this push. Env overrides: ZOT_LOCAL_PORT
# (5001), ZOT_NAMESPACE (registry), ZOT_SERVICE (svc/zot).
set -euo pipefail

SOURCE_IMAGE="${1:?source image required}"
DESTINATION="${2:?destination image required}"

LOCAL_PORT="${ZOT_LOCAL_PORT:-5001}"
NAMESPACE="${ZOT_NAMESPACE:-registry}"
SERVICE="${ZOT_SERVICE:-svc/zot}"
REGISTRY_URL="http://localhost:${LOCAL_PORT}/v2/"

IMAGE_TAR="$(mktemp)"

if curl -fsS "${REGISTRY_URL}" >/dev/null 2>&1; then
  # Reuse an existing forward — do not start or tear one down.
  trap 'rm -f "${IMAGE_TAR}"' EXIT
else
  kubectl -n "${NAMESPACE}" port-forward "${SERVICE}" "${LOCAL_PORT}:5000" >/dev/null 2>&1 &
  PORT_FORWARD_PID=$!
  trap 'kill "${PORT_FORWARD_PID}" 2>/dev/null || true; rm -f "${IMAGE_TAR}"' EXIT
  for _ in $(seq 1 60); do
    curl -fsS "${REGISTRY_URL}" >/dev/null 2>&1 && break
    sleep 0.5
  done
  curl -fsS "${REGISTRY_URL}" >/dev/null
fi

docker save -o "${IMAGE_TAR}" "${SOURCE_IMAGE}"
crane push --insecure "${IMAGE_TAR}" "${DESTINATION}"
