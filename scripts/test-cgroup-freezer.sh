#!/usr/bin/env bash
export GOPATH="${GOPATH:-/tmp/gopath}"
export GOCACHE="${GOCACHE:-/tmp/gocache}"
export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
export CGO_ENABLED=0
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      test-cgroup-freezer
# @doc     docs/signalloom/cgroup-v2-freeze-architecture.md
# @tests   test/cgroup-freeze-stun.bats
# @target  d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go
#
# CRKC-P1-2 live Tier 0 containment harness.
#
# Builds the real stun-sentinel binary, installs it on the Kind node, starts a
# CPU-burning pod, freezes it through the daemon's own /stun endpoint, and
# measures what actually happened at the kernel. Emits a JSON proof artifact.
#
# This exercises the shipped code path end to end. It deliberately does NOT
# reimplement freeze logic in shell — a shell reimplementation would prove that
# the shell works, not that the daemon does.
#
# Deliberately NOT using `set -e`:
#   errexit aborts at the first failing probe, so the harness would render a
#   verdict on the whole having measured only a prefix. It also makes `! cmd`
#   assertions dead and lets an EXIT trap's final command rewrite the exit
#   status. Every probe runs; the exit code is derived from the tally.
set -uo pipefail

# The number of probes this harness is contracted to run. A harness that
# silently runs zero probes exits 0 and is indistinguishable from one that
# passed, so the count is asserted rather than assumed.
readonly DECLARED_PROBES=12

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly MODULE_DIR="${REPO_ROOT}/d2-signalloom/apps/stun-sentinel"

CLUSTER_CONTEXT="${CLUSTER_CONTEXT:-kind-osramp}"
KIND_NODE="${KIND_NODE:-osramp-control-plane}"
NAMESPACE="${NAMESPACE:-crkc-freeze-test}"
POD="${POD:-crkc-cpu-burner}"
BURNER_IMAGE="${BURNER_IMAGE:-docker.io/library/busybox:1.36}"
DAEMON_ADDR="${DAEMON_ADDR:-127.0.0.1:18080}"
RESUME_TOKEN="${RESUME_TOKEN:-crkc-governor-token}"
# CPU sampling window. Long enough that a running busy-loop accumulates
# hundreds of milliseconds of usage, so "0" is unmistakably a halt and not a
# scheduling artefact.
SAMPLE_WINDOW="${SAMPLE_WINDOW:-0.5}"
JSON_OUT="${JSON_OUT:-}"
KEEP="${KEEP:-0}"

PASS=0
FAIL=0
EXECUTED=0
declare -a RESULTS=()

log()  { printf '%s\n' "$*" >&2; }
node() { docker exec "${KIND_NODE}" "$@"; }
nsh()  { docker exec "${KIND_NODE}" sh -c "$1"; }

# probe NAME CONDITION_DESCRIPTION ACTUAL EXPECTED_PREDICATE
record() {
  local name="$1" detail="$2" ok="$3"
  EXECUTED=$((EXECUTED + 1))
  if [[ "${ok}" == "1" ]]; then
    PASS=$((PASS + 1))
    log "  ok   ${name} — ${detail}"
    RESULTS+=("$(jq -nc --arg n "${name}" --arg d "${detail}" '{probe:$n,status:"pass",detail:$d}')")
  else
    FAIL=$((FAIL + 1))
    log "  FAIL ${name} — ${detail}"
    RESULTS+=("$(jq -nc --arg n "${name}" --arg d "${detail}" '{probe:$n,status:"fail",detail:$d}')")
  fi
}

