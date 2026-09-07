#!/bin/sh
# Resolves the live agent pod name in fe-signalloom-agents and substitutes it
# for the "agent-patsy" placeholder in the committed netassert config, mirroring
# the sed step in d2-signalloom/Makefile's test-netassert target (the same
# substitution a human running `make test-netassert` gets for free from
# `kubectl get pod`). Uses this Job pod's own mounted ServiceAccount token —
# no kubectl binary needed, keeping the image to netassert + curl.
set -eu

TOKEN_FILE=${TOKEN_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/token}
CACERT=${CA_CERT:-/var/run/secrets/kubernetes.io/serviceaccount/ca.crt}
API=${KUBERNETES_API:-"https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"}
CONFIG_FILE=${CONFIG_FILE:-/config/netassert-signalloom.yaml}
OUTPUT_FILE=${OUTPUT_FILE:-/work/netassert-run.yaml}
AGENT_NAMESPACE=fe-signalloom-agents
TOKEN=$(cat "$TOKEN_FILE")

api_get() {
  curl -fsS --cacert "$CACERT" -H "Authorization: Bearer ${TOKEN}" "${API}$1"
}

AGENT_POD=$(api_get "/api/v1/namespaces/${AGENT_NAMESPACE}/pods?labelSelector=signalloom.ai%2Fagent%3Dtrue" | jq -r '
  [.items[]
   | select(.metadata.deletionTimestamp == null)
   | select(.status.phase == "Running")
   | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))]
  | sort_by(.metadata.creationTimestamp)
  | first.metadata.name // empty
')

if [ -z "${AGENT_POD:-}" ]; then
  echo "resolve-agent-pod: no Running, Ready, non-terminating agent pod found in ${AGENT_NAMESPACE}" >&2
  exit 1
fi

sed "s/name: agent-patsy/name: ${AGENT_POD}/g" "$CONFIG_FILE" > "$OUTPUT_FILE"

# A denied assertion is meaningful only when its destination exists. Netassert
# considers the scanner's connection failure sufficient for expected exitCode
# 1, which otherwise makes a scaled-to-zero or terminating destination look
# like policy enforcement. Fail before Netassert so the Job is unavailable,
# never falsely green/denied. The fixed ConfigMap is the only suite input.
yq -r '.[] | select(.dst.k8sResource) | .dst.k8sResource
  | [.kind, .name, .namespace] | @tsv' "$OUTPUT_FILE" |
while IFS="$(printf '\t')" read -r kind name namespace; do
  case "$kind" in
    pod)
      path="/api/v1/namespaces/${namespace}/pods/${name}"
      predicate='.metadata.deletionTimestamp == null and .status.phase == "Running"
        and any(.status.conditions[]?; .type == "Ready" and .status == "True")'
      ;;
    deployment)
      path="/apis/apps/v1/namespaces/${namespace}/deployments/${name}"
      predicate='.metadata.deletionTimestamp == null and (.status.availableReplicas // 0) > 0'
      ;;
    statefulset)
      path="/apis/apps/v1/namespaces/${namespace}/statefulsets/${name}"
      predicate='.metadata.deletionTimestamp == null and (.status.readyReplicas // 0) > 0'
      ;;
    daemonset)
      path="/apis/apps/v1/namespaces/${namespace}/daemonsets/${name}"
      predicate='.metadata.deletionTimestamp == null and (.status.numberReady // 0) > 0'
      ;;
    *)
      echo "resolve-agent-pod: destination unavailable: unsupported ${kind}/${namespace}/${name}" >&2
      exit 1
      ;;
  esac
  if ! api_get "$path" | jq -e "$predicate" >/dev/null; then
    echo "resolve-agent-pod: destination unavailable: ${kind}/${namespace}/${name}" >&2
    exit 1
  fi
done

echo "resolve-agent-pod: resolved agent pod ${AGENT_POD}" >&2
