#!/usr/bin/env bash
#
# final-governor-certification.sh - SLDC-P5-GOV mission certification gate.
#
# @id     final-governor-certification
# @tests  test/final-mission-governor.bats
# @doc    docs/eap/SLDC-MISSION-CERTIFICATION.md
# @lib    scripts/package-eap-evidence.sh, scripts/verify-eap-evidence.sh
#
# Runs the five-step containment suite N times (default 3), fail-fast, resetting
# agent state between runs. Only when every run is green with zero skips does it
# package and verify the forensic bundle. The mission is certified only when the
# bundle verifies AND every required human approver has signed the certificate
# digest. An agent can never produce status=pass on its own.
#
# Usage:
#   scripts/final-governor-certification.sh [--runs N] [--out DIR] [--signoff FILE]
#
# Injectable boundaries (every external dependency is overridable):
#   SLDC_E2E_CMD      command run once per iteration; receives EVIDENCE_DIR in env,
#                     must emit TAP on stdout   (default: bats --tap test/e2e-dual-cluster-containment.bats)
#   SLDC_RESET_CMD    command run between iterations (default: restart agent-kusari
#                     on kind-osramp and wait for rollout)
#   SLDC_PACKAGE_CMD  bundle packager           (default: scripts/package-eap-evidence.sh)
#   SLDC_VERIFY_CMD   bundle verifier           (default: scripts/verify-eap-evidence.sh --require-live)
#   SLDC_APPROVERS    comma-separated identities that must sign
#
# Sign-off file (JSON): {"approvers":[{"identity":"...","role":"...","signature_file":"...",
#   "allowed_signers":"..."}]}. Each signature is an `ssh-keygen -Y sign -n sldc-mission-cert`
#   signature over the certificate digest file and is verified with `ssh-keygen -Y verify`.
#
# Exit codes: 0 certified · 1 gate failed (red run, skip, bundle or sign-off) · 2 usage.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS=3
OUT_DIR="${REPO_ROOT}/ci-evidence"
SIGNOFF=""
APPROVERS="${SLDC_APPROVERS:-Andrew Martin,John Kjell,Francesco Beltramini,Wendy Overton}"

while [ $# -gt 0 ]; do
    case "$1" in
        --runs)    RUNS="${2:?--runs requires a count}"; shift 2 ;;
        --out)     OUT_DIR="${2:?--out requires a dir}"; shift 2 ;;
        --signoff) SIGNOFF="${2:?--signoff requires a file}"; shift 2 ;;
        -h|--help) sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         echo "error: unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ "${RUNS}" =~ ^[1-9][0-9]*$ ]] || { echo "error: --runs must be a positive integer" >&2; exit 2; }

E2E_CMD="${SLDC_E2E_CMD:-bats --tap ${REPO_ROOT}/test/e2e-dual-cluster-containment.bats}"
RESET_CMD="${SLDC_RESET_CMD:-kubectl --context kind-osramp -n fe-signalloom-agents rollout restart deploy/agent-kusari && kubectl --context kind-osramp -n fe-signalloom-agents rollout status deploy/agent-kusari --timeout=180s}"
PACKAGE_CMD="${SLDC_PACKAGE_CMD:-${REPO_ROOT}/scripts/package-eap-evidence.sh}"
VERIFY_CMD="${SLDC_VERIFY_CMD:-${REPO_ROOT}/scripts/verify-eap-evidence.sh --require-live}"

mkdir -p "${OUT_DIR}"
RUN_ROOT="${OUT_DIR}/final-e2e-runs"
mkdir -p "${RUN_ROOT}"
LOG="${OUT_DIR}/final-e2e-consecutive-runs.log"
CERT="${OUT_DIR}/final-mission-certification.json"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*" | tee -a "${LOG}"; }

