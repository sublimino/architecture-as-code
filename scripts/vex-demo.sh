#!/usr/bin/env bash
# Phase 1 (OSRAMP L1) triage demo: scan the three service images, triage the
# findings into signed VEX statements for the three canonical cases, then
# rescan with the merged VEX document and show the triaged findings gone.
#
# Case A: a base image CVE shared by more than one container, standing in for
#         an upstream vendor VEX document.
# Case B: a false positive proven unreachable: golang.org/x/text v0.3.7 is
#         pinned in the processor, grype flags CVE-2022-32149, and govulncheck
#         proves the vulnerable symbol is never called.
# Case C: a finding with an inline mitigation recorded (hardened pod security
#         context, isolated install directories).
#
# Requires: docker, syft, grype, govulncheck, vexctl, jq, and the local
# registry (make registry) for digest-addressable image references. Witness
# signing and Archivista upload activate when the cluster backend is running.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"

OUT_DIR="vex/out"
REGISTRY_HOST="${REGISTRY_HOST:-127.0.0.1:5001}"
REGISTRY_PATH="${REGISTRY_PATH:-acme/images}"
IMAGES=(listener processor archiver)

export SYFT_REGISTRY_INSECURE_USE_HTTP=true
export GRYPE_REGISTRY_INSECURE_USE_HTTP=true

mkdir -p "${OUT_DIR}/sboms" "${OUT_DIR}/scans" "${OUT_DIR}/statements"

step() { printf '\n=== %s\n' "$*"; }

# --- publish local images to the registry so findings bind to real digests

step "publishing :dev images to ${REGISTRY_HOST}/${REGISTRY_PATH}"
kubectl -n registry port-forward svc/zot 5001:5000 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
trap 'kill ${PORT_FORWARD_PID} 2>/dev/null || true' EXIT
wait_reachable "http://${REGISTRY_HOST}/v2/" 90

# crane pushes from the host through the port-forward; the docker daemon
# cannot reach host-local forwards on Docker Desktop
declare -A DIGESTS
for image in "${IMAGES[@]}"; do
  docker image inspect "${image}:dev" >/dev/null 2>&1 || {
    echo "${image}:dev not built; run 'make images' first"; exit 1; }
  ref="${REGISTRY_HOST}/${REGISTRY_PATH}/${image}:dev"
  image_tar="${OUT_DIR}/.push-${image}.tar"
  docker save "${image}:dev" -o "${image_tar}"
  crane push --insecure "${image_tar}" "${ref}" >/dev/null
  rm -f "${image_tar}"
  DIGESTS[$image]=$(crane digest --insecure "${ref}")
  echo "${image}: ${DIGESTS[$image]}"
done

# --- SBOM generation and the baseline scan

for image in "${IMAGES[@]}"; do
  step "syft SBOM for ${image}"
  syft "registry:${REGISTRY_HOST}/${REGISTRY_PATH}/${image}:dev" \
    -o "spdx-json=${OUT_DIR}/sboms/${image}.spdx.json" --quiet
  step "grype baseline scan for ${image}"
  # scans target the registry image: grype's VEX product matching binds to
  # image digests, which SPDX files do not carry through
  grype "registry:${REGISTRY_HOST}/${REGISTRY_PATH}/${image}:dev" \
    -o json --quiet > "${OUT_DIR}/scans/${image}.baseline.json"
  count=$(jq '.matches | length' "${OUT_DIR}/scans/${image}.baseline.json")
  echo "${image}: ${count} findings"
done

product_purl() {
  # digest-only purl: grype matches it regardless of which registry hosts
  # the image, so the same statement works locally and in CI
  local image="$1"
  echo "pkg:oci/${image}@${DIGESTS[$image]//:/%3A}"
}

vuln_ids() { jq -r '.matches[].vulnerability.id' "${OUT_DIR}/scans/$1.baseline.json" | tr -d '\r' | sort -u; }

# --- Case A: base image CVE present in more than one container

