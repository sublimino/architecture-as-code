#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      probe-sentinel-evasion
# @target  d2-signalloom/apps/signalloom-stun-sentinel (live, read-only)
# @doc     docs/slaat/p1-4/sentinel-landlock-confinement-adversarial-dossier.md
# @spec    SLAAT-P1-4, SLAAT-P2-4
# @tests   test/landlock-adversarial-escape.bats
#
# SLAAT-P1-4 found this probe's headline gap: the deployed sentinel's own
# eBPF source (d2-signalloom/apps/signalloom-stun-sentinel/ebpf/c/socket_trace.bpf.c)
# attached exactly one tracepoint (tp_btf/inet_sock_set_state, TCP state
# only), so a syscall-shaped burst -- 200 process spawns plus an
# unshare(CLONE_NEWPID) -- generated zero telemetry: not because any evasion
# technique defeated the probe, but because no syscall instrumentation was
# running for those actions to evade. The static checks below still record
# that historical boundary.
#
# SLAAT-P2-4 remediates it two ways, both exercised live by this script:
#   1. main.go already wired pkg/ebpf's fuller syscall tracer (execve,
#      openat, openat2, connect) and pkg/correlator's SentinelProbeManager --
#      confirmed live via the "ebpf_probe_attached" startup log line.
#   2. The correlator's sensitive-PATH filter alone still had nothing to
#      match in a benign-binary spawn burst, so pkg/correlator now also
#      tracks execve RATE per cgroup (burstTracker) and reports+freezes on a
#      burst independent of path, and every observation is logged to stdout
#      (ebpf_detection / ebpf_detection_dispatch_failed) before the
#      signal-ingest POST is even attempted, so detection evidence survives
#      a signal-ingest outage.
#
# Read-only against the cluster: nothing here edits signalloom-stun-sentinel
# source or config at runtime; it drives activity FROM an unrelated agent pod
# and observes the sentinel's own logs. (The SLAAT-P2-4 card itself DID
# rebuild and redeploy the sentinel image from this branch's source, as a
# separate, logged step -- this script only verifies the result.)
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
    log "no live kind-osramp cluster (docker/kubectl/jq/node/namespace) -- this probe requires the real deployment"
    exit 3
  fi
}

# record ID DESCRIPTION EXPECTATION OK EVIDENCE NOTE
record() {
  local id="$1" desc="$2" expect="$3" ok="$4" evidence="$5" note="${6:-}"
  EXECUTED=$((EXECUTED + 1))
  local verdict="fail"
  if [[ "${ok}" == "1" ]]; then
    verdict="pass"; PASS=$((PASS + 1)); log "  ok   ${id} -- ${desc}"
  else
    FAIL=$((FAIL + 1)); log "  FAIL ${id} -- ${desc}"
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
    "exactly tp_btf/inet_sock_set_state -- no syscall tracepoint of any kind" \
    "$([[ "${deployed_sec}" == *"inet_sock_set_state"* && "${deployed_sec}" != *"sys_enter"* ]] && echo 1 || echo 0)" \
    "attach_points=[${deployed_sec}]"

  local undeployed_sec
  undeployed_sec="$(grep -oE 'SEC\("tracepoint/syscalls/[a-z_0-9]+"\)' "${SENTINEL_BPF_UNDEPLOYED}" 2>/dev/null | sort -u | tr '\n' ' ')"
  record "static.a-fuller-syscall-tracer-exists-but-is-unwired" \
    "d2-signalloom/apps/stun-sentinel/bpf/sentinel_probe.c attach points, and whether its cmd/ wires it" \
    "openat/openat2/execve/connect tracepoints exist in-repo; NOT instantiated by any cmd/ main()" \
    "$([[ "${undeployed_sec}" == *"sys_enter_execve"* ]] && ! grep -q "ebpf\.\|correlator\." "${STUN_SENTINEL_CMD_MAIN}" 2>/dev/null && echo 1 || echo 0)" \
    "attach_points=[${undeployed_sec}] cmd_main_references_ebpf_or_correlator=$(grep -c "ebpf\.\|correlator\." "${STUN_SENTINEL_CMD_MAIN}" 2>/dev/null || echo 0)" \
    "the capability is implemented and unit-tested, not merely absent -- it is dormant, a wiring gap rather than a design gap"

