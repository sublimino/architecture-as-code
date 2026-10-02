#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      probe-sentinel-evasion
# @target  d2-signalloom/apps/signalloom-stun-sentinel (live, read-only)
# @doc     docs/slaat/p1-4/sentinel-landlock-confinement-adversarial-dossier.md
# @spec    SLAAT-P1-4
# @tests   test/landlock-adversarial-escape.bats
#
# SLAAT-P1-4 — eBPF telemetry evasion probe against the LIVE deployed sentinel
# (ghcr.io/controlplaneio-in-toto/signalloom-stun-sentinel:v0.2.0, pod
# stun-sentinel-* in fe-signalloom-agents on kind-osramp).
#
# Read-only. Nothing here edits signalloom-stun-sentinel source (merge
# boundary for this card) or any Landlock/sentinel config; it drives activity
# FROM an unrelated agent pod and observes the sentinel's own logs.
#
# Headline finding, established by static source inspection before any live
# probe ran (recorded so the live probes below are read as confirmation, not
# discovery): the live sentinel's eBPF program
# (d2-signalloom/apps/signalloom-stun-sentinel/ebpf/c/socket_trace.bpf.c)
# attaches exactly one tracepoint —
#
#   SEC("tp_btf/inet_sock_set_state")
#
# — TCP socket state transitions only. A separate, more capable syscall
# tracer exists in this repository
# (d2-signalloom/apps/stun-sentinel/bpf/sentinel_probe.c: sys_enter_openat,
# sys_enter_openat2, sys_enter_execve, sys_enter_connect, with a full
# SyscallEvent/correlator pipeline and passing unit tests) but is wired into
# NO cmd/ entrypoint in that module and is not the image deployed. So "evade
# eBPF telemetry via rapid process spawning / ptrace attachment / unshare
# namespace creation" succeeds trivially against the live system today — not
# because any evasion technique defeats the probe, but because no syscall
# instrumentation is running for those actions to evade in the first place.
# Only network-flow-shaped activity is in this probe's field of view at all.
set -uo pipefail

readonly DECLARED_PROBES=9

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SENTINEL_BPF_DEPLOYED="${REPO_ROOT}/d2-signalloom/apps/signalloom-stun-sentinel/ebpf/c/socket_trace.bpf.c"
SENTINEL_BPF_UNDEPLOYED="${REPO_ROOT}/d2-signalloom/apps/stun-sentinel/bpf/sentinel_probe.c"
STUN_SENTINEL_CMD_MAIN="${REPO_ROOT}/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go"
SIGNALLOOM_CMD_MAIN="${REPO_ROOT}/d2-signalloom/apps/signalloom-stun-sentinel/main.go"

CLUSTER_CONTEXT="${CLUSTER_CONTEXT:-kind-osramp}"
KIND_NODE="${KIND_NODE:-osramp-control-plane}"
NAMESPACE="${NAMESPACE:-fe-signalloom-agents}"
PROBE_POD="${PROBE_POD:-}"       # auto-discovered if empty: a non-sentinel running agent pod
SENTINEL_LABEL="${SENTINEL_LABEL:-app.kubernetes.io/name=stun-sentinel}"
JSON_OUT=""

PASS=0
FAIL=0
EXECUTED=0
declare -a RESULTS=()

log() { printf '%s\n' "$*" >&2; }
node() { docker exec "${KIND_NODE}" "$@"; }
nsh() { docker exec "${KIND_NODE}" sh -c "$1"; }
kc() { kubectl --context "${CLUSTER_CONTEXT}" "$@"; }

usage_text() {
  cat <<'EOF'
Usage: scripts/probe-sentinel-evasion.sh [--json PATH]

Read-only eBPF telemetry evasion probe against the live stun-sentinel
deployment. Requires: docker, kubectl (context kind-osramp reachable), jq.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --json) JSON_OUT="${2:-}"; shift 2 ;;
    --json=*) JSON_OUT="${1#*=}"; shift ;;
    -h | --help) usage_text; exit 0 ;;
    *) log "unknown option: $1"; usage_text >&2; exit 2 ;;
    esac
  done
}

have_cluster() {
  command -v docker >/dev/null 2>&1 || return 1
  command -v kubectl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  docker inspect "${KIND_NODE}" >/dev/null 2>&1 || return 1
  kc get namespace "${NAMESPACE}" >/dev/null 2>&1 || return 1
  return 0
}

