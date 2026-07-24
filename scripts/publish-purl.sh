#!/usr/bin/env bash
# Publish a purl ingestion task to the OSRAMP queue. The purl listener picks
# it up, checks the cache, and queues an npm install and SBOM generation.
set -euo pipefail

PURL="${1:-pkg:npm/lodash@4.17.21}"
TASK_ID="purl-$(date +%s)"

NATS_BOX=$(kubectl get pods --all-namespaces -o wide | awk '/nats-box/{print "--namespace " $1 " " $2}' | head -n1)
test -n "${NATS_BOX}" || { echo "nats-box pod not found; is the backend running?"; exit 1; }

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
