#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      bench-cgroup-freezer
# @doc     docs/signalloom/cgroup-v2-freeze-architecture.md
# @target  d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go
#
# CRKC-P1-2 freeze-latency benchmark.
#
# Measures the freeze→`frozen 1` transition across N iterations against a real
# cgroup on the Kind node, under load, and reports p50/p90/p99/max.
#
# What is being measured, precisely: the interval from the start of the write
# to cgroup.freeze until the first read of cgroup.events that reports
# `frozen 1`. That is the containment latency an operator cares about. It is
# NOT the duration of the write syscall — a benchmark that timed only the
# write would report a figure that says nothing about whether anything
# actually stopped.
#
# Each iteration thaws before it freezes, so every measurement is a genuine
# 0→1 transition. Freezing an already-frozen cgroup settles instantly and
# would flatter the numbers into meaninglessness.
#
# No `set -e`: see the note in scripts/test-cgroup-freezer.sh.
set -uo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly MODULE_DIR="${REPO_ROOT}/d2-signalloom/apps/stun-sentinel"

CLUSTER_CONTEXT="${CLUSTER_CONTEXT:-kind-osramp}"
KIND_NODE="${KIND_NODE:-osramp-control-plane}"
NAMESPACE="${NAMESPACE:-crkc-freeze-bench}"
POD="${POD:-crkc-bench-burner}"
BURNER_IMAGE="${BURNER_IMAGE:-docker.io/library/busybox:1.36}"
# Worker processes inside the container. Multi-process is the interesting
# case: the kernel must settle every task in the subtree before cgroup.events
# reports frozen 1.
WORKERS="${WORKERS:-8}"
ITERATIONS="${ITERATIONS:-100}"
# p99 budget from the CRKC-P1-2 card.
P99_BUDGET_MS="${P99_BUDGET_MS:-25}"
JSON_OUT="${JSON_OUT:-}"
KEEP="${KEEP:-0}"

log() { printf '%s\n' "$*" >&2; }
nsh() { docker exec "${KIND_NODE}" sh -c "$1"; }

usage_text() {
  cat <<'EOF'
Usage: test/bench-cgroup-freezer.sh [options]

  --iterations N   number of freeze/thaw cycles (default 100)
  --workers N      CPU-burning processes in the target container (default 8)
  --json PATH      write the JSON benchmark report to PATH
  --keep           leave the benchmark namespace in place afterwards
  -h, --help       this text
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iterations) ITERATIONS="${2:-100}"; shift 2 ;;
      --iterations=*) ITERATIONS="${1#*=}"; shift ;;
      --workers) WORKERS="${2:-8}"; shift 2 ;;
      --workers=*) WORKERS="${1#*=}"; shift ;;
      --json) JSON_OUT="${2:-}"; shift 2 ;;
      --json=*) JSON_OUT="${1#*=}"; shift ;;
      --keep) KEEP=1; shift ;;
      -h|--help) usage_text; exit 0 ;;
      *) log "unknown option: $1"; usage_text >&2; exit 2 ;;
    esac
  done
}

preflight() {
  local missing=0
  for bin in docker kubectl jq go; do
    command -v "${bin}" >/dev/null 2>&1 || { log "missing required tool: ${bin}"; missing=1; }
  done
  [[ "${missing}" == "0" ]] || exit 3
  docker inspect "${KIND_NODE}" >/dev/null 2>&1 || {
    log "Kind node container '${KIND_NODE}' is not running"; exit 3; }
}

start_burner() {
  kubectl --context "${CLUSTER_CONTEXT}" create namespace "${NAMESPACE}" >/dev/null 2>&1
  kubectl --context "${CLUSTER_CONTEXT}" delete pod "${POD}" -n "${NAMESPACE}" \
    --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1

  kubectl --context "${CLUSTER_CONTEXT}" apply -f - >/dev/null <<YAML || exit 6
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NAMESPACE}
  labels:
    app: ${POD}
    signalloom.ai/role: crkc-p1-2-bench-target
