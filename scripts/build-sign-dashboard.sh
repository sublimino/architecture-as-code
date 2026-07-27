#!/usr/bin/env bash
# Build the Signal Loom dashboard image, extract BuildKit supply-chain evidence,
# push it to the local registry, sign the resolved digest, and load it into Kind.
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE_REF="${IMAGE_REF:-zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/dashboard-signalloom:latest}"
LOCAL_REF="${LOCAL_REF:-localhost:5001/acme/images/signalloom/apps/dashboard-signalloom:latest}"
COSIGN_KEY="${COSIGN_KEY:-.keys/cosign.key}"
EVIDENCE_DIR="${EVIDENCE_DIR:-docs/signalloom/evidence}"
CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
CONTEXT="${CONTEXT:-d2-signalloom/apps/dashboard-signalloom}"

SBOM_FILE="${EVIDENCE_DIR}/dashboard-signalloom.sbom.spdx.json"
PROVENANCE_FILE="${EVIDENCE_DIR}/dashboard-signalloom.provenance.slsa.json"
DIGEST_FILE="${EVIDENCE_DIR}/dashboard-signalloom.digest.txt"

test -f "${COSIGN_KEY}" || { echo "${COSIGN_KEY} not found; run 'make signing-keys' first"; exit 1; }
test -d "${CONTEXT}" || { echo "dashboard build context not found: ${CONTEXT}"; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "$1 not installed"; exit 1; }
}

for tool in curl cosign crane docker find jq kind kubectl tar; do
  require_command "${tool}"
done

mkdir -p "${EVIDENCE_DIR}"
rm -f "${SBOM_FILE}" "${PROVENANCE_FILE}" "${DIGEST_FILE}"

TMP_DIR="$(mktemp -d)"
OCI_TAR="${TMP_DIR}/dashboard-signalloom.oci.tar"
OCI_DIR="${TMP_DIR}/dashboard-signalloom.oci"
IMAGE_TAR="${TMP_DIR}/dashboard-signalloom.image.tar"
PORT_FORWARD_PID=""

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

for _ in $(seq 1 60); do
  curl -fsS "http://localhost:5001/v2/" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "http://localhost:5001/v2/" >/dev/null

echo "building OCI evidence archive for ${IMAGE_REF}"
docker buildx build \
  --sbom=true \
  --provenance=mode=max \
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

echo "building runnable image into the local Docker image store"
docker buildx build -t "${IMAGE_REF}" --load "${CONTEXT}"

echo "pushing ${IMAGE_REF} to ${LOCAL_REF}"
docker save -o "${IMAGE_TAR}" "${IMAGE_REF}"
crane push --insecure "${IMAGE_TAR}" "${LOCAL_REF}"

DIGEST="$(crane digest --insecure "${LOCAL_REF}")"
printf '%s\n' "${DIGEST}" > "${DIGEST_FILE}"
LOCAL_DIGEST_REF="${LOCAL_REF%:*}@${DIGEST}"

echo "signing ${LOCAL_DIGEST_REF}"
COSIGN_PASSWORD="" cosign sign --yes \
  --key "${COSIGN_KEY}" \
  --use-signing-config=false \
  --tlog-upload=false \
  --allow-insecure-registry \
  --registry-referrers-mode=legacy \
  "${LOCAL_DIGEST_REF}"

echo "loading ${IMAGE_REF} into kind cluster ${CLUSTER_NAME}"
kind load docker-image --name "${CLUSTER_NAME}" "${IMAGE_REF}"

echo "dashboard supply-chain evidence ready"
echo "  image: ${IMAGE_REF}"
echo "  local registry digest: ${LOCAL_DIGEST_REF}"
echo "  sbom: ${SBOM_FILE}"
echo "  provenance: ${PROVENANCE_FILE}"
echo "  digest: ${DIGEST_FILE}"
