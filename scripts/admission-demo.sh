#!/usr/bin/env bash
# Admission control demo: Kyverno verifies cosign signatures at admission
# time. A pod from a signed image is admitted; a pod from an unsigned image
# is rejected at the API server, before it ever runs.
set -euo pipefail

cd "$(dirname "$0")/.."

KYVERNO_VERSION="v1.13.4"
# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"
REGISTRY_HOST="${REGISTRY_HOST:-127.0.0.1:5001}"
CLUSTER_IMAGE_BASE="zot.registry.svc.cluster.local:5000/acme/images"

# shellcheck source=scripts/lib/keys.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/keys.sh"
KEYS_DIR="$(keys_dir)"
test -f "${KEYS_DIR}/cosign.key" || { echo "run 'make signing-keys' first"; exit 1; }

echo "=== installing Kyverno ${KYVERNO_VERSION} (idempotent)"
# server-side apply: the Kyverno CRDs exceed the client-side annotation limit
kubectl apply --server-side --force-conflicts -f "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml" >/dev/null
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=3m

echo "=== publishing a signed and an unsigned image"
kubectl -n registry port-forward svc/zot 5001:5000 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
trap 'kill ${PORT_FORWARD_PID} 2>/dev/null || true' EXIT
wait_reachable "http://${REGISTRY_HOST}/v2/" 90

docker image inspect listener:dev >/dev/null 2>&1 || { echo "run 'make images' first"; exit 1; }

# crane pushes from the host through the port-forward; the docker daemon
# cannot reach host-local forwards on Docker Desktop
mkdir -p vex/out
LISTENER_TAR="vex/out/.push-listener.tar"
docker save listener:dev -o "${LISTENER_TAR}"
crane push --insecure "${LISTENER_TAR}" "${REGISTRY_HOST}/acme/images/listener:signed" >/dev/null
SIGNED_DIGEST=$(crane digest --insecure "${REGISTRY_HOST}/acme/images/listener:signed")
[ -f ${KEYS_DIR}/signing-config.json ] || cosign signing-config create \
  --no-default-rekor --no-default-fulcio --no-default-oidc --no-default-tsa \
  --out ${KEYS_DIR}/signing-config.json >/dev/null 2>&1
# Same flag set as every other cosign sign in the repo, asserted by
# test/cosign-signing-consistency.bats. This was previously the only call site
# without --registry-referrers-mode; the flag has since been removed everywhere
# rather than added here, because cosign v3.0.6 ignores it (see that test's
# header for the measurement). Sign by digest, never by tag: the :signed tag can
# move under a concurrent push, stranding the signature on a digest nobody serves.
COSIGN_PASSWORD="" cosign sign --yes --key "${KEYS_DIR}/cosign.key" \
  --signing-config ${KEYS_DIR}/signing-config.json --allow-insecure-registry \
  "${REGISTRY_HOST}/acme/images/listener@${SIGNED_DIGEST}"

crane push --insecure "${LISTENER_TAR}" "${REGISTRY_HOST}/acme/images/unsigned:latest" >/dev/null
rm -f "${LISTENER_TAR}"

echo "=== applying the verify-images policy"
kubectl create ns admission-demo --dry-run=client -o yaml | kubectl apply -f -
# the PEM is multiline, so each line must carry the YAML block indentation
INDENTED_KEY=$(sed 's/^/                      /' ${KEYS_DIR}/cosign.pub)
awk -v key="${INDENTED_KEY}" \
  '{ if ($0 ~ /\$\{COSIGN_PUBLIC_KEY\}/) print key; else print }' \
  policy/kyverno-verify-images.yaml | kubectl apply -f -
sleep 3

run_pod() {
  kubectl -n admission-demo run "$1" --image="$2" \
    --restart=Never --command -- sleep 60 2>&1
}

echo
echo "=== admitting a pod from the SIGNED image (expect success)"
kubectl -n admission-demo delete pod signed-pod --ignore-not-found >/dev/null
if run_pod signed-pod "${CLUSTER_IMAGE_BASE}/listener@${SIGNED_DIGEST}"; then
  echo "ADMITTED: signed image"
  admitted=0
else
  echo "unexpected: signed image was rejected"
  admitted=1
fi

echo
echo "=== admitting a pod from the UNSIGNED image (expect denial)"
kubectl -n admission-demo delete pod unsigned-pod --ignore-not-found >/dev/null
if output=$(run_pod unsigned-pod "${CLUSTER_IMAGE_BASE}/unsigned:latest"); then
  echo "unexpected: unsigned image was admitted"
  echo "${output}"
  denied=1
else
  echo "DENIED at admission, as intended"
  denied=0
fi

kubectl -n admission-demo delete pod signed-pod --ignore-not-found >/dev/null 2>&1 || true

echo
if [ "${admitted}" -eq 0 ] && [ "${denied}" -eq 0 ]; then
  echo "admission demo passed: signature required to run"
else
  echo "admission demo FAILED: admitted=${admitted} denied=${denied}"
  exit 1
fi