step "case A: common base image finding"
CASE_A_CVE=$(comm -12 <(vuln_ids listener) <(vuln_ids processor) | head -1 || true)
if [ -z "${CASE_A_CVE}" ]; then
  CASE_A_CVE=$(comm -12 <(vuln_ids listener) <(vuln_ids archiver) | head -1 || true)
fi
if [ -n "${CASE_A_CVE}" ]; then
  echo "shared finding: ${CASE_A_CVE}"
  for image in "${IMAGES[@]}"; do
    if vuln_ids "$image" | grep -qx "${CASE_A_CVE}"; then
      vexctl create \
        --product="$(product_purl "$image")" \
        --vuln="${CASE_A_CVE}" \
        --status="not_affected" \
        --justification="vulnerable_code_not_in_execute_path" \
        --author="Acme Co. security team" \
        > "${OUT_DIR}/statements/case-a-${image}.openvex.json"
    fi
  done
else
  echo "no shared base-image finding today; case A skipped (scanner DB dependent)"
fi

# --- Case B: pinned x/text CVE, unreachable per govulncheck

step "case B: govulncheck reachability proof for the processor"
CASE_B_CVE="CVE-2022-32149"
# GOOS=linux because the processor uses Linux-only syscalls. JSON output so
# the check targets the x/text advisory specifically: exit code 3 covers any
# called vulnerability, which would conflate unrelated findings with this
# claim. Loading errors still fail hard.
set +e
GOOS=linux govulncheck -C d2-osramp-apps/apps/processor -format json ./... \
  > "${OUT_DIR}/govulncheck-processor.json"
govulncheck_rc=$?
set -e
if [ "${govulncheck_rc}" -ne 0 ] && [ "${govulncheck_rc}" -ne 3 ]; then
  echo "govulncheck failed (exit ${govulncheck_rc}); refusing to issue not_affected"
  exit 1
fi
XTEXT_CALLED=$(jq -rs \
  '[.[] | .finding? // empty | select(.osv == "GO-2022-1059") | select(.trace[0].function != null)] | length' \
  "${OUT_DIR}/govulncheck-processor.json")
if [ "${XTEXT_CALLED}" -ne 0 ]; then
  echo "govulncheck reports the x/text vulnerable symbol as reachable; refusing to issue not_affected"
  exit 1
fi
echo "govulncheck confirms the x/text vulnerable symbol is not called"
OTHER_CALLED=$(jq -rs \
  '[.[] | .finding? // empty | select(.trace[0].function != null) | .osv] | unique | join(" ")' \
  "${OUT_DIR}/govulncheck-processor.json")
if [ -n "${OTHER_CALLED}" ]; then
  echo "separate reachable findings (remediation items, not VEX candidates): ${OTHER_CALLED}"
fi

# grype may report the finding under its GHSA or GO alias; collect every id
# tied to the CVE so the VEX statements match what the scanner emits
CASE_B_IDS=$(jq -r --arg cve "${CASE_B_CVE}" \
  '.matches[] | select(.vulnerability.id == $cve or ([.relatedVulnerabilities[]?.id] | index($cve))) | .vulnerability.id' \
  "${OUT_DIR}/scans/processor.baseline.json" | tr -d '\r' | sort -u)
if [ -z "${CASE_B_IDS}" ]; then
  echo "warning: scanner did not flag ${CASE_B_CVE} on the processor SBOM"
  CASE_B_IDS="${CASE_B_CVE}"
elif ! echo "${CASE_B_IDS}" | grep -qx "${CASE_B_CVE}"; then
  CASE_B_IDS="${CASE_B_IDS} ${CASE_B_CVE}"
fi
for vuln_id in ${CASE_B_IDS}; do
  vexctl create \
    --product="$(product_purl processor)" \
    --subcomponents="pkg:golang/golang.org/x/text@v0.3.7" \
    --vuln="${vuln_id}" \
    --status="not_affected" \
    --justification="vulnerable_code_not_in_execute_path" \
    --author="Acme Co. security team" \
    > "${OUT_DIR}/statements/case-b-${vuln_id}.openvex.json"
done

# --- Case C: inline mitigation on the highest-severity remaining finding

