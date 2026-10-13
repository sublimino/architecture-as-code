#!/usr/bin/env bash
# Admission control demo: a CEL ValidatingAdmissionPolicy gates container
# images at the API server. A digest-pinned image from the trusted registry
# is admitted; an image from an untrusted registry, and an unpinned mutable
# tag, are rejected before the pod ever runs.
#
# OSD-7: this demo used to install Kyverno v1.13.4 by
# `kubectl apply -f https://github.com/kyverno/kyverno/releases/...`. That
# made the demo depend on the internet, which an air-gapped appliance does
# not have, and on a controller that appears in NO entry of
# bundle/.manifest.d/images.json -- so the P2-4 deliverable it was meant to
# evidence was unsatisfiable as built. CEL ValidatingAdmissionPolicy needs
# no controller and no extra image: Kubernetes 1.30+ evaluates it in the
# API server.
#
# What changed in the guarantee, stated plainly rather than papered over:
# Kyverno's verifyImages performed CRYPTOGRAPHIC cosign verification at
# admission. CEL cannot -- it cannot call out of the API server, so it can
# only inspect the admission request's own fields. The trust chain is now
# two layers:
#
#   Layer 1 (signature)  Flux verifies the cosign signature before an
#                        artefact reaches the in-cluster Zot registry
#                        (OCIRepository verify.provider: cosign).
#   Layer 2 (admission)  These policies enforce that a pod may only pull a
#                        DIGEST-PINNED image FROM that registry.
#
# "In the registry" carries the signature claim; "pinned to a digest from
# the registry" is what admission can prove on its own. The demo below
# still signs the image it admits, because that signature is what layer 1
# checks -- it is simply no longer the thing the API server verifies.
#
# For cryptographic verification AT admission, the replacement is Sigstore
# policy-controller, which is not deployed. See
# docs/signalloom/image-verification-without-kyverno.md.
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"
REGISTRY_HOST="${REGISTRY_HOST:-127.0.0.1:5001}"
CLUSTER_IMAGE_BASE="zot.registry.svc.cluster.local:5000/acme/images"

# shellcheck source=scripts/lib/keys.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/keys.sh"
KEYS_DIR="$(keys_dir)"
test -f "${KEYS_DIR}/cosign.key" || { echo "run 'make signing-keys' first"; exit 1; }

# ValidatingAdmissionPolicy is GA from 1.30. On an older server the policy
# objects apply but are never enforced, so every denial below would read as
# an unexpected admission -- fail with the cause instead of the symptom.
echo "=== checking ValidatingAdmissionPolicy is served (requires k8s 1.30+)"
local_api_resources="$(kubectl api-resources --api-group=admissionregistration.k8s.io 2>/dev/null || true)"
if ! grep -q '\bvalidatingadmissionpolicies\b' <<<"$local_api_resources"; then
  echo "admissionregistration.k8s.io ValidatingAdmissionPolicy is not served by this API server"
  echo "the ValidatingAdmissionPolicy feature is GA in Kubernetes 1.30; this demo requires it"
  exit 1
fi

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
#
# This signature is layer 1 of the chain described in the header. It is what
# Flux verifies before the artefact is trusted; the API server policy below
# verifies provenance-by-registry and digest pinning, not this signature.
COSIGN_PASSWORD="" cosign sign --yes --key "${KEYS_DIR}/cosign.key" \
  --signing-config ${KEYS_DIR}/signing-config.json --allow-insecure-registry \
  "${REGISTRY_HOST}/acme/images/listener@${SIGNED_DIGEST}"

crane push --insecure "${LISTENER_TAR}" "${REGISTRY_HOST}/acme/images/unsigned:latest" >/dev/null
rm -f "${LISTENER_TAR}"

echo "=== applying the CEL admission policies (no controller, no network fetch)"
kubectl create ns admission-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f policy/cel/require-trusted-registry.yaml
kubectl apply -f policy/cel/require-image-digest.yaml
kubectl apply -f policy/cel/admission-demo-bindings.yaml

# The API server compiles a policy and caches its bindings asynchronously,
# so an immediate pod create can race ahead of enforcement and be admitted.
# Wait on the objects, then on enforcement actually biting: a known-bad pod
# must be REJECTED before any verdict below is trusted. Without this second
# wait the whole demo can pass vacuously on a slow control plane.
_wait_retry 15 "validatingadmissionpolicy sl-require-trusted-registry registered" \
  "kubectl get validatingadmissionpolicy sl-require-trusted-registry >/dev/null 2>&1"
_wait_retry 15 "validatingadmissionpolicybinding sl-admission-demo-trusted-registry-binding registered" \
  "kubectl get validatingadmissionpolicybinding sl-admission-demo-trusted-registry-binding >/dev/null 2>&1"
_wait_retry 30 "admission enforcement is live (a known-bad pod is refused)" \
  "! kubectl -n admission-demo run enforcement-probe --image=docker.io/library/busybox:latest \
      --dry-run=server --restart=Never --command -- sleep 1 >/dev/null 2>&1"

run_pod() {
  kubectl -n admission-demo run "$1" --image="$2" \
    --restart=Never --command -- sleep 60 2>&1
}

echo
echo "=== admitting a pod from the DIGEST-PINNED trusted image (expect success)"
kubectl -n admission-demo delete pod pinned-pod --ignore-not-found >/dev/null
if run_pod pinned-pod "${CLUSTER_IMAGE_BASE}/listener@${SIGNED_DIGEST}"; then
  echo "ADMITTED: digest-pinned image from the trusted registry"
  admitted=0
else
  echo "unexpected: the digest-pinned trusted image was rejected"
  admitted=1
fi

echo
echo "=== admitting a pod from an UNTRUSTED REGISTRY (expect denial)"
kubectl -n admission-demo delete pod untrusted-pod --ignore-not-found >/dev/null
# Digest-pinned, so only the registry allowlist can be what refuses it:
# pinning a digest does not make a registry trustworthy, because an
# attacker controls both the tag and the digest in a registry they own.
if output=$(run_pod untrusted-pod "docker.io/library/busybox@${SIGNED_DIGEST}"); then
  echo "unexpected: an image from an untrusted registry was admitted"
  echo "${output}"
  denied_untrusted=1
else
  echo "DENIED at admission, as intended (untrusted registry)"
  denied_untrusted=0
fi

echo
echo "=== admitting a pod from an UNPINNED MUTABLE TAG (expect denial)"
kubectl -n admission-demo delete pod unpinned-pod --ignore-not-found >/dev/null
# From the trusted registry, so only the digest requirement can refuse it.
if output=$(run_pod unpinned-pod "${CLUSTER_IMAGE_BASE}/unsigned:latest"); then
  echo "unexpected: an unpinned mutable tag was admitted"
  echo "${output}"
  denied_unpinned=1
else
  echo "DENIED at admission, as intended (tag not pinned to a digest)"
  denied_unpinned=0
fi

kubectl -n admission-demo delete pod pinned-pod --ignore-not-found >/dev/null 2>&1 || true

echo
if [ "${admitted}" -eq 0 ] && [ "${denied_untrusted}" -eq 0 ] && [ "${denied_unpinned}" -eq 0 ]; then
  echo "admission demo passed: a digest-pinned platform image is admitted, an untrusted one rejected"
else
  echo "admission demo FAILED: admitted=${admitted} denied_untrusted=${denied_untrusted} denied_unpinned=${denied_unpinned}"
  exit 1
fi