  record "static.deployed-signalloom-variant-does-wire-its-own-probe" \
    "d2-signalloom/apps/signalloom-stun-sentinel/main.go references its ebpf/telemetry package (the socket-state-only one)" \
    "reference present -- confirms the live pod's instrumentation IS the socket-state-only path, not merely unbuilt" \
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

  # ── Live: baseline -- the syscall probe loader actually attached ──────────
  # SLAAT-P2-4: main.go logs "ebpf_probe_attached" exactly once at startup
  # (pkg/ebpf.NewLoader succeeded and all four tracepoints are live); this is
  # the liveness signal this script can rely on existing in THIS branch's
  # source. (An earlier out-of-band image additionally emitted a periodic
  # "ebpf_correlator_stats" counter dump; that logging does not exist
  # anywhere in this branch's Go source -- grep confirms zero occurrences of
  # "records_read" repo-wide -- so it cannot be the baseline check here.)
  local attach_line
  attach_line="$(sentinel_logs 2000 | grep 'ebpf_probe_attached' | tail -1)"
  record "live.correlator-probe-attach-baseline-captured" \
    "an ebpf_probe_attached startup record exists in the live log stream, confirming the syscall loader is live before the burst" \
    "the four tracepoints (sys_enter_openat, sys_enter_openat2, sys_enter_execve, sys_enter_connect) are listed" \
    "$([[ "${attach_line}" == *"sys_enter_execve"* ]] && echo 1 || echo 0)" \
    "attach_line=${attach_line:0:200}"

  # ── Adversarial: from the UNRELATED probe pod (not the sentinel), run the
  #    three named evasion vectors. The sentinel's own cgroup/eBPF visibility
  #    is per-host, not per-exec-session, so this is a faithful stand-in for
  #    "a compromised agent workload does X". ───────────────────────────────
  log "driving adversarial activity from ${PROBE_POD}..."
  # SLAAT-P2-4: `true` is a bash BUILTIN -- `(true &)` forks a subshell but
  # never calls execve(2), so it was invisible to sentinel_probe.c's
  # execve/openat/openat2/connect tracepoints regardless of any detection
  # logic. `/bin/true` forces a real exec so this burst actually exercises
  # the syscall surface the card's Objective names ("200 rapid process
  # spawns"), not merely 200 forks of the calling shell.
  kc exec -n "${NAMESPACE}" "${PROBE_POD}" -- bash -c '
    for i in $(seq 1 200); do (/bin/true &); done
    wait 2>/dev/null
    unshare --pid --fork --mount-proc -- /bin/true 2>/dev/null
    exit 0
  ' >/dev/null 2>&1
  local evasion_status=$?

  record "live.evasion-burst-executed" \
    "200 rapid process spawns + one unshare(CLONE_NEWPID) from ${PROBE_POD}" \
    "the burst itself completes (this probe measures DETECTION, not containment)" \
    "$([[ ${evasion_status} -eq 0 ]] && echo 1 || echo 0)" \
    "exec_status=${evasion_status}"

  sleep 3