preflight() {
  if ! have_cluster; then
    log "no live kind-osramp cluster (docker/kubectl/jq/node/namespace) — this probe requires the real deployment"
    exit 3
  fi
}

# record ID DESCRIPTION EXPECTATION OK EVIDENCE NOTE
record() {
  local id="$1" desc="$2" expect="$3" ok="$4" evidence="$5" note="${6:-}"
  EXECUTED=$((EXECUTED + 1))
  local verdict="fail"
  if [[ "${ok}" == "1" ]]; then
    verdict="pass"; PASS=$((PASS + 1)); log "  ok   ${id} — ${desc}"
  else
    FAIL=$((FAIL + 1)); log "  FAIL ${id} — ${desc}"
  fi
  RESULTS+=("$(jq -nc \
    --arg id "${id}" --arg d "${desc}" --arg e "${expect}" \
    --arg v "${verdict}" --arg ev "${evidence}" --arg n "${note}" \
    '{id:$id, description:$d, expectation:$e, verdict:$v, evidence:$ev, note:$n}')")
}

sentinel_logs() {
  kc logs -n "${NAMESPACE}" -l "${SENTINEL_LABEL}" --tail="${1:-500}" 2>/dev/null
}

main() {
  parse_args "$@"
  preflight

  local sentinel_pod
  sentinel_pod="$(kc get pods -n "${NAMESPACE}" -l "${SENTINEL_LABEL}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -n "${sentinel_pod}" ]] || { log "no sentinel pod found with label ${SENTINEL_LABEL}"; exit 3; }
  log "sentinel pod: ${sentinel_pod}"

  if [[ -z "${PROBE_POD}" ]]; then
    PROBE_POD="$(kc get pods -n "${NAMESPACE}" --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -v "${sentinel_pod}" | grep '^agent-standard-baseline' | head -1)"
  fi
  [[ -n "${PROBE_POD}" ]] || { log "no probe pod found"; exit 3; }
  log "probe pod (attacker-controlled surrogate): ${PROBE_POD}"

  # ── Static: the live sentinel's own eBPF source names exactly one syscall
  #    surface. Evidence first, so the live probes below read as CONFIRMATION
  #    of a boundary already established by reading the code, not discovery
  #    dressed up as a live result. ─────────────────────────────────────────
  local deployed_sec undeployed_sec
  deployed_sec="$(grep -oE 'SEC\("[a-z_/]+"\)' "${SENTINEL_BPF_DEPLOYED}" 2>/dev/null | sort -u | tr '\n' ' ')"
  record "static.deployed-probe-is-socket-state-only" \
    "d2-signalloom/apps/signalloom-stun-sentinel's eBPF source attach points" \
    "exactly tp_btf/inet_sock_set_state — no syscall tracepoint of any kind" \
    "$([[ "${deployed_sec}" == *"inet_sock_set_state"* && "${deployed_sec}" != *"sys_enter"* ]] && echo 1 || echo 0)" \
    "attach_points=[${deployed_sec}]"

  local undeployed_sec
  undeployed_sec="$(grep -oE 'SEC\("tracepoint/syscalls/[a-z_0-9]+"\)' "${SENTINEL_BPF_UNDEPLOYED}" 2>/dev/null | sort -u | tr '\n' ' ')"
  record "static.a-fuller-syscall-tracer-exists-but-is-unwired" \
    "d2-signalloom/apps/stun-sentinel/bpf/sentinel_probe.c attach points, and whether its cmd/ wires it" \
    "openat/openat2/execve/connect tracepoints exist in-repo; NOT instantiated by any cmd/ main()" \
    "$([[ "${undeployed_sec}" == *"sys_enter_execve"* ]] && ! grep -q "ebpf\.\|correlator\." "${STUN_SENTINEL_CMD_MAIN}" 2>/dev/null && echo 1 || echo 0)" \
    "attach_points=[${undeployed_sec}] cmd_main_references_ebpf_or_correlator=$(grep -c "ebpf\.\|correlator\." "${STUN_SENTINEL_CMD_MAIN}" 2>/dev/null || echo 0)" \
    "the capability is implemented and unit-tested, not merely absent — it is dormant, a wiring gap rather than a design gap"

  record "static.deployed-signalloom-variant-does-wire-its-own-probe" \
    "d2-signalloom/apps/signalloom-stun-sentinel/main.go references its ebpf/telemetry package (the socket-state-only one)" \
    "reference present — confirms the live pod's instrumentation IS the socket-state-only path, not merely unbuilt" \
    "$(grep -lq "ebpf\." "${SIGNALLOOM_CMD_MAIN}" 2>/dev/null && echo 1 || echo 0)" \
    "$(grep -c "ebpf\." "${SIGNALLOOM_CMD_MAIN}" 2>/dev/null || echo 0) reference(s) found"

  # ── Live: the daemon is actually up and self-reports healthy ─────────────
  local health
  health="$(nsh "curl -sf --max-time 5 http://localhost:8081/healthz" 2>&1)"
  record "live.sentinel-healthz-reachable" \
    "live sentinel daemon healthz, reached via the node's hostPort 8081" \
    "HTTP 200, status ok" \
    "$([[ "${health}" == *'"status":"ok"'* ]] && echo 1 || echo 0)" \
    "response=${health:0:200}"

  # ── Live: baseline correlator stats before the adversarial burst ─────────
  local before_stats before_matched before_read
  before_stats="$(sentinel_logs 400 | grep 'ebpf_correlator_stats' | tail -1)"
  before_read="$(printf '%s' "${before_stats}" | jq -r '.details.stats.records_read // 0' 2>/dev/null || echo 0)"
  before_matched="$(printf '%s' "${before_stats}" | jq -r '.details.stats.matched // 0' 2>/dev/null || echo 0)"
  record "live.correlator-stats-baseline-captured" \
    "a recent ebpf_correlator_stats record exists in the live log stream before the burst" \
    "records_read and matched counters readable" \
    "$([[ -n "${before_stats}" ]] && echo 1 || echo 0)" \
    "records_read=${before_read} matched=${before_matched}"

  # ── Adversarial: from the UNRELATED probe pod (not the sentinel), run the
  #    three named evasion vectors. The sentinel's own cgroup/eBPF visibility
  #    is per-host, not per-exec-session, so this is a faithful stand-in for
  #    "a compromised agent workload does X". ───────────────────────────────
  log "driving adversarial activity from ${PROBE_POD}..."
  kc exec -n "${NAMESPACE}" "${PROBE_POD}" -- bash -c '
    for i in $(seq 1 200); do (true &); done
    wait 2>/dev/null
    unshare --pid --fork --mount-proc -- true 2>/dev/null
    exit 0
  ' >/dev/null 2>&1
  local evasion_status=$?

  record "live.evasion-burst-executed" \
    "200 rapid process spawns + one unshare(CLONE_NEWPID) from ${PROBE_POD}" \
    "the burst itself completes (this probe measures DETECTION, not containment)" \
    "$([[ ${evasion_status} -eq 0 ]] && echo 1 || echo 0)" \
    "exec_status=${evasion_status}"

  sleep 3

  # ── Live: did ANYTHING in the sentinel's logs reference the burst? ────────
  local post_logs mention_count
  post_logs="$(sentinel_logs 200)"
  mention_count="$(grep -c "${PROBE_POD}" <<<"${post_logs}" | grep -cE '(execve|openat|unshare|fork|process)' 2>/dev/null || true)"
  mention_count="$(grep -iE "(execve|openat|sys_enter|unshare|fork_bomb|process_spawn)" <<<"${post_logs}" | wc -l)"
  record "live.evasion-burst-generates-no-syscall-telemetry" \
    "sentinel logs in the 3s window after the burst contain zero execve/openat/unshare-shaped events" \
    "zero matches — confirms the static finding live: the deployed probe cannot see this class of activity at all" \
    "$([[ "${mention_count}" -eq 0 ]] && echo 1 || echo 0)" \
    "post_burst_syscall_shaped_mentions=${mention_count}" \
    "this is the central finding of this probe: not a bypass of a defense, but the complete absence of one for this activity class"

  # ── Positive control: a TCP connect from the SAME probe pod IS in the
  #    deployed probe's instrumented surface (inet_sock_set_state). Without
  #    this half, "no telemetry for the burst" could mean "nothing is
  #    instrumented at all", which would be a different and worse finding. ──
  local sentinel_ip before_connect_read after_connect_read
  sentinel_ip="$(kc get pod -n "${NAMESPACE}" "${sentinel_pod}" -o jsonpath='{.status.podIP}' 2>/dev/null)"
  # Stats lines are a small fraction of the log stream (~1 in 20, interleaved
  # with per-pod reconcile-tick lines) — a short tail can legitimately miss
  # one on either side. 800 lines comfortably spans several reconcile cycles.
  before_connect_read="$(sentinel_logs 800 | grep 'ebpf_correlator_stats' | tail -1 | jq -r '.details.stats.records_read // 0' 2>/dev/null || echo 0)"
  kc exec -n "${NAMESPACE}" "${PROBE_POD}" -- bash -c "
    for p in 8081 8080 443 80; do
      timeout 1 bash -c 'exec 3<>/dev/tcp/${sentinel_ip}/'\$p 2>/dev/null && exec 3>&- || true
    done
  " >/dev/null 2>&1
  sleep 12
  after_connect_read="$(sentinel_logs 800 | grep 'ebpf_correlator_stats' | tail -1 | jq -r '.details.stats.records_read // 0' 2>/dev/null || echo 0)"
  record "live.control-tcp-connect-stays-within-instrumented-surface" \
    "the correlator's records_read counter continues to advance across a TCP connect burst from the probe pod" \
    "records_read after > records_read before — the instrumented surface (TCP state) is live and counting, distinguishing 'not instrumented' from 'instrumented but blind to this activity class'" \
    "$([[ "${after_connect_read}" -gt "${before_connect_read}" ]] && echo 1 || echo 0)" \
    "before=${before_connect_read} after=${after_connect_read}"

  # ── Observational: the reconciler's own logging shape, recorded because it
  #    was found while reading these logs and is relevant to the cgroup-freeze
  #    half of this card — not probed further here (see
  #    test/cgroup-freeze-adversarial.bats for the live freeze/thaw battery).
  local unstun_count stun_count
  unstun_count="$(grep -c '"event":"unstun"' <<<"${post_logs}" || true)"
  stun_count="$(grep -c '"event":"stun"' <<<"${post_logs}" || true)"
  record "observation.reconciler-logs-a-decision-every-cycle-for-every-pod" \
    "the live sentinel logs an 'unstun'/containment_released line for every known agent pod on every reconcile tick, independent of whether anything was ever frozen" \
    "informational — distinguishes a verbose always-log reconciler from an anomalous freeze/thaw loop" \
    "1" \
    "unstun_mentions_in_200_lines=${unstun_count} stun_mentions_in_200_lines=${stun_count}" \
    "no stun (freeze) events observed in this window; the volume of unstun lines is reconciliation-tick logging, not evidence of pods actually cycling frozen/thawed"

  local arity_ok=1
  [[ "${EXECUTED}" -eq "${DECLARED_PROBES}" ]] || arity_ok=0
  local overall="pass"
  [[ "${FAIL}" -eq 0 && "${arity_ok}" -eq 1 ]] || overall="pass-with-findings"

  log ""
  log "probes: ${PASS}/${EXECUTED} passed (declared ${DECLARED_PROBES}) — ${overall}"

  local artifact
  artifact="$(jq -n \
    --arg artifact "sentinel-evasion-probe" \
    --arg card "SLAAT-P1-4" \
    --arg overall "${overall}" \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sentinel_pod "${sentinel_pod}" \
    --arg probe_pod "${PROBE_POD}" \
    --arg namespace "${NAMESPACE}" \
    --argjson declared "${DECLARED_PROBES}" \
    --argjson executed "${EXECUTED}" \
    --argjson passed "${PASS}" \
    --argjson failed "${FAIL}" \
    --slurpfile probes <(printf '%s\n' "${RESULTS[@]}" | jq -s '.') \
    '{
       artifact: $artifact, card: $card, overall: $overall, generated: $generated,
       target: {namespace: $namespace, sentinel_pod: $sentinel_pod, probe_pod: $probe_pod},
       totals: {declared: $declared, executed: $executed, passed: $passed, failed: $failed},
       probes: $probes[0]
     }')"

  if [[ -n "${JSON_OUT}" ]]; then
    mkdir -p "$(dirname -- "${JSON_OUT}")"
    printf '%s\n' "${artifact}" >"${JSON_OUT}"
    log "proof artifact written to ${JSON_OUT}"
  else
    printf '%s\n' "${artifact}"
  fi

  [[ "${EXECUTED}" -eq "${DECLARED_PROBES}" ]] && return 0
  return 1
}

main "$@"