step "case C: inline mitigation record"
CASE_C_CVE=$(jq -r --arg skip "${CASE_A_CVE:-none}" \
  '[.matches[] | select(.vulnerability.id != $skip)]
   | sort_by(.vulnerability.severity != "Critical", .vulnerability.severity != "High")
   | .[0].vulnerability.id // empty' \
  "${OUT_DIR}/scans/processor.baseline.json")
if [ -n "${CASE_C_CVE}" ] && [ "${CASE_C_CVE}" != "${CASE_B_CVE}" ]; then
  echo "mitigated finding: ${CASE_C_CVE}"
  vexctl create \
    --product="$(product_purl processor)" \
    --vuln="${CASE_C_CVE}" \
    --status="not_affected" \
    --justification="inline_mitigations_already_exist" \
    --author="Acme Co. security team" \
    > "${OUT_DIR}/statements/case-c-processor.openvex.json"
else
  echo "no distinct finding available for case C today; skipped"
fi

# --- merge, optionally sign under witness, rescan

step "merging VEX statements"
MERGED="${OUT_DIR}/osramp.openvex.json"
vexctl merge "${OUT_DIR}"/statements/*.openvex.json > "${MERGED}"
jq '.statements | length' "${MERGED}" | xargs echo "merged statements:"

ARCHIVISTA_URL="${ARCHIVISTA_URL:-}"
if [ -z "${ARCHIVISTA_URL}" ] && kubectl -n backend get svc osramp-archivista >/dev/null 2>&1; then
  kubectl -n backend port-forward svc/osramp-archivista 8082:8082 >/dev/null 2>&1 &
  ARCHIVISTA_PID=$!
  trap 'kill ${PORT_FORWARD_PID} ${ARCHIVISTA_PID} 2>/dev/null || true' EXIT
  sleep 2
  ARCHIVISTA_URL="http://localhost:8082"
fi
if [ -n "${ARCHIVISTA_URL}" ] && command -v witness >/dev/null 2>&1 && [ -f .keys/witness.pem ]; then
  step "signing the VEX document under witness and uploading to Archivista"
  # scoped to vex/out so materials and products are the analysis artifacts,
  # not the whole repository
  KEYS_ABS="$(pwd)/.keys/witness.pem"
  # the target is removed first so the copy always registers as a fresh
  # product for the vex attestor to embed
  rm -f "${OUT_DIR}/osramp.attested.openvex.json"
  (cd "${OUT_DIR}" && witness run --step vex-analysis \
    -a vex \
    -o "vex-analysis.attestation.json" \
    -k "${KEYS_ABS}" \
    --enable-archivista --archivista-server="${ARCHIVISTA_URL}" \
    -- cp "osramp.openvex.json" "osramp.attested.openvex.json")
else
  echo "witness signing skipped (needs the cluster backend, witness, and .keys/witness.pem)"
fi

step "rescanning with the merged VEX document"
for image in "${IMAGES[@]}"; do
  grype "registry:${REGISTRY_HOST}/${REGISTRY_PATH}/${image}:dev" --vex "${MERGED}" \
    -o json --quiet > "${OUT_DIR}/scans/${image}.with-vex.json"
  before=$(jq '.matches | length' "${OUT_DIR}/scans/${image}.baseline.json")
  after=$(jq '.matches | length' "${OUT_DIR}/scans/${image}.with-vex.json")
  echo "${image}: ${before} findings before VEX, ${after} after"
done

step "verifying the triaged findings are suppressed"
fail=0
for cve in ${CASE_A_CVE:-} ${CASE_B_IDS} ${CASE_C_CVE:-}; do
  if jq -e --arg cve "$cve" \
      '.matches[] | select(.vulnerability.id == $cve or ([.relatedVulnerabilities[]?.id] | index($cve)))' \
      "${OUT_DIR}/scans/processor.with-vex.json" >/dev/null 2>&1; then
    echo "STILL PRESENT on processor: ${cve}"
    fail=1
  else
    echo "suppressed: ${cve}"
  fi
done
exit ${fail}
