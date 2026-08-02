#!/bin/sh
# Resolves the live agent pod name in fe-signalloom-agents and substitutes it
# for the "agent-patsy" placeholder in the committed netassert config, mirroring
# the sed step in d2-signalloom/Makefile's test-netassert target (the same
# substitution a human running `make test-netassert` gets for free from
# `kubectl get pod`). Uses this Job pod's own mounted ServiceAccount token —
# no kubectl binary needed, keeping the image to netassert + curl.
set -eu

TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
API="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"

AGENT_POD=$(curl -fsS --cacert "$CACERT" -H "Authorization: Bearer ${TOKEN}" \
  "${API}/api/v1/namespaces/fe-signalloom-agents/pods?labelSelector=signalloom.ai%2Fagent%3Dtrue" \
  | sed -n 's/.*"name":"\(agent-[^"]*\)".*/\1/p' | head -n1)

if [ -z "${AGENT_POD:-}" ]; then
  echo "resolve-agent-pod: no agent pod found in fe-signalloom-agents (label signalloom.ai/agent=true)" >&2
  exit 1
fi

sed "s/name: agent-patsy/name: ${AGENT_POD}/g" /config/netassert-signalloom.yaml > /work/netassert-run.yaml
echo "resolve-agent-pod: resolved agent pod ${AGENT_POD}" >&2
