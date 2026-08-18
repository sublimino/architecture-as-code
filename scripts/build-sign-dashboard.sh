#!/usr/bin/env bash
# Build the Signal Loom dashboard image, extract BuildKit supply-chain evidence,
# push it to the local registry, sign the resolved digest, and load it into Kind.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"

IMAGE_REF="${IMAGE_REF:-zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/dashboard-signalloom:latest}"
LOCAL_REF="${LOCAL_REF:-localhost:5001/acme/images/signalloom/apps/dashboard-signalloom:latest}"
# shellcheck source=scripts/lib/keys.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/keys.sh"
KEYS_DIR="$(keys_dir)"
COSIGN_KEY="${COSIGN_KEY:-${KEYS_DIR}/cosign.key}"
EVIDENCE_DIR="${EVIDENCE_DIR:-docs/signalloom/evidence}"
CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
CONTEXT="${CONTEXT:-d2-signalloom/apps/dashboard-signalloom}"

SBOM_FILE="${EVIDENCE_DIR}/dashboard-signalloom.sbom.spdx.json"
PROVENANCE_FILE="${EVIDENCE_DIR}/dashboard-signalloom.provenance.slsa.json"
DIGEST_FILE="${EVIDENCE_DIR}/dashboard-signalloom.digest.txt"

test -f "${COSIGN_KEY}" || { echo "${COSIGN_KEY} not found; run 'make signing-keys' first"; exit 1; }
test -d "${CONTEXT}" || { echo "dashboard build context not found: ${CONTEXT}"; exit 1; }
BUILD_FLAGS=()
if [ "${DASHBOARD_NO_CACHE:-0}" = "1" ]; then
  BUILD_FLAGS+=(--no-cache)
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "$1 not installed"; exit 1; }
}

for tool in curl cosign crane docker find jq kind kubectl sha256sum skopeo tar; do
  require_command "${tool}"
done

mkdir -p "${EVIDENCE_DIR}"
rm -f "${SBOM_FILE}" "${PROVENANCE_FILE}" "${DIGEST_FILE}"

TMP_DIR="$(mktemp -d)"
OCI_TAR="${TMP_DIR}/dashboard-signalloom.oci.tar"
OCI_DIR="${TMP_DIR}/dashboard-signalloom.oci"
PORT_FORWARD_PID=""

# Keep the source identity aligned with .dockerignore. Its use immediately
# before COPY . . prevents BuildKit from reusing application layers for a
# different source tree while retaining the package-install cache.
#
# The computation moved into scripts/lib/source-id.sh and is NOT reproduced here.
# The same fingerprint is now also read back out of the running pod by
# scripts/check-deployed-staleness.sh, and that comparison is only meaningful
# while both sides are produced by one piece of code — two copies of this tar
# pipeline would drift the moment one was edited, and a guard that fires on an
# up-to-date deployment gets muted, which is worse than no guard.
# shellcheck source=scripts/lib/source-id.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/source-id.sh"
SOURCE_ID="$(source_id_for dashboard-signalloom)"
GIT_REF="$(source_id_git_ref)"
test -n "${SOURCE_ID}" || { echo "dashboard source fingerprint is empty"; exit 1; }