verify_signoffs() {
    # Verify every required approver's ssh signature over the stored digest.
    local digest_file="$1" who entry sig as ok out="[]" all=true
    IFS=',' read -r -a required <<<"${APPROVERS}"
    for who in "${required[@]}"; do
        entry=$(jq -c --arg w "${who}" '.approvers[]? | select(.identity==$w)' "${SIGNOFF}" | head -1)
        ok=false
        if [ -n "${entry}" ]; then
            sig=$(jq -r '.signature_file' <<<"${entry}"); as=$(jq -r '.allowed_signers' <<<"${entry}")
            if [ -f "${sig}" ] && [ -f "${as}" ] && ssh-keygen -Y verify -f "${as}" -I "${who}" \
                -n sldc-mission-cert -s "${sig}" <"${digest_file}" >/dev/null 2>&1; then
                ok=true
            fi
        fi
        [ "${ok}" = true ] || { all=false; missing="${missing:-}${missing:+, }${who}"; }
        out=$(jq -c --arg w "${who}" --argjson ok "${ok}" '. + [{identity:$w, verified:$ok}]' <<<"${out}")
    done
    SIGNOFF_JSON="${out}"
    [ "${all}" = true ]
}

if [ -n "${SIGNOFF}" ]; then
    # Finalise mode: never re-runs the suite; signs off the recorded certificate.
    [ -f "${SIGNOFF}" ] || { echo "error: sign-off file not found: ${SIGNOFF}" >&2; exit 2; }
    [ -f "${CERT}" ] || { echo "error: no certificate at ${CERT}; run the gate first" >&2; exit 2; }
    [ "$(jq -r .status "${CERT}")" = "awaiting-signoff" ] \
        || { echo "error: certificate status is $(jq -r .status "${CERT}"), not awaiting-signoff" >&2; exit 1; }
    digest_file="${OUT_DIR}/final-mission-certification.digest"
    [ "$(cat "${digest_file}")" = "$(jq -r .certificate_digest "${CERT}")" ] \
        || { echo "error: digest file does not match certificate" >&2; exit 1; }
    # The status label is only a hint: re-derive it from the records the
    # approvers' digest covers, so an edited certificate cannot be signed off.
    [ "$(jq -cj '{runs, bundle_sha256, integration_head}' "${CERT}" | sha256sum | cut -d' ' -f1)" \
        = "$(jq -r .certificate_digest "${CERT}")" ] \
        || { echo "error: certificate_digest does not match its recorded runs and bundle" >&2; exit 1; }
    jq -e '(.runs | length) == .consecutive_green_required and .consecutive_green_achieved == .consecutive_green_required
           and all(.runs[]; .exit == 0 and .failed == 0 and .skipped == 0 and .passed > 0)
           and (.bundle_sha256 | test("^[0-9a-f]{64}$"))' "${CERT}" >/dev/null \
        || { echo "error: certificate records do not support sign-off (red, short or bundle-less run)" >&2; exit 1; }
    [ "$(sha256sum "$(jq -r .bundle "${CERT}")" 2>/dev/null | cut -d' ' -f1)" = "$(jq -r .bundle_sha256 "${CERT}")" ] \
        || { echo "error: certified bundle no longer matches bundle_sha256" >&2; exit 1; }
    missing=""
    if verify_signoffs "${digest_file}"; then st=pass; rs=""; else st=awaiting-signoff; rs="human sign-off missing or unverifiable for ${missing}"; fi
    jq --arg st "${st}" --arg rs "${rs}" --argjson so "${SIGNOFF_JSON}" \
       '.status=$st | .reason=$rs | .signoffs=$so' "${CERT}" >"${CERT}.tmp" && mv "${CERT}.tmp" "${CERT}"
    echo "certification status=${st}${rs:+ reason=${rs}}"
    [ "${st}" = pass ]
    exit
fi

: >"${LOG}"
runs_json="[]"
status="pass"
reason=""
green=0