usage_text() {
  cat <<'EOF'
Usage: scripts/test-cgroup-freezer.sh [options]

  --json PATH   write the JSON proof artifact to PATH
  --keep        leave the test namespace and daemon running afterwards
  -h, --help    this text

Environment overrides: CLUSTER_CONTEXT KIND_NODE NAMESPACE POD BURNER_IMAGE
                       DAEMON_ADDR RESUME_TOKEN SAMPLE_WINDOW
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
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

  if ! docker inspect "${KIND_NODE}" >/dev/null 2>&1; then
    log "Kind node container '${KIND_NODE}' is not running — cannot run the live harness."
    exit 3
  fi
  if ! nsh 'command -v curl >/dev/null'; then
    log "node '${KIND_NODE}' has no curl; the harness drives the daemon over HTTP from inside the node."
    exit 3
  fi
}

build_and_install() {
  log "building stun-sentinel (static)"
  # -buildvcs=false: `go build` inside a git worktree fails with
  # "error obtaining VCS status: exit status 128".
  ( cd "${MODULE_DIR}" && CGO_ENABLED=0 GOPATH="${GOPATH:-/tmp/gopath}" GOCACHE="${GOCACHE:-/tmp/gocache}" GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}" GOFLAGS=-buildvcs=false \
      go build -ldflags='-s -w' -o /tmp/stun-sentinel-live ./cmd/stun-sentinel ) || {
    log "build failed"; exit 4; }
  docker cp /tmp/stun-sentinel-live "${KIND_NODE}:/usr/local/bin/stun-sentinel" >/dev/null || exit 4
}

start_daemon() {
  # pkill -x (exact name) rather than pkill -f: a -f pattern would also match
  # the shell running this very command and kill it.
  nsh 'pkill -x stun-sentinel >/dev/null 2>&1; exit 0'
  sleep 0.3
  # setsid puts the daemon in its own session so it survives this exec, and
  # all three fds are redirected so it never writes back into our stream.
  # No `disown`: the node's /bin/sh is dash, which does not have it — and
  # setsid alone is what does the detaching.
  nsh "STUN_RESUME_TOKEN='${RESUME_TOKEN}' setsid /usr/local/bin/stun-sentinel \
         --listen-addr='${DAEMON_ADDR}' </dev/null >/tmp/stun-sentinel.log 2>&1 &"
  # Poll for readiness rather than sleeping a fixed interval.
  local i
  for i in $(seq 1 50); do
    if nsh "curl -sf --max-time 2 http://${DAEMON_ADDR}/healthz >/dev/null 2>&1"; then return 0; fi
    sleep 0.2
  done
  log "daemon did not become healthy on ${DAEMON_ADDR}"
  nsh 'cat /tmp/stun-sentinel.log' >&2
  exit 5
}

start_burner() {
  # A namespace left Terminating by a previous run rejects both `create` and
  # `apply` ("namespace is terminating"). Back-to-back invocations hit this
  # every time, and the resulting failure is easy to misread as the freezer
  # being broken. Wait it out before touching anything.
  local phase i
  for i in $(seq 1 60); do
    if ! kubectl --context "${CLUSTER_CONTEXT}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
      break
    fi
    phase="$(kubectl --context "${CLUSTER_CONTEXT}" get namespace "${NAMESPACE}" \
              -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${phase}" != "Terminating" ]]; then
      break
    fi
    [[ "${i}" == "1" ]] && log "waiting for namespace ${NAMESPACE} to finish terminating"
    sleep 1
  done

  if ! kubectl --context "${CLUSTER_CONTEXT}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    kubectl --context "${CLUSTER_CONTEXT}" create namespace "${NAMESPACE}" >/dev/null 2>&1 || true
  fi
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
    signalloom.ai/role: crkc-p1-2-freeze-target
spec:
  terminationGracePeriodSeconds: 1
  containers:
    - name: burner
      image: ${BURNER_IMAGE}
      imagePullPolicy: IfNotPresent
      # A tight busy loop. Under freeze its CPU accounting must stop dead;
      # anything that merely slows down is not containment.
      command: ["/bin/sh", "-c", "while :; do :; done"]
YAML

  kubectl --context "${CLUSTER_CONTEXT}" wait --for=condition=Ready \
    "pod/${POD}" -n "${NAMESPACE}" --timeout=120s >/dev/null || exit 6
}

