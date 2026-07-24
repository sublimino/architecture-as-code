#!/usr/bin/env bash
# Retrieve attested OpenVEX documents from Archivista and merge them into one
# file for scanner consumption (grype --vex, trivy --vex).
#
# Envelopes are listed over GraphQL, downloaded by gitoid, and filtered
# client-side for the openvex attestor payload (type https://openvex.dev/ns).
set -euo pipefail

cd "$(dirname "$0")/.."

ARCHIVISTA_URL="${ARCHIVISTA_URL:-http://localhost:8082}"
OUT="${1:-vex/out/fetched.openvex.json}"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

gitoids=$(curl -fsS -X POST "${ARCHIVISTA_URL}/query" \
  -H "Content-Type: application/json" \
  -d '{"query":"query { dsses(first: 100) { edges { node { gitoidSha256 } } } }"}' \
  | jq -r '.data.dsses.edges[].node.gitoidSha256' | tr -d '\r')

found=0
for gitoid in ${gitoids}; do
  envelope="${WORK_DIR}/${gitoid}.json"
  curl -fsS "${ARCHIVISTA_URL}/download/${gitoid}" -o "${envelope}" || continue
  payload=$(jq -r '.payload' "${envelope}" | tr -d '\r\n' | base64 -d 2>/dev/null) || continue
  vex_doc=$(echo "${payload}" \
    | jq -r '.predicate.attestations[]? | select(.type == "https://openvex.dev/ns") | .attestation.vexDocument // empty' \
    2>/dev/null) || continue
  if [ -n "${vex_doc}" ] && [ "${vex_doc}" != "null" ]; then
    echo "${vex_doc}" > "${WORK_DIR}/vex-${found}.openvex.json"
    found=$((found + 1))
    echo "openvex payload in ${gitoid}"
  fi
done

if [ "${found}" -eq 0 ]; then
  echo "no attested OpenVEX documents found in Archivista"
  exit 1
fi

mkdir -p "$(dirname "${OUT}")"
vexctl merge "${WORK_DIR}"/vex-*.openvex.json > "${OUT}"
echo "merged ${found} attested VEX documents into ${OUT}"
