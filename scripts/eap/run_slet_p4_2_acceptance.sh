#!/usr/bin/env bash
# ==============================================================================
# scripts/eap/run_slet_p4_2_acceptance.sh
# SLET-P4-2 — run the kurasi tenant isolation acceptance suite.
#
#   run_slet_p4_2_acceptance.sh              # tier 1 only (hermetic)
#   run_slet_p4_2_acceptance.sh --live       # tier 1 + tier 2 against kind-osramp
#   run_slet_p4_2_acceptance.sh --iterations 10 [--live]
#   run_slet_p4_2_acceptance.sh --evidence-dir DIR   # keep metrics + transcripts
#
# Tier 2 needs an OpenBao token. It is taken from BAO_TOKEN if set; otherwise
# it is read at runtime from the OpenBao Deployment, and ONLY if that server is
# running in -dev mode (the kind demo cluster). It is never printed or written.
# ==============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$(cd "${here}/../../d2-signalloom/apps/fe-signalloom/src" && pwd)"
context="${SLET_KUBE_CONTEXT:-kind-osramp}"
bao_ns="${SLET_BAO_NAMESPACE:-inf-bao}"
live=0
iterations=1
evidence_dir=""

usage() { sed -n '4,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --live) live=1 ;;
    --iterations) iterations="${2:?}"; shift ;;
    --evidence-dir) evidence_dir="${2:?}"; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
  shift
done

if [[ "${live}" == 1 && -z "${BAO_TOKEN:-}" ]]; then
  args="$(kubectl --context "${context}" -n "${bao_ns}" get deploy openbao \
    -o jsonpath='{.spec.template.spec.containers[0].args}')"
  if [[ "${args}" != *'"-dev"'* ]]; then
    echo "refusing: OpenBao in ${context}/${bao_ns} is not a -dev server; export BAO_TOKEN yourself" >&2
    exit 3
  fi
  BAO_TOKEN="$(kubectl --context "${context}" -n "${bao_ns}" get deploy openbao \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="BAO_DEV_ROOT_TOKEN_ID")].value}')"
  [[ -n "${BAO_TOKEN}" ]] || { echo "could not discover the dev token" >&2; exit 3; }
  export BAO_TOKEN
fi
[[ "${live}" == 1 ]] && export SLET_LIVE_CLUSTER=1

export UV_CACHE_DIR="${UV_CACHE_DIR:-${TMPDIR:-/tmp}/slet-uv-cache}"
[[ -n "${evidence_dir}" ]] && mkdir -p "${evidence_dir}"

fail=0
for ((i = 1; i <= iterations; i++)); do
  if [[ -n "${evidence_dir}" ]]; then
    export SLET_METRICS_PATH="${evidence_dir}/metrics-${i}.json"
    export SLET_TRANSCRIPT_PATH="${evidence_dir}/transcript-${i}.jsonl"
  fi
  echo "=== SLET-P4-2 iteration ${i}/${iterations} (live=${live}) ==="
  if ! (cd "${src}" && uv run -q --python 3.12 --with pytest --with pytest-asyncio \
      --with-requirements requirements.txt python -m pytest \
      tests/test_kurasi_tenant_isolation.py -v -p no:cacheprovider -rs); then
    fail=$((fail + 1))
  fi
done

echo "=== SLET-P4-2: ${iterations} iteration(s), ${fail} failed ==="
[[ "${fail}" == 0 ]]