for i in $(seq 1 "${RUNS}"); do
    run_dir="${RUN_ROOT}/run-${i}"
    rm -rf "${run_dir}"; mkdir -p "${run_dir}"
    log "=== RUN ${i}/${RUNS} evidence=${run_dir}"
    start=$(date +%s)
    rc=0
    EVIDENCE_DIR="${run_dir}" SLDC_RUN_INDEX="${i}" bash -c "${E2E_CMD}" >"${run_dir}/tap.txt" 2>&1 || rc=$?
    secs=$(( $(date +%s) - start ))
    cat "${run_dir}/tap.txt" >>"${LOG}"
    passed=$(grep -cE '^ok [0-9]+' "${run_dir}/tap.txt" || true)
    failed=$(grep -cE '^not ok [0-9]+' "${run_dir}/tap.txt" || true)
    skipped=$(grep -ciE '^ok [0-9]+ .*# skip' "${run_dir}/tap.txt" || true)
    runs_json=$(jq -c --argjson i "${i}" --argjson rc "${rc}" --argjson p "${passed}" \
        --argjson f "${failed}" --argjson s "${skipped}" --argjson t "${secs}" \
        '. + [{run:$i, exit:$rc, passed:$p, failed:$f, skipped:$s, seconds:$t}]' <<<"${runs_json}")
    log "=== RUN ${i} exit=${rc} passed=${passed} failed=${failed} skipped=${skipped} seconds=${secs}"

    if [ "${rc}" -ne 0 ] || [ "${failed}" -ne 0 ]; then
        status="fail"; reason="run ${i} red (exit=${rc}, failed=${failed}); consecutive-green chain broken"; break
    fi
    if [ "${skipped}" -ne 0 ] || [ "${passed}" -eq 0 ]; then
        status="fail"; reason="run ${i} had ${skipped} skipped / ${passed} passed; a skip or empty run is not green"; break
    fi
    planned=$(sed -nE 's/^1\.\.([0-9]+)$/\1/p' "${run_dir}/tap.txt" | head -1)
    if [ "${planned:-0}" -ne "${passed}" ]; then
        status="fail"; reason="run ${i} reported ${passed} of ${planned:-no} planned tests; a short run is not green"; break
    fi
    green=$((green + 1))
    if [ "${i}" -lt "${RUNS}" ]; then
        log "=== reset before run $((i + 1))"
        bash -c "${RESET_CMD}" >>"${LOG}" 2>&1 || { status="fail"; reason="state reset after run ${i} failed"; break; }
    fi
done

bundle=""; bundle_sha=""
if [ "${status}" = "pass" ]; then
    last="${RUN_ROOT}/run-${RUNS}"
    # Only a bundle built from this run may be certified: never a leftover.
    rm -rf "${OUT_DIR}/bundle-staging"
    if bash -c "${PACKAGE_CMD} '${last}' --out '${OUT_DIR}/bundle-staging'" >>"${LOG}" 2>&1; then
        built=$(ls -1t "${OUT_DIR}"/bundle-staging/*.tar.gz 2>/dev/null | head -1 || true)
        if [ -n "${built}" ] && bash -c "${VERIFY_CMD} '${built}'" >>"${LOG}" 2>&1; then
            bundle="${OUT_DIR}/kusari-eap-certified-bundle.tar.gz"
            cp "${built}" "${bundle}"
            bundle_sha=$(sha256sum "${bundle}" | cut -d' ' -f1)
            log "=== bundle verified sha256=${bundle_sha}"
        else
            status="fail"; reason="evidence bundle failed verification"
        fi
    else
        status="fail"; reason="evidence bundle packaging refused"
    fi
fi

# Certificate digest over what the approvers attest to: the run record and bundle.
digest_input=$(jq -cn --argjson runs "${runs_json}" --arg b "${bundle_sha}" \
    --arg head "$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unresolved)" \
    '{runs:$runs, bundle_sha256:$b, integration_head:$head}')
cert_digest=$(printf '%s' "${digest_input}" | sha256sum | cut -d' ' -f1)
printf '%s' "${cert_digest}" >"${OUT_DIR}/final-mission-certification.digest"

signoffs="[]"
if [ "${status}" = "pass" ]; then
    status="awaiting-signoff"
    reason="runs and bundle green; human sign-off required: finalise with --signoff FILE"
fi
jq -n --arg status "${status}" --arg reason "${reason}" --argjson runs "${runs_json}" \
    --argjson required "${RUNS}" --argjson green "${green}" --arg bundle "${bundle}" \
    --arg bundle_sha "${bundle_sha}" --arg digest "${cert_digest}" --argjson signoffs "${signoffs}" \
    --arg at "$(date '+%Y-%m-%d %H:%M:%S%z')" --argjson dig "${digest_input}" \
    '{schema:"sldc-mission-certification/v1", status:$status, reason:$reason, generated_at:$at,
      integration_head:$dig.integration_head, consecutive_green_required:$required,
      consecutive_green_achieved:$green, runs:$runs, bundle:$bundle, bundle_sha256:$bundle_sha,
      certificate_digest:$digest, signoffs:$signoffs}' >"${CERT}"

log "=== certification status=${status}${reason:+ reason=${reason}}"
[ "${status}" = "pass" ]
