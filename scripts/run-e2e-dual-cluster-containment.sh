#!/usr/bin/env bash
#
# run-e2e-dual-cluster-containment.sh - SLDC-P5-1 runner.
#
# @id     run-e2e-dual-cluster-containment
# @tests  test/e2e-dual-cluster-containment.bats
# @doc    docs/eap/SLDC-P5-1-E2E-CONTAINMENT.md
# @lib    scripts/lib/wait.sh
#
# Executes the five-step containment suite, pins one evidence directory for the
# whole run, and leaves a machine-readable summary beside the step artefacts.
#
# Usage:
#   scripts/run-e2e-dual-cluster-containment.sh [--evidence-dir DIR] [--filter REGEX]
#                                               [--repeat N] [--tap] [-- BATS_ARGS...]
#
# Exit codes: 0 all steps passed · 1 a step failed · 2 usage/preflight error.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="${REPO_ROOT}/test/e2e-dual-cluster-containment.bats"

usage() {
    sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    [ $# -gt 0 ] && { echo; echo "error: $*" >&2; return 2; }
    return 0
}

EVIDENCE_DIR=""
FILTER=""
REPEAT=1
TAP=0
declare -a BATS_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --evidence-dir) EVIDENCE_DIR="${2:?--evidence-dir requires a path}"; shift 2 ;;
        --filter)       FILTER="${2:?--filter requires a regex}"; shift 2 ;;
        --repeat)       REPEAT="${2:?--repeat requires a count}"; shift 2 ;;
        --tap)          TAP=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        --)             shift; BATS_ARGS+=("$@"); break ;;
        *)              usage "unknown option: $1"; exit 2 ;;
    esac
done

command -v bats >/dev/null 2>&1 || { echo "error: bats not on PATH" >&2; exit 2; }
[ -f "${SUITE}" ] || { echo "error: suite not found: ${SUITE}" >&2; exit 2; }

if ! [[ "${REPEAT}" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: --repeat must be a positive integer, got '${REPEAT}'" >&2
    exit 2
fi

RUN_ROOT="${EVIDENCE_DIR:-${HOME}/kusari-e2e/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "${RUN_ROOT}"
chmod 0750 "${RUN_ROOT}"

overall=0
for i in $(seq 1 "${REPEAT}"); do
    run_dir="${RUN_ROOT}"
    [ "${REPEAT}" -gt 1 ] && run_dir="${RUN_ROOT}/run-${i}"
    mkdir -p "${run_dir}"; chmod 0750 "${run_dir}"

    echo "=== run ${i}/${REPEAT} - evidence ${run_dir}"
    declare -a cmd=(bats)
    [ "${TAP}" -eq 1 ] && cmd+=(--tap)
    [ -n "${FILTER}" ] && cmd+=(-f "${FILTER}")
    cmd+=("${SUITE}")
    [ ${#BATS_ARGS[@]} -gt 0 ] && cmd+=("${BATS_ARGS[@]}")

    rc=0
    EVIDENCE_DIR="${run_dir}" "${cmd[@]}" 2>&1 | tee "${run_dir}/bats-output.log" || rc=$?
    # tee masks bats' status; recover it from PIPESTATUS.
    rc="${PIPESTATUS[0]:-${rc}}"

    passed="$(grep -cE '^ok [0-9]+' "${run_dir}/bats-output.log" || true)"
    failed="$(grep -cE '^not ok [0-9]+' "${run_dir}/bats-output.log" || true)"
    printf '{"run":%d,"exit":%d,"passed":%s,"failed":%s,"evidence_dir":"%s","finished":"%s"}\n' \
        "${i}" "${rc}" "${passed:-0}" "${failed:-0}" "${run_dir}" "$(date '+%Y-%m-%d %H:%M:%S%z')" \
        >"${run_dir}/run-summary.json"

    [ "${rc}" -ne 0 ] && overall=1
done

echo "=== evidence root: ${RUN_ROOT}"
exit "${overall}"
