#!/usr/bin/env bash
# Publish a purl ingestion task to the OSRAMP queue. The purl listener picks
# it up, checks the cache, and queues an npm install and SBOM generation.
set -euo pipefail

# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"

PURL="${1:-pkg:npm/lodash@4.17.21}"
TASK_ID="purl-$(date +%s)"

NATS_BOX=$(kubectl get pods --all-namespaces -o wide | awk '/nats-box/{print "--namespace " $1 " " $2}' | head -n1)
test -n "${NATS_BOX}" || { echo "nats-box pod not found; is the backend running?"; exit 1; }
# The pod exists but may still be ContainerCreating — `kubectl exec` fails until
# it is Ready. Wait before publishing.
NATS_NS=$(awk '{print $2}' <<<"${NATS_BOX}"); NATS_POD=$(awk '{print $3}' <<<"${NATS_BOX}")
wait_k8s_ready pod "${NATS_POD}" -n "${NATS_NS}" 120

MESSAGE=$(jq -nc --arg id "${TASK_ID}" --arg purl "${PURL}" '{
  id: $id,
  type: "purl_check",
  payload: { purl: $purl },
  correlation_id: "console",
  timestamp: now | floor
}')

echo "publishing ${PURL} as task ${TASK_ID}"
# shellcheck disable=SC2086
kubectl exec ${NATS_BOX} -- nats pub tasks.purl "${MESSAGE}"
echo "queued; follow the processor logs to watch the pipeline"
