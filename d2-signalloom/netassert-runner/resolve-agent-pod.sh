#!/bin/sh
# Resolves every known pod placeholder in the fixed Netassert suite. Each
# placeholder has a fixed namespace and label selector; caller input cannot
# introduce a target. Uses this Job pod's mounted ServiceAccount token.
set -eu

TOKEN_FILE=${TOKEN_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/token}
CACERT=${CA_CERT:-/var/run/secrets/kubernetes.io/serviceaccount/ca.crt}
API=${KUBERNETES_API:-"https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"}
CONFIG_FILE=${CONFIG_FILE:-/config/netassert-signalloom.yaml}
OUTPUT_FILE=${OUTPUT_FILE:-/work/netassert-run.yaml}
TOKEN=$(cat "$TOKEN_FILE")

api_get() {
  curl -fsS --cacert "$CACERT" -H "Authorization: Bearer ${TOKEN}" "${API}$1"
}

resolve_pod() {
  placeholder=$1
  namespace=$2
  selector=$3
  pod=$(api_get "/api/v1/namespaces/${namespace}/pods?labelSelector=${selector}" | jq -r '
    [.items[]
     | select(.metadata.deletionTimestamp == null)
     | select(.status.phase == "Running")
     | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))]
    | sort_by(.metadata.creationTimestamp)
    | first.metadata.name // empty
  ')
  if [ -z "${pod:-}" ]; then
    echo "resolve-agent-pod: no Running, Ready, non-terminating pod for ${placeholder} in ${namespace}" >&2
    return 1
  fi
  printf '%s\n' "$pod"
}

cp "$CONFIG_FILE" "$OUTPUT_FILE"
while IFS="$(printf '\t')" read -r placeholder namespace selector; do
  if grep -Fq "$placeholder" "$OUTPUT_FILE"; then
    pod=$(resolve_pod "$placeholder" "$namespace" "$selector")
    sed "s/${placeholder}/${pod}/g" "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp"
    mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
    echo "resolve-agent-pod: resolved ${placeholder} to ${pod}" >&2
  fi
done <<'RESOLVERS'
agent-patsy	fe-signalloom-agents	signalloom.ai%2Fagent%3Dtrue
envoy-gateway-pod	ingress	gateway.envoyproxy.io%2Fowning-gateway-name%3Dcluster
supercred-cardvault-agent-pod	fe-signalloom-agents	app.kubernetes.io%2Fname%3Dcardvault-agent%2Csignalloom.ai%2Fsupercred%3Dtrue
RESOLVERS

if grep -Eq 'agent-patsy|envoy-gateway-pod|supercred-cardvault-agent-pod' "$OUTPUT_FILE"; then
  echo "resolve-agent-pod: recognized pod placeholder remained unresolved" >&2
  exit 1
fi

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