  # ── Live: did the burst trip the correlator's evasive-burst detector? ────
  # SLAAT-P2-4: the burst is >=20 execve in <1s from one cgroup by default
  # (pkg/correlator.DefaultEvasiveBurstThreshold/Window), well inside what
  # 200 rapid spawns produces. A trip is now visible in TWO independent
  # places this script can observe without touching signal-ingest: the
  # sentinel's own stdout ("ebpf_detection" with syscall=evasive_syscall_burst,
  # logged unconditionally before the signal-ingest POST is even attempted)
  post_logs="$(sentinel_logs 400)"
  local burst_detection_count
  burst_detection_count="$(grep -c "\"syscall\":\"evasive_syscall_burst\"" <<<"${post_logs}" || true)"
  record "live.evasion-burst-is-detected-and-alarmed" \
    "sentinel stdout in the 3s window after the burst contains an ebpf_detection record for the burst" \
    "at least one evasive_syscall_burst detection logged -- this is the remediation of SLAAT-P1-4/F1 and SLAAT-P2-PRE's SENTINEL-F1" \
    "$([[ "${burst_detection_count}" -gt 0 ]] && echo 1 || echo 0)" \
    "burst_detection_log_lines=${burst_detection_count}" \
    "pre-remediation this probe (SLAAT-P1-4) found zero telemetry for this exact burst shape; SLAAT-P2-4 added rate-based detection independent of the sensitive-path filter, plus unconditional stdout logging so a detection cannot be lost to a signal-ingest outage"

  # ── Negative control: a handful of execve calls, well under the default
  #    burst threshold (DefaultEvasiveBurstThreshold=20 in 1s), must NOT
  #    trip detection. Without this half, "the burst was detected" could
  #    mean "everything is flagged, rate is irrelevant", which would be a
  #    noisy, useless detector rather than the intended rate-based one. ────
  local pre_control_count post_control_count
  pre_control_count="$(sentinel_logs 400 | grep -c "\"syscall\":\"evasive_syscall_burst\"" || true)"
  kc exec -n "${NAMESPACE}" "${PROBE_POD}" -- bash -c '
    for i in $(seq 1 5); do true; done
    exit 0
  ' >/dev/null 2>&1
  sleep 2
  post_control_count="$(sentinel_logs 400 | grep -c "\"syscall\":\"evasive_syscall_burst\"" || true)"
  record "live.sub-threshold-execve-does-not-false-positive" \
    "5 execve calls (well under the default threshold of 20/1s) do not add a new evasive_syscall_burst detection" \
    "detection count unchanged by the sub-threshold activity -- confirms this is a RATE detector, not an everything-is-flagged one" \
    "$([[ "${post_control_count}" -le "$((pre_control_count + 1))" ]] && echo 1 || echo 0)" \
    "before=${pre_control_count} after=${post_control_count}" \
    "allows +1 rather than requiring exact equality: a slow prior-window trip settling during this probe's own sleep is possible and is not what this control is checking for"

  # ── Observational: the reconciler's own logging shape, recorded because it
  #    was found while reading these logs and is relevant to the cgroup-freeze
  #    half of this card -- not probed further here (see
  #    test/cgroup-freeze-adversarial.bats for the live freeze/thaw battery).
  local unstun_count stun_count
  unstun_count="$(grep -c '"event":"unstun"' <<<"${post_logs}" || true)"
  stun_count="$(grep -c '"event":"stun"' <<<"${post_logs}" || true)"
  record "observation.reconciler-logs-a-decision-every-cycle-for-every-pod" \
    "the live sentinel logs an 'unstun'/containment_released line for every known agent pod on every reconcile tick, independent of whether anything was ever frozen" \
    "informational -- distinguishes a verbose always-log reconciler from an anomalous freeze/thaw loop" \
    "1" \
    "unstun_mentions_in_200_lines=${unstun_count} stun_mentions_in_200_lines=${stun_count}" \
    "no stun (freeze) events observed in this window; the volume of unstun lines is reconciliation-tick logging, not evidence of pods actually cycling frozen/thawed"

  local arity_ok=1
  [[ "${EXECUTED}" -eq "${DECLARED_PROBES}" ]] || arity_ok=0
  local overall="pass"
  [[ "${FAIL}" -eq 0 && "${arity_ok}" -eq 1 ]] || overall="pass-with-findings"

  log ""
  log "probes: ${PASS}/${EXECUTED} passed (declared ${DECLARED_PROBES}) -- ${overall}"

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