cleanup() {
  if [ -n "${PORT_FORWARD_PID}" ]; then
    kill "${PORT_FORWARD_PID}" 2>/dev/null || true
  fi
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

if curl -fsS "http://localhost:5001/v2/" >/dev/null 2>&1; then
  echo "using existing registry endpoint on localhost:5001"
else
  kubectl -n registry port-forward svc/zot 5001:5000 >/dev/null 2>&1 &
  PORT_FORWARD_PID=$!
  echo "started registry port-forward on localhost:5001"
fi

wait_reachable "http://localhost:5001/v2/" 90

# ── Why this build needs its own builder ────────────────────────────────────
#
# This is the only build in the estate that asks for attestations and an OCI
# archive, and those two demands are what make it incompatible with the default
# builder on a current Docker.
#
# Docker's default "docker" driver refuses both unless the containerd image
# store is enabled:
#
#   ERROR: failed to build: Attestation is not supported for the docker driver.
#   Switch to a different driver, or turn on the containerd image store.
#
# Turning that store on is not a free choice, because it breaks the OTHER half
# of the estate: under the containerd image store `kind load` exits 0 having
# transferred nothing (see Makefile:297 and scripts/kind-load-verified.sh), so
# every plain `docker build` in signalloom-images reaches the node as a stale
# image or not at all. There is no setting of that one flag that satisfies both.
#
# The resolution is the first branch of Docker's own advice — a different
# driver — applied HERE ONLY. A `docker-container` builder supports
# attestations and OCI export regardless of the image store, so the daemon can
# keep the classic store that `kind load` needs.
#
# It must NOT be made the global default. `docker build` is buildx in Docker
# 23+, so a default docker-container builder silently stops loading plain
# builds into the daemon: the images build, report success, and never appear in
# `docker images`. kind-load-verified.sh then compares the node against a stale
# image and reports a rootfs diffID divergence — a confusing symptom two steps
# removed from its cause. Keep the scope to this one invocation.
BUILDX_BUILDER_NAME="${BUILDX_BUILDER_NAME:-signalloom-oci}"
if ! docker buildx inspect "${BUILDX_BUILDER_NAME}" >/dev/null 2>&1; then
  echo "creating docker-container builder ${BUILDX_BUILDER_NAME} (attestations + OCI export)"
  docker buildx create --name "${BUILDX_BUILDER_NAME}" --driver docker-container --bootstrap >/dev/null
fi

echo "building OCI evidence and runnable image archive for ${IMAGE_REF}"
docker buildx build \
  --builder "${BUILDX_BUILDER_NAME}" \
  "${BUILD_FLAGS[@]}" \
  --sbom=true \
  --provenance=mode=max \
  --build-arg "SOURCE_ID=${SOURCE_ID}" \
  --build-arg "GIT_REF=${GIT_REF}" \
  -t "${IMAGE_REF}" \
  --output "type=oci,dest=${OCI_TAR}" \
  "${CONTEXT}"

mkdir -p "${OCI_DIR}"
tar -xf "${OCI_TAR}" -C "${OCI_DIR}"
test -f "${OCI_DIR}/index.json" || { echo "OCI evidence archive missing index.json: ${OCI_TAR}"; exit 1; }

SBOM_FOUND=0
PROVENANCE_FOUND=0
while IFS= read -r blob; do
  if [ "${SBOM_FOUND}" -eq 0 ] && jq -e '.predicateType == "https://spdx.dev/Document" and (.predicate.spdxVersion // .predicate.SPDXID)' "${blob}" >/dev/null 2>&1; then
    jq '.predicate' "${blob}" > "${SBOM_FILE}"
    SBOM_FOUND=1
  fi
  if [ "${PROVENANCE_FOUND}" -eq 0 ] && jq -e '(.predicateType // "") | startswith("https://slsa.dev/provenance/")' "${blob}" >/dev/null 2>&1; then
    jq '.' "${blob}" > "${PROVENANCE_FILE}"
    PROVENANCE_FOUND=1
  fi
  if [ "${SBOM_FOUND}" -eq 1 ] && [ "${PROVENANCE_FOUND}" -eq 1 ]; then
    break
  fi
done < <(find "${OCI_DIR}/blobs/sha256" -type f | sort)

test -f "${SBOM_FILE}" || { echo "SPDX SBOM attestation not found in ${OCI_TAR}"; exit 1; }
test -f "${PROVENANCE_FILE}" || { echo "SLSA provenance attestation not found in ${OCI_TAR}"; exit 1; }
jq -e '.spdxVersion // .SPDXID' "${SBOM_FILE}" >/dev/null || { echo "extracted SBOM is not valid SPDX JSON: ${SBOM_FILE}"; exit 1; }
jq -e '(.predicateType // "") | startswith("https://slsa.dev/provenance/")' "${PROVENANCE_FILE}" >/dev/null || { echo "extracted provenance is not SLSA provenance: ${PROVENANCE_FILE}"; exit 1; }
PROV_PREDICATE_TYPE="$(jq -r '.predicateType' "${PROVENANCE_FILE}")"
echo "provenance predicateType: ${PROV_PREDICATE_TYPE} (BuildKit local build; delivery-contract targets .../v1 — see evidence README)"

echo "loading the runnable image from the OCI evidence archive"
skopeo copy --insecure-policy \
  --override-os linux \
  --override-arch amd64 \
  "oci-archive:${OCI_TAR}" \
  "docker-daemon:${IMAGE_REF}"

echo "pushing ${IMAGE_REF} to ${LOCAL_REF}"
skopeo copy --insecure-policy \
  --dest-tls-verify=false \
  --override-os linux \
  --override-arch amd64 \
  "oci-archive:${OCI_TAR}" \
  "docker://${LOCAL_REF}"

DIGEST="$(crane digest --insecure "${LOCAL_REF}")"
printf '%s\n' "${DIGEST}" > "${DIGEST_FILE}"
LOCAL_DIGEST_REF="${LOCAL_REF%:*}@${DIGEST}"

echo "signing ${LOCAL_DIGEST_REF}"
SIGNING_CONFIG="${SIGNING_CONFIG:-${COSIGN_KEY%/*}/signing-config.json}"
[ -f "${SIGNING_CONFIG}" ] || cosign signing-config create \
  --no-default-rekor --no-default-fulcio --no-default-oidc --no-default-tsa \
  --out "${SIGNING_CONFIG}" >/dev/null 2>&1
COSIGN_PASSWORD="" cosign sign --yes \
  --key "${COSIGN_KEY}" \
  --signing-config "${SIGNING_CONFIG}" \
  --allow-insecure-registry \
  "${LOCAL_DIGEST_REF}"

echo "loading ${IMAGE_REF} into kind cluster ${CLUSTER_NAME}"
kind load docker-image --name "${CLUSTER_NAME}" "${IMAGE_REF}"

echo "dashboard supply-chain evidence ready"
echo "  image: ${IMAGE_REF}"
echo "  local registry digest: ${LOCAL_DIGEST_REF}"
echo "  sbom: ${SBOM_FILE}"
echo "  provenance: ${PROVENANCE_FILE}"
echo "  digest: ${DIGEST_FILE}"