cleanup() {
  if [[ "${KEEP}" == "1" ]]; then
    log "--keep: leaving namespace ${NAMESPACE} and the daemon in place"
    return 0
  fi
  kubectl --context "${CLUSTER_CONTEXT}" delete namespace "${NAMESPACE}" \
    --ignore-not-found --wait=false >/dev/null 2>&1
  nsh 'pkill -x stun-sentinel >/dev/null 2>&1; exit 0'
  # An explicit success: under a future `set -e` the trap's last command
  # would otherwise rewrite the script's exit status.
  return 0
}

cpu_usec() { nsh "awk '/^usage_usec/{print \$2}' '$1/cpu.stat' 2>/dev/null || echo 0"; }

main() {
  parse_args "$@"
  preflight
  build_and_install
  start_burner
  start_daemon
  trap cleanup EXIT

  local pod_uid cg_expected
  pod_uid="$(kubectl --context "${CLUSTER_CONTEXT}" get pod "${POD}" -n "${NAMESPACE}" \
              -o jsonpath='{.metadata.uid}')"
  log "pod ${NAMESPACE}/${POD} uid=${pod_uid}"

  # ── P1: the daemon can write the host cgroup hierarchy ────────────────────
  local health
  health="$(nsh "curl -sf --max-time 5 http://${DAEMON_ADDR}/healthz")"
  record "P01-healthcheck-cgroup-writable" \
    "healthz=$(printf '%s' "${health}" | jq -c '{status,cgroup_write}')" \
    "$([[ "$(printf '%s' "${health}" | jq -r '.cgroup_write')" == "true" ]] && echo 1 || echo 0)"

  # ── P2: the pod's cgroup resolves, and to the layout we predict ───────────
  cg_expected="/sys/fs/cgroup/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-besteffort.slice/kubelet-kubepods-besteffort-pod${pod_uid//-/_}.slice"
  record "P02-cgroup-path-exists" "expected ${cg_expected}" \
    "$(nsh "test -f '${cg_expected}/cgroup.freeze'" && echo 1 || echo 0)"

  # ── P3: baseline — the workload is genuinely burning CPU ──────────────────
  local a b running_delta
  a="$(cpu_usec "${cg_expected}")"; sleep "${SAMPLE_WINDOW}"; b="$(cpu_usec "${cg_expected}")"
  running_delta=$((b - a))
  record "P03-baseline-cpu-burning" \
    "usage_usec delta over ${SAMPLE_WINDOW}s = ${running_delta}" \
    "$([[ "${running_delta}" -gt 100000 ]] && echo 1 || echo 0)"

  # ── P4: pre-freeze state is frozen 0 ──────────────────────────────────────
  local pre_events
  pre_events="$(nsh "cat '${cg_expected}/cgroup.events'" | tr '\n' ';')"
  record "P04-pre-freeze-thawed" "cgroup.events=${pre_events}" \
    "$([[ "${pre_events}" == *"frozen 0"* ]] && echo 1 || echo 0)"

  # ── P5: the stun call succeeds ────────────────────────────────────────────
  # One request only. Issuing a second call to read the status code would
  # freeze an already-frozen cgroup and report ITS latency, which is not the
  # transition we are measuring. Body and status come back together.
  local stun_raw stun_resp stun_code latency_ms resolved_path
  stun_raw="$(nsh "curl -s -w '\n%{http_code}' --max-time 10 -X POST http://${DAEMON_ADDR}/stun \
      -H 'Content-Type: application/json' \
      -d '{\"pod_uid\":\"${pod_uid}\",\"pod\":\"${POD}\",\"namespace\":\"${NAMESPACE}\"}'")"
  stun_code="$(printf '%s' "${stun_raw}" | tail -n1)"
  stun_resp="$(printf '%s' "${stun_raw}" | sed '$d')"
  record "P05-stun-returns-200" "http_status=${stun_code}" \
    "$([[ "${stun_code}" == "200" ]] && echo 1 || echo 0)"

  latency_ms="$(printf '%s' "${stun_resp}" | jq -r '.latency_ms // 999')"
  resolved_path="$(printf '%s' "${stun_resp}" | jq -r '.cgroup_path // ""')"

  # ── P6: the daemon resolved the same path we did, independently ───────────
  record "P06-daemon-resolved-expected-path" "daemon=${resolved_path}" \
    "$([[ "${resolved_path}" == "${cg_expected}" ]] && echo 1 || echo 0)"

  # ── P7: the daemon reports frozen, from a read-back not an assumption ─────
  record "P07-daemon-reports-frozen" \
    "frozen=$(printf '%s' "${stun_resp}" | jq -r '.frozen')" \
    "$([[ "$(printf '%s' "${stun_resp}" | jq -r '.frozen')" == "true" ]] && echo 1 || echo 0)"

  # ── P8: latency inside the 50ms deadline ──────────────────────────────────
  record "P08-freeze-latency-under-50ms" "latency_ms=${latency_ms}" \
    "$(awk -v l="${latency_ms}" 'BEGIN{exit !(l < 50)}' && echo 1 || echo 0)"

  # ── P9: THE kernel-truth probe. cgroup.events read directly, not via the
  #        daemon, so the daemon cannot vouch for itself. ────────────────────
  local post_events
  post_events="$(nsh "cat '${cg_expected}/cgroup.events'" | tr '\n' ';')"
  record "P09-kernel-reports-frozen-1" "cgroup.events=${post_events}" \
    "$([[ "${post_events}" == *"frozen 1"* ]] && echo 1 || echo 0)"

  # ── P10: THE behavioural probe. CPU accounting must stop dead. ────────────
  local c d frozen_delta
  c="$(cpu_usec "${cg_expected}")"; sleep "${SAMPLE_WINDOW}"; d="$(cpu_usec "${cg_expected}")"
  frozen_delta=$((d - c))
  record "P10-cpu-usage-drops-to-zero" \
    "usage_usec delta over ${SAMPLE_WINDOW}s = ${frozen_delta} (was ${running_delta})" \
    "$([[ "${frozen_delta}" -eq 0 ]] && echo 1 || echo 0)"

  # Kernel task state of the frozen processes, recorded for the audit trail.
  # NOTE: cgroup-v2 parks frozen tasks in TASK_INTERRUPTIBLE, so /proc shows
  # 'S' with wchan=get_signal — NOT the 'D' that the cgroup-v1 freezer
  # produced. See the Deviations section of the CRKC-P1-2 errata.
  local pid_states=""
  local p
  for p in $(printf '%s' "${stun_resp}" | jq -r '.pids[]? // empty'); do
    pid_states+="${p}:$(nsh "awk '{print \$3}' /proc/${p}/stat 2>/dev/null || echo GONE")"
    pid_states+="/$(nsh "cat /proc/${p}/wchan 2>/dev/null || echo -") "
  done
  log "  info frozen task states (pid:state/wchan): ${pid_states:-none}"

  # ── P11: resume without a governance credential is refused ────────────────
  local unauth_code
  unauth_code="$(nsh "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST http://${DAEMON_ADDR}/resume \
      -H 'Content-Type: application/json' -d '{\"pod_uid\":\"${pod_uid}\"}'")"
  record "P11-resume-without-credential-refused" "http_status=${unauth_code}" \
    "$([[ "${unauth_code}" == "403" ]] && echo 1 || echo 0)"

  # ── P12: authorised resume thaws, and CPU actually restarts ───────────────
  local resume_resp resume_delta e f
  resume_resp="$(nsh "curl -s --max-time 10 -X POST http://${DAEMON_ADDR}/resume \
      -H 'Content-Type: application/json' -H 'Authorization: Bearer ${RESUME_TOKEN}' \
      -d '{\"pod_uid\":\"${pod_uid}\",\"pod\":\"${POD}\",\"namespace\":\"${NAMESPACE}\"}'")"
  e="$(cpu_usec "${cg_expected}")"; sleep "${SAMPLE_WINDOW}"; f="$(cpu_usec "${cg_expected}")"
  resume_delta=$((f - e))
  record "P12-authorised-resume-restores-execution" \
    "frozen=$(printf '%s' "${resume_resp}" | jq -r '.frozen'), usage_usec delta = ${resume_delta}" \
    "$([[ "$(printf '%s' "${resume_resp}" | jq -r '.frozen')" == "false" && "${resume_delta}" -gt 100000 ]] && echo 1 || echo 0)"

  # ── Arity gate ────────────────────────────────────────────────────────────
  local arity_ok=1
  if [[ "${EXECUTED}" -ne "${DECLARED_PROBES}" ]]; then
    arity_ok=0
    log "ARITY FAILURE: executed ${EXECUTED} probes, declared ${DECLARED_PROBES}"
  fi

  local overall="pass"
  [[ "${FAIL}" -eq 0 && "${arity_ok}" -eq 1 ]] || overall="fail"

  log ""
  log "probes: ${PASS}/${EXECUTED} passed (declared ${DECLARED_PROBES}, executed ${EXECUTED}) — ${overall}"

  local telemetry_line
  telemetry_line="$(nsh "grep StunExecutionHalted /tmp/stun-sentinel.log 2>/dev/null | tail -1" || echo '')"

  local artifact
  artifact="$(jq -n \
    --arg card "CRKC-P1-2" \
    --arg overall "${overall}" \
    --arg kernel "$(uname -r)" \
    --arg node "${KIND_NODE}" \
    --arg ns "${NAMESPACE}" \
    --arg pod "${POD}" \
    --arg uid "${pod_uid}" \
    --arg cg "${cg_expected}" \
    --arg pre "${pre_events}" \
    --arg post "${post_events}" \
    --arg states "${pid_states}" \
    --argjson latency "${latency_ms}" \
    --argjson running "${running_delta}" \
    --argjson frozen "${frozen_delta}" \
    --argjson resumed "${resume_delta}" \
    --argjson declared "${DECLARED_PROBES}" \
    --argjson executed "${EXECUTED}" \
    --argjson passed "${PASS}" \
    --argjson failed "${FAIL}" \
    --argjson window "${SAMPLE_WINDOW}" \
    --slurpfile probes <(printf '%s\n' "${RESULTS[@]}" | jq -s '.') \
    '{
       card: $card,
       harness: "scripts/test-cgroup-freezer.sh",
       overall: $overall,
       environment: {kernel: $kernel, node: $node, cgroup_version: 2,
                     freezer_is_core_interface: true},
       target: {namespace: $ns, pod: $pod, pod_uid: $uid, cgroup_path: $cg},
       measurements: {
         sample_window_seconds: $window,
         cpu_usec_running: $running,
         cpu_usec_frozen: $frozen,
         cpu_usec_after_resume: $resumed,
         freeze_latency_ms: $latency,
         deadline_ms: 50,
         cgroup_events_before: $pre,
         cgroup_events_after: $post,
         frozen_task_states: $states
       },
       probes: {declared: $declared, executed: $executed, passed: $passed, failed: $failed,
                results: $probes[0]}
     }')"

  if [[ -n "${telemetry_line}" ]]; then
    artifact="$(printf '%s' "${artifact}" | jq --argjson t "${telemetry_line}" '. + {signal_loom_telemetry: $t}')"
  fi

  if [[ -n "${JSON_OUT}" ]]; then
    mkdir -p "$(dirname -- "${JSON_OUT}")"
    printf '%s\n' "${artifact}" > "${JSON_OUT}"
    log "proof artifact written to ${JSON_OUT}"
  else
    printf '%s\n' "${artifact}"
  fi

  [[ "${overall}" == "pass" ]] && return 0
  return 1
}

main "$@"
