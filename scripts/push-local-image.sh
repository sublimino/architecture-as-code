#!/usr/bin/env bash
# Push a host-built image through the local Zot port-forward.
set -euo pipefail

SOURCE_IMAGE="${1:?source image required}"
DESTINATION="${2:?destination image required}"

kubectl -n registry port-forward svc/zot 5001:5000 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
IMAGE_TAR=$(mktemp)
trap 'kill "${PORT_FORWARD_PID}" 2>/dev/null || true; rm -f "${IMAGE_TAR}"' EXIT

for _ in $(seq 1 60); do
  curl -fsS http://localhost:5001/v2/ >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS http://localhost:5001/v2/ >/dev/null

docker save -o "${IMAGE_TAR}" "${SOURCE_IMAGE}"
crane push --insecure "${IMAGE_TAR}" "${DESTINATION}"