spec:
  terminationGracePeriodSeconds: 1
  containers:
    - name: burner
      image: ${BURNER_IMAGE}
      imagePullPolicy: IfNotPresent
      command:
        - /bin/sh
        - -c
        - "i=0; while [ \$i -lt ${WORKERS} ]; do (while :; do :; done) & i=\$((i+1)); done; wait"
YAML

  kubectl --context "${CLUSTER_CONTEXT}" wait --for=condition=Ready \
    "pod/${POD}" -n "${NAMESPACE}" --timeout=120s >/dev/null || exit 6
}

cleanup() {
  if [[ "${KEEP}" == "1" ]]; then
    log "--keep: leaving namespace ${NAMESPACE}"
    return 0
  fi
  kubectl --context "${CLUSTER_CONTEXT}" delete namespace "${NAMESPACE}" \
    --ignore-not-found --wait=false >/dev/null 2>&1
  return 0
}

main() {
  parse_args "$@"
  preflight
  start_burner
  trap cleanup EXIT

  local pod_uid cg
  pod_uid="$(kubectl --context "${CLUSTER_CONTEXT}" get pod "${POD}" -n "${NAMESPACE}" \
              -o jsonpath='{.metadata.uid}')"
  cg="$(nsh "find /sys/fs/cgroup -maxdepth 6 -type d -name '*${pod_uid//-/_}*' 2>/dev/null | head -1")"
  if [[ -z "${cg}" ]]; then
    log "could not resolve a cgroup for pod uid ${pod_uid}"
    exit 7
  fi
  log "target cgroup: ${cg}"

  local nproc_in_cgroup
  nproc_in_cgroup="$(nsh "cat ${cg}/*/cgroup.procs 2>/dev/null | wc -l")"
  log "processes in subtree: ${nproc_in_cgroup}, iterations: ${ITERATIONS}"

  # The measurement loop runs entirely inside the node, in one shell. Driving
  # it from the host would fold ~20ms of `docker exec` startup into every
  # sample and drown the signal being measured.
  #
  # busybox date supports %s%N, giving nanosecond resolution.
  local samples
  samples="$(nsh "
    CG='${cg}'
    i=0
    while [ \$i -lt ${ITERATIONS} ]; do
      # Ensure a genuine 0->1 transition for every sample.
      echo 0 > \"\$CG/cgroup.freeze\"
      while grep -q '^frozen 1' \"\$CG/cgroup.events\"; do :; done

      start=\$(date +%s%N)
      echo 1 > \"\$CG/cgroup.freeze\"
      while ! grep -q '^frozen 1' \"\$CG/cgroup.events\"; do :; done
      end=\$(date +%s%N)

      echo \$(( (end - start) / 1000 ))
      i=\$((i+1))
    done
    echo 0 > \"\$CG/cgroup.freeze\"
  ")"

  local count
  count="$(printf '%s\n' "${samples}" | grep -c '^[0-9]\+$')"
  if [[ "${count}" -ne "${ITERATIONS}" ]]; then
    log "ARITY FAILURE: collected ${count} samples, expected ${ITERATIONS}"
    log "a benchmark that silently measures fewer iterations than it claims is worse than none"
    exit 8
  fi

  # Percentiles over microsecond samples, reported in milliseconds.
  #
  # The awk function is declared at top level. A `function` defined inside an
  # END block is a syntax error: awk then writes to stderr and produces NO
  # stdout, `read` assigns empty strings, and every downstream numeric
  # comparison treats "" as 0 — which renders as a flawless "p99 0.0000 ms —
  # pass". A benchmark that failed to measure anything is the one result that
  # must never read as success, hence the parse gate below.
  local stats
  stats="$(printf '%s\n' "${samples}" | grep '^[0-9]\+$' | sort -n | awk -v n="${count}" '
    # Nearest-rank percentile: the smallest value at or above which p% of
    # samples fall. No interpolation, so every reported figure is a real
    # observation rather than an average of two.
    function pct(p,   i) { i = int(p * n + 0.999999); if (i < 1) i = 1; if (i > n) i = n; return v[i] }
    { v[NR] = $1; sum += $1 }
    END { printf "%d %d %d %d %d %.3f\n", v[1], pct(0.50), pct(0.90), pct(0.99), v[n], sum / n }')"

  read -r min p50 p90 p99 max mean <<<"${stats:-}"

  # Parse gate. Without this, an awk failure is indistinguishable from a
  # perfect run: empty values compare as zero and the budget check passes.
  local field
  for field in "${min:-}" "${p50:-}" "${p90:-}" "${p99:-}" "${max:-}" "${mean:-}"; do
    if [[ ! "${field}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      log "STATS PARSE FAILURE: percentile computation produced '${field}' (stats='${stats}')"
      log "refusing to report a verdict from unparsed measurements"
      exit 9
    fi
  done
  # A freeze that measured as exactly zero microseconds across every
  # percentile means the clock or the loop did not run, not that the kernel
  # is infinitely fast.
  if [[ "${max}" -eq 0 ]]; then
    log "STATS SANITY FAILURE: max latency is 0us across ${count} samples — the measurement loop did not run"
    exit 9
  fi

  local p99_ms
  p99_ms="$(awk -v u="${p99}" 'BEGIN{printf "%.4f", u/1000}')"

  local verdict="pass"
  awk -v p="${p99_ms}" -v b="${P99_BUDGET_MS}" 'BEGIN{exit !(p < b)}' || verdict="fail"

  log ""
  log "freeze latency over ${count} iterations (${nproc_in_cgroup} processes in subtree)"
  log "  min  $(awk -v u=${min} 'BEGIN{printf "%.4f", u/1000}') ms"
  log "  p50  $(awk -v u=${p50} 'BEGIN{printf "%.4f", u/1000}') ms"
  log "  p90  $(awk -v u=${p90} 'BEGIN{printf "%.4f", u/1000}') ms"
  log "  p99  ${p99_ms} ms   (budget ${P99_BUDGET_MS} ms) — ${verdict}"
  log "  max  $(awk -v u=${max} 'BEGIN{printf "%.4f", u/1000}') ms"
  log "  mean $(awk -v u=${mean} 'BEGIN{printf "%.4f", u/1000}') ms"

  local report
  report="$(jq -n \
    --arg card "CRKC-P1-2" \
    --arg verdict "${verdict}" \
    --arg kernel "$(uname -r)" \
    --arg cg "${cg}" \
    --argjson iterations "${count}" \
    --argjson procs "${nproc_in_cgroup}" \
    --argjson budget "${P99_BUDGET_MS}" \
    --argjson min "${min}" --argjson p50 "${p50}" --argjson p90 "${p90}" \
    --argjson p99 "${p99}" --argjson max "${max}" --argjson mean "${mean}" \
    '{
       card: $card,
       benchmark: "test/bench-cgroup-freezer.sh",
       measures: "interval from write(cgroup.freeze,1) until cgroup.events reports frozen 1",
       verdict: $verdict,
       environment: {kernel: $kernel, cgroup_path: $cg, processes_in_subtree: $procs},
       iterations: $iterations,
       p99_budget_ms: $budget,
       latency_ms: {
         min:  ($min  / 1000),
         p50:  ($p50  / 1000),
         p90:  ($p90  / 1000),
         p99:  ($p99  / 1000),
         max:  ($max  / 1000),
         mean: ($mean / 1000)
       },
       latency_usec: {min: $min, p50: $p50, p90: $p90, p99: $p99, max: $max, mean: $mean}
     }')"

  if [[ -n "${JSON_OUT}" ]]; then
    mkdir -p "$(dirname -- "${JSON_OUT}")"
    printf '%s\n' "${report}" > "${JSON_OUT}"
    log "benchmark report written to ${JSON_OUT}"
  else
    printf '%s\n' "${report}"
  fi

  [[ "${verdict}" == "pass" ]] && return 0
  return 1
}

main "$@"
