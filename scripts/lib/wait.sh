# shellcheck shell=bash
# wait.sh — VENDORED COPY, DO NOT EDIT HERE.
# Source of truth: ~/.andy_sync/includes/wait.sh   Re-vendor: make wait-lib-sync
#
# wait.sh — self-contained, resilient waiting/polling primitives.
#
# SOURCE OF TRUTH: ~/.andy_sync/includes/wait.sh. This file is vendored verbatim
# into other repos (e.g. osramp-demo/scripts/lib/wait.sh) so the SAME robust
# waits run in interactive shells, Makefiles, bats tests, and CI/containers.
# It deliberately has NO dependency on the login shell libraries — everything it
# needs is embedded, so it works anywhere bash + coreutils exist.
#
# Design principles (from the distributed-systems audit):
#   1. DEADLINE, not attempt-count. Under CPU/memory pressure "slow but
#      eventually" is a PASS, not a fail. Every wait is bounded by wall-clock.
#   2. EXISTENCE before CONDITION. `kubectl wait`/`rollout status` error
#      instantly on an object Flux hasn't created yet; we poll for existence
#      first, then wait for readiness within the remaining budget.
#   3. EXPONENTIAL BACKOFF + JITTER. No synchronised thundering-herd retries.
#   4. PER-ATTEMPT HANG FENCE. One wedged curl/kubectl can't block past the
#      deadline — each attempt runs under `timeout`.
#   5. READINESS, not wall-clock sleeps. Probe the actual endpoint/condition.
#
# Global tunables (env):
#   WAIT_DEADLINE_SCALE   multiply every deadline (default 1). Set to e.g. 10
#                         for a saturated prod box so the same suite passes
#                         slowly instead of failing — the "slow mode" lever.
#   WAIT_SLEEP            initial backoff sleep seconds (default 0.5)
#   WAIT_BACKOFF          exponential rate (default 1.5; 1 = fixed)
#   WAIT_JITTER           jitter fraction 0..1 (default 0.2)
#   WAIT_ATTEMPT_TIMEOUT  per-attempt timeout seconds (default 10)
#   WAIT_QUIET            if set, suppress progress chatter (⏳/✅/heartbeat lines)
#   WAIT_HEARTBEAT_START  seconds before the first "… still waiting" heartbeat
#                         (default 5; set 0 to disable heartbeats entirely)
#   WAIT_HEARTBEAT_FACTOR each heartbeat interval is multiplied by this
#                         (default 2 → ~5s, 10s, 20s, 40s, 80s: quiet, exponential)
#   WAIT_SOFT_RATIO       soft-threshold fraction of the deadline (default 0.6).
#                         On crossing it, a wait emits a one-time ⚠ "slow"
#                         warning naming the site + the retry command, then
#                         KEEPS WAITING to the hard deadline. No pause, no decay.
#   WAIT_STAT_FILE        if set, every wait appends a structured completion line
#                         (WAIT_STAT site=… elapsed=… deadline=… ratio=…). Sort
#                         that file by ratio after a run for a deterministic,
#                         ranked list of exactly which deadlines to raise.
#   WAIT_TIMEOUT_DIAGNOSTICS_CALLBACK
#                         optional function or executable invoked once after a
#                         hard timeout as: callback description elapsed deadline
#                         last_rc. Its status never changes the wait result.
#   WAIT_FAIL_FAST_RC     internal sentinel used by policy-aware probes.
#
# All verbs return 0 on success, 1 on deadline-exceeded.

# --- internal: float-capable arithmetic -------------------------------------
_wait_calc() {
  if command -v awk >/dev/null 2>&1; then awk "BEGIN{print $*}"; else echo "$(($*))"; fi
}

_wait_log() { [ -n "${WAIT_QUIET:-}" ] || printf '%s\n' "$*" >&2; }

# --- internal: structured completion stat -----------------------------------
# _wait_stat <desc> <start_seconds> <deadline_s> <result>
# Emits one WAIT_STAT line to stderr (always — it is the signal, not chatter)
# and appends to WAIT_STAT_FILE if set. ratio = how much of the budget was used.
_wait_stat() {
  local desc="$1" start="$2" deadline="$3" result="$4"
  local elapsed; elapsed=$(( SECONDS - start ))
  local ratio=0
  if [ "${deadline:-0}" -gt 0 ] 2>/dev/null; then
    ratio="$(_wait_calc "${elapsed} * 100.0 / ${deadline}")"
    ratio="${ratio%%.*}"
  fi
  local line; line="$(printf 'WAIT_STAT site="%s" elapsed=%ss deadline=%ss ratio=%s%% result=%s' \
    "${desc}" "${elapsed}" "${deadline}" "${ratio}" "${result}")"
  printf '%s\n' "${line}" >&2
  [ -n "${WAIT_STAT_FILE:-}" ] && printf '%s\n' "${line}" >> "${WAIT_STAT_FILE}" 2>/dev/null
  return 0
}

# _wait_timeout_diagnostics <desc> <start_seconds> <deadline_s> <last_rc>
# Runs once in a guarded subshell. A callback may perform synchronous diagnostic
# collection after the polling deadline; its exit status cannot replace timeout.
_wait_timeout_diagnostics() {
  local callback="${WAIT_TIMEOUT_DIAGNOSTICS_CALLBACK:-}"
  [ -n "${callback}" ] || return 0
  [ -z "${WAIT_TIMEOUT_DIAGNOSTICS_ACTIVE:-}" ] || return 0
  local desc="$1" start="$2" deadline="$3" last_rc="$4"
  local elapsed=$(( SECONDS - start ))
  (
    export WAIT_TIMEOUT_DIAGNOSTICS_ACTIVE=1
    "${callback}" "${desc}" "${elapsed}" "${deadline}" "${last_rc}" || true
  )
}

# --- core retry engine ------------------------------------------------------
# _wait_retry <deadline_s> <description> <command...>
# Retries <command> until it exits 0 or the wall-clock deadline elapses.
# Honours WAIT_SLEEP / WAIT_BACKOFF / WAIT_JITTER / WAIT_ATTEMPT_TIMEOUT and the
# global WAIT_DEADLINE_SCALE. The command runs under `timeout` (hang fence).
_wait_retry() {
  local deadline="${1:?deadline required}"; shift
  local desc="${1:?description required}"; shift
  local scale="${WAIT_DEADLINE_SCALE:-1}"
  local sleep_s="${WAIT_SLEEP:-0.5}"
  local backoff="${WAIT_BACKOFF:-1.5}"
  local jitter="${WAIT_JITTER:-0.2}"
  local attempt_timeout="${WAIT_ATTEMPT_TIMEOUT:-10}"

  deadline="$(_wait_calc "${deadline} * ${scale}")"
  local dl_int="${deadline%%.*}"; [ -n "${dl_int}" ] || dl_int=0
  local start="${SECONDS}"
  local end; end="$(_wait_calc "${start} + ${deadline}")"; end="${end%%.*}"
  # Soft threshold (default 60% of the hard deadline): compassionate warning,
  # not a second timeout — we keep waiting to the hard deadline.
  local soft; soft="$(_wait_calc "${dl_int} * ${WAIT_SOFT_RATIO:-0.6}")"; soft="${soft%%.*}"
  local cmd="$*"

  local attempt=0 rc=1 cur_sleep remaining attempt_timeout_now soft_warned=
  # Progress heartbeat: first at WAIT_HEARTBEAT_START seconds, then spaced out by
  # WAIT_HEARTBEAT_FACTOR each time (exponential) so a long wait shows it is alive
  # without spamming — e.g. ~5s, 10s, 20s, 40s, 80s. Respects WAIT_QUIET; set
  # WAIT_HEARTBEAT_START=0 to disable.
  local hb_next="${WAIT_HEARTBEAT_START:-5}"
  local hb_factor="${WAIT_HEARTBEAT_FACTOR:-2}"
  local have_timeout=; command -v timeout >/dev/null 2>&1 && have_timeout=1

  _wait_log "⏳ ${desc} (deadline ${dl_int}s, soft ${soft}s, backoff ${backoff}, jitter ${jitter})"
  while :; do
    if [ "${SECONDS}" -ge "${end}" ]; then
      _wait_log "❌ ${desc} — deadline ${dl_int}s exceeded after ${attempt} attempt(s)"
      _wait_stat "${desc}" "${start}" "${dl_int}" timeout
      _wait_timeout_diagnostics "${desc}" "${start}" "${dl_int}" "${rc}"
      return 1
    fi
    remaining=$((end - SECONDS))
    if [ "${remaining}" -le 0 ]; then
      continue
    fi
    attempt_timeout_now="${attempt_timeout}"
    if [ "${remaining}" -gt 0 ] && [ "$(_wait_calc "(${attempt_timeout} > ${remaining}) ? 1 : 0")" -eq 1 ]; then
      attempt_timeout_now="${remaining}"
    fi
    if [ -n "${have_timeout}" ]; then
      if timeout "${attempt_timeout_now}" bash -c "${cmd}"; then
        rc=0
      else
        rc=$?
      fi
    elif bash -c "${cmd}"; then
      rc=0
    else
      rc=$?
    fi
    if [ "${rc}" -eq 0 ]; then
      _wait_log "✅ ${desc} — ready after $((attempt + 1)) attempt(s), $(( SECONDS - start ))s"
      _wait_stat "${desc}" "${start}" "${dl_int}" ok
      return 0
    fi
    if [ -n "${WAIT_FAIL_FAST_RC:-}" ] && [ "${rc}" -eq "${WAIT_FAIL_FAST_RC}" ]; then
      _wait_log "❌ ${desc} — terminal failure after $((attempt + 1)) attempt(s)"
      _wait_stat "${desc}" "${start}" "${dl_int}" failed
      return 1
    fi

    if [ "${SECONDS}" -ge "${end}" ]; then
      _wait_log "❌ ${desc} — deadline ${dl_int}s exceeded after $((attempt + 1)) attempt(s)"
      _wait_stat "${desc}" "${start}" "${dl_int}" timeout
      _wait_timeout_diagnostics "${desc}" "${start}" "${dl_int}" "${rc}"
      return 1
    fi
    # Soft-deadline: warn ONCE past the soft threshold (bypasses WAIT_QUIET —
    # this is signal, and only fires when something is genuinely slow), name the
    # retry command, and KEEP WAITING. No pause, no backoff decay.
    if [ -z "${soft_warned}" ] && [ "${soft}" -gt 0 ] && [ "$(( SECONDS - start ))" -ge "${soft}" ]; then
      soft_warned=1
      printf '⚠ slow: %s still not ready after %ss of %ss — consider raising the budget. retry: %s\n' \
        "${desc}" "$(( SECONDS - start ))" "${dl_int}" "${cmd}" >&2
    fi
    # Occasional, exponentially-spaced heartbeat so a long wait shows life.
    if [ "${hb_next%.*}" -gt 0 ] 2>/dev/null && [ "$(( SECONDS - start ))" -ge "${hb_next%.*}" ]; then
      _wait_log "   … still waiting: ${desc} ($(( SECONDS - start ))s / ${dl_int}s)"
      hb_next="$(_wait_calc "${hb_next} * ${hb_factor}")"
    fi
    # exponential backoff
    cur_sleep="$(_wait_calc "${sleep_s} * (${backoff} ^ ${attempt})")"
    # jitter: +/- fraction, clamped >= 0
    cur_sleep="$(_wait_calc "j = ${cur_sleep} * (1 + ${jitter} * ((${RANDOM} / 32767.0) * 2 - 1)); (j < 0) ? 0 : j")"
    remaining=$((end - SECONDS))
    cur_sleep="$(_wait_calc "(${cur_sleep} > ${remaining}) ? ${remaining} : ${cur_sleep}")"
    sleep "${cur_sleep}"
    attempt=$((attempt + 1))
  done
}

# --- network / HTTP readiness ----------------------------------------------
# wait_reachable <url> [deadline_s]  — HTTP endpoint returns success (curl -fsS)
wait_reachable() {
  local url="${1:?url required}"; local deadline="${2:-60}"
  _wait_retry "${deadline}" "reachable ${url}" \
    "curl -fsS --max-time ${WAIT_ATTEMPT_TIMEOUT:-10} -o /dev/null '${url}'"
}

# wait_tcp <host> <port> [deadline_s]  — TCP port accepts connections
wait_tcp() {
  local host="${1:?host required}"; local port="${2:?port required}"; local deadline="${3:-60}"
  local probe
  if command -v nc >/dev/null 2>&1; then
    probe="nc -z '${host}' '${port}'"
  else
    probe="exec 3<>/dev/tcp/${host}/${port} && exec 3>&-"
  fi
  _wait_retry "${deadline}" "tcp ${host}:${port}" "${probe}"
}

# --- kubernetes -------------------------------------------------------------
# wait_k8s_exists <kind> <name> [-n ns] [deadline_s]  — object exists in the API
wait_k8s_exists() {
  local kind="${1:?kind required}"; local name="${2:?name required}"; shift 2
  local ns_args="" deadline=120
  while [ $# -gt 0 ]; do case "$1" in
    -n) ns_args="-n $2"; shift 2 ;;
    *)  deadline="$1"; shift ;;
  esac; done
  _wait_retry "${deadline}" "exists ${kind}/${name} ${ns_args}" \
    "kubectl ${ns_args} get ${kind} ${name} >/dev/null 2>&1"
}

# wait_k8s_ready <kind> <name> [-n ns] [--for cond] [deadline_s]
# Existence-first, THEN `kubectl wait --for=<cond>` within the remaining budget.
# This is the generalised fix for the cold-cluster race where `kubectl wait`
# errors instantly on a not-yet-created object.
wait_k8s_ready() {
  local kind="${1:?kind required}"; local name="${2:?name required}"; shift 2
  case "${kind}" in
    job|Job|jobs|Jobs)
      wait_job "${name}" "$@"
      return $?
      ;;
  esac
  local ns_args="" cond="condition=ready" deadline=300
  while [ $# -gt 0 ]; do case "$1" in
    -n) ns_args="-n $2"; shift 2 ;;
    --for) cond="$2"; shift 2 ;;
    *)  deadline="$1"; shift ;;
  esac; done
  local scale="${WAIT_DEADLINE_SCALE:-1}"
  local scaled; scaled="$(_wait_calc "${deadline} * ${scale}")"; scaled="${scaled%%.*}"
  local start="${SECONDS}"

  # Phase 1: existence (half the budget).
  local half; half="$(_wait_calc "${scaled} / 2")"; half="${half%%.*}"
  if [ "${half}" -le 0 ]; then
    if [ "${scaled}" -le 0 ]; then
      _wait_log "❌ ready ${kind}/${name} ${ns_args} — no deadline budget available"
      _wait_stat "ready ${kind}/${name} ${ns_args}" "${start}" "${scaled}" timeout
      _wait_timeout_diagnostics "ready ${kind}/${name} ${ns_args}" "${start}" "${scaled}" 1
      return 1
    fi
    half="${scaled}"
  fi
  WAIT_DEADLINE_SCALE=1 _wait_retry "${half}" "exists ${kind}/${name} ${ns_args}" \
    "kubectl ${ns_args} get ${kind} ${name} >/dev/null 2>&1" || return 1

  # Phase 2: readiness within whatever budget remains.
  local remaining; remaining="$(_wait_calc "${scaled} - (${SECONDS} - ${start})")"; remaining="${remaining%%.*}"
  if [ "${remaining}" -le 0 ]; then
    _wait_log "❌ ready ${kind}/${name} ${ns_args} — deadline ${scaled}s exhausted before readiness check"
    _wait_stat "ready ${kind}/${name} ${ns_args}" "${start}" "${scaled}" timeout
    _wait_timeout_diagnostics "ready ${kind}/${name} ${ns_args}" "${start}" "${scaled}" 1
    return 1
  fi
  _wait_log "⏳ ready ${kind}/${name} ${ns_args} (--for=${cond}, ${remaining}s left)"
  local rc
  if command -v timeout >/dev/null 2>&1; then
    if timeout "${remaining}" kubectl ${ns_args} wait "${kind}/${name}" "--for=${cond}" "--timeout=${remaining}s"; then rc=0; else rc=$?; fi
  elif kubectl ${ns_args} wait "${kind}/${name}" "--for=${cond}" "--timeout=${remaining}s"; then
    rc=0
  else
    rc=$?
  fi
  if [ "${rc}" -eq 0 ]; then
    _wait_stat "ready ${kind}/${name} ${ns_args}" "${start}" "${scaled}" ok
  else
    _wait_stat "ready ${kind}/${name} ${ns_args}" "${start}" "${scaled}" timeout
    [ "$(( SECONDS - start ))" -ge "${scaled}" ] && _wait_timeout_diagnostics "ready ${kind}/${name} ${ns_args}" "${start}" "${scaled}" "${rc}"
    return 1
  fi
}

# wait_rollout <deploy> [-n ns] [deadline_s]  — existence then rollout status
wait_rollout() {
  local name="${1:?deployment required}"; shift
  local ns_args="" deadline=300
  while [ $# -gt 0 ]; do case "$1" in
    -n) ns_args="-n $2"; shift 2 ;;
    *)  deadline="$1"; shift ;;
  esac; done
  local scale="${WAIT_DEADLINE_SCALE:-1}"
  local scaled; scaled="$(_wait_calc "${deadline} * ${scale}")"; scaled="${scaled%%.*}"
  local start="${SECONDS}"
  local half; half="$(_wait_calc "${scaled} / 2")"; half="${half%%.*}"
  if [ "${half}" -le 0 ]; then
    if [ "${scaled}" -le 0 ]; then
      _wait_log "❌ rollout deploy/${name} ${ns_args} — no deadline budget available"
      _wait_stat "rollout deploy/${name} ${ns_args}" "${start}" "${scaled}" timeout
      _wait_timeout_diagnostics "rollout deploy/${name} ${ns_args}" "${start}" "${scaled}" 1
      return 1
    fi
    half="${scaled}"
  fi
  WAIT_DEADLINE_SCALE=1 _wait_retry "${half}" "exists deploy/${name} ${ns_args}" \
    "kubectl ${ns_args} get deploy ${name} >/dev/null 2>&1" || return 1
  local remaining; remaining="$(_wait_calc "${scaled} - (${SECONDS} - ${start})")"; remaining="${remaining%%.*}"
  if [ "${remaining}" -le 0 ]; then
    _wait_log "❌ rollout deploy/${name} ${ns_args} — deadline ${scaled}s exhausted before rollout check"
    _wait_stat "rollout deploy/${name} ${ns_args}" "${start}" "${scaled}" timeout
    _wait_timeout_diagnostics "rollout deploy/${name} ${ns_args}" "${start}" "${scaled}" 1
    return 1
  fi
  _wait_log "⏳ rollout deploy/${name} ${ns_args} (${remaining}s left)"
  local rc
  if command -v timeout >/dev/null 2>&1; then
    if timeout "${remaining}" kubectl ${ns_args} rollout status "deploy/${name}" "--timeout=${remaining}s"; then rc=0; else rc=$?; fi
  elif kubectl ${ns_args} rollout status "deploy/${name}" "--timeout=${remaining}s"; then
    rc=0
  else
    rc=$?
  fi
  if [ "${rc}" -eq 0 ]; then
    _wait_stat "rollout deploy/${name} ${ns_args}" "${start}" "${scaled}" ok
  else
    _wait_stat "rollout deploy/${name} ${ns_args}" "${start}" "${scaled}" timeout
    [ "$(( SECONDS - start ))" -ge "${scaled}" ] && _wait_timeout_diagnostics "rollout deploy/${name} ${ns_args}" "${start}" "${scaled}" "${rc}"
    return 1
  fi
}

# wait_flux_ready <kind> <name> [-n ns] [deadline_s]  — Flux Kustomization/
# ResourceSet Ready. Existence-first, then wait on the Ready condition.
wait_flux_ready() {
  local kind="${1:?kind required}"; local name="${2:?name required}"; shift 2
  wait_k8s_ready "${kind}" "${name}" "$@" --for "condition=ready"
}

# wait_pods_ready <selector> [-n ns] [--for all-ready|any-ready]
#                 [--fail-fast] [deadline_s]
# Default semantics remain all-ready: at least one matching pod, every matching
# pod has container statuses, and no container is unready.
wait_pods_ready() {
  local selector="${1:?selector required}"; shift
  local ns_args="" deadline=300 for_cond="all-ready" fail_fast=0
  while [ $# -gt 0 ]; do case "$1" in
    -n|--namespace) ns_args="-n $2"; shift 2 ;;
    -n=*|--namespace=*) ns_args="-n ${1#*=}"; shift ;;
    --for=*) for_cond="${1#--for=}"; shift ;;
    --for) for_cond="$2"; shift 2 ;;
    --fail-fast) fail_fast=1; shift ;;
    *) deadline="$1"; shift ;;
  esac; done
  case "${for_cond}" in
    ready|all|all-ready) for_cond="all-ready" ;;
    any|any-ready) for_cond="any-ready" ;;
    *) _wait_log "❌ pods ready ${selector} ${ns_args} — unsupported policy: ${for_cond}"; return 1 ;;
  esac

  local probe="
    if [ '${fail_fast}' -eq 1 ]; then
      states=\$(kubectl ${ns_args} get pods -l '${selector}' \
        -o 'jsonpath={range .items[*]}{.status.phase}{\"|\"}{.spec.restartPolicy}{\"|\"}{range .status.initContainerStatuses[*]}{.state.terminated.exitCode}{\",\"}{.state.waiting.reason}{\",\"}{end}{range .status.containerStatuses[*]}{.state.terminated.exitCode}{\",\"}{.state.waiting.reason}{\",\"}{end}{\"\n\"}{end}' 2>/dev/null) || exit 1
      terminal=0
      while IFS='|' read -r phase restart_policy container_states; do
        [ \"\$phase\" = 'Failed' ] && terminal=1
        IFS=',' read -r -a fields <<< \"\$container_states\"
        for ((i=0; i<\${#fields[@]}; i+=2)); do
          exit_code=\${fields[\$i]:-}
          reason=\${fields[\$((i + 1))]:-}
          if [ \"\$restart_policy\" = 'Never' ] && [[ \"\$exit_code\" =~ ^[0-9]+$ ]] && [ \"\$exit_code\" -ne 0 ]; then
            terminal=1
          fi
          [ \"\$reason\" = 'InvalidImageName' ] && terminal=1
        done
      done <<< \"\$states\"
      [ \"\$terminal\" -eq 1 ] && exit 42
    fi

    out=\$(kubectl ${ns_args} get pods -l '${selector}' \
      -o 'jsonpath={range .items[*]}{.metadata.name}{\"|\"}{range .status.containerStatuses[*]}{.ready}{\",\"}{end}{\"\n\"}{end}' 2>/dev/null) || exit 1
    found=0
    bad=0
    ready=0
    while IFS='|' read -r pod statuses; do
      [ -n \"\$pod\" ] || continue
      found=1
      if [ -n \"\$statuses\" ] && ! printf '%s' \"\$statuses\" | grep -q false; then
        ready=1
      else
        bad=1
      fi
    done <<< \"\$out\"
    if [ '${for_cond}' = 'any-ready' ]; then
      [ \"\$ready\" -eq 1 ]
    else
      [ \"\$found\" -eq 1 ] && [ \"\$bad\" -eq 0 ]
    fi
  "
  local desc="pods ready ${selector} ${ns_args}"
  [ "${for_cond}" = "any-ready" ] && desc="${desc} (any-ready)"
  [ "${fail_fast}" -eq 1 ] && desc="${desc} (fail-fast)"
  WAIT_FAIL_FAST_RC=42 _wait_retry "${deadline}" "${desc}" "${probe}"
}

# wait_service_backends <service> [-n ns] [deadline_s]
# Existence-first, then requires at least one non-terminating EndpointSlice
# endpoint whose Ready condition is true or absent (unknown).
wait_service_backends() {
  local name="${1:?service name required}"; shift
  local ns_args="" deadline=300
  while [ $# -gt 0 ]; do case "$1" in
    -n|--namespace) ns_args="-n $2"; shift 2 ;;
    -n=*|--namespace=*) ns_args="-n ${1#*=}"; shift ;;
    *) deadline="$1"; shift ;;
  esac; done

  local scale="${WAIT_DEADLINE_SCALE:-1}"
  local scaled; scaled="$(_wait_calc "${deadline} * ${scale}")"; scaled="${scaled%%.*}"
  local start="${SECONDS}"
  if [ "${scaled}" -le 0 ]; then
    _wait_log "❌ service/${name}${ns_args:+ $ns_args} — no deadline budget available"
    _wait_stat "service/${name}${ns_args:+ $ns_args}" "${start}" "${scaled}" timeout
    _wait_timeout_diagnostics "service/${name}${ns_args:+ $ns_args}" "${start}" "${scaled}" 1
    return 1
  fi

  local half; half="$(_wait_calc "${scaled} / 2")"; half="${half%%.*}"
  [ "${half}" -le 0 ] && half="${scaled}"
  WAIT_DEADLINE_SCALE=1 _wait_retry "${half}" "exists service/${name}${ns_args:+ $ns_args}" \
    "kubectl ${ns_args} get service ${name} >/dev/null 2>&1" || return 1

  local remaining; remaining="$(_wait_calc "${scaled} - (${SECONDS} - ${start})")"; remaining="${remaining%%.*}"
  if [ "${remaining}" -le 0 ]; then
    _wait_log "❌ service/${name}${ns_args:+ $ns_args} — deadline exhausted before backend check"
    _wait_stat "service/${name}${ns_args:+ $ns_args}" "${start}" "${scaled}" timeout
    _wait_timeout_diagnostics "service/${name}${ns_args:+ $ns_args}" "${start}" "${scaled}" 1
    return 1
  fi

  WAIT_DEADLINE_SCALE=1 _wait_retry "${remaining}" "ready backends service/${name}${ns_args:+ $ns_args}" "
    out=\$(kubectl ${ns_args} get endpointslices.discovery.k8s.io \
      -l 'kubernetes.io/service-name=${name}' \
      -o 'jsonpath={range .items[*].endpoints[*]}{.addresses[0]}{\"|\"}{.conditions.ready}{\"|\"}{.conditions.terminating}{\"\n\"}{end}' 2>/dev/null) || exit 1
    ready=0
    while IFS='|' read -r address condition terminating; do
      if [ -n \"\$address\" ] && [ \"\$condition\" != 'false' ] && [ \"\$terminating\" != 'true' ]; then
        ready=1
      fi
    done <<< \"\$out\"
    [ \"\$ready\" -eq 1 ]
  "
}

# wait_job <name> [-n ns] [--for complete|terminal|failed] [--fail-fast] [deadline_s]
# Robust, evidenced waiting for a Kubernetes batch/v1 Job.
#   Phase 1: existence check (exists job/${name}) using _wait_retry.
#   Phase 2: terminal polling using _wait_retry:
#     Checks .status.conditions[Complete]=True or Failed=True.
#     If --fail-fast is set, also checks if container exit code is [1-9]
#     (using .status.containerStatuses[*] mapped as name=exitCode).
#   Phase 3: condition evaluation:
#     If --for=complete (default): returns 0 if Complete=True and no non-zero exit;
#     logs error and returns 1 if failed.
#     If --for=terminal: returns 0 when terminal state reached.
#     If --for=failed: returns 0 if Failed=True or non-zero exit; returns 1 if completed.
# Emits structured _wait_stat lines.
# shellcheck disable=SC2086
wait_job() {
  local name="${1:?job name required}"; shift
  local ns_args="" for_cond="complete" fail_fast=0 deadline=300
  while [ $# -gt 0 ]; do case "$1" in
    -n|--namespace) ns_args="-n $2"; shift 2 ;;
    -n=*|--namespace=*) ns_args="-n ${1#*=}"; shift ;;
    --for=*)
      for_cond="${1#--for=}"
      for_cond="${for_cond#condition=}"
      shift ;;
    --for)
      for_cond="${2#condition=}"
      shift 2 ;;
    --fail-fast)
      fail_fast=1; shift ;;
    *)
      deadline="$1"; shift ;;
  esac; done

  case "${for_cond}" in
    ready|complete) for_cond="complete" ;;
    terminal)       for_cond="terminal" ;;
    failed)         for_cond="failed" ;;
    *)              for_cond="complete" ;;
  esac

  local scale="${WAIT_DEADLINE_SCALE:-1}"
  local scaled; scaled="$(_wait_calc "${deadline} * ${scale}")"; scaled="${scaled%%.*}"
  local start="${SECONDS}"

  # Phase 1: existence check (half the budget).
  local half; half="$(_wait_calc "${scaled} / 2")"; half="${half%%.*}"
  if [ -z "${half}" ] || [ "${half}" -le 0 ]; then
    if [ "${scaled}" -gt 0 ]; then
      half="${scaled}"
    else
      _wait_log "❌ exists job/${name}${ns_args:+ $ns_args} — no deadline budget available"
      _wait_stat "job/${name}${ns_args:+ $ns_args}" "${start}" "${scaled}" timeout
      _wait_timeout_diagnostics "job/${name}${ns_args:+ $ns_args}" "${start}" "${scaled}" 1
      return 1
    fi
  fi
  local exists_desc="exists job/${name}${ns_args:+ $ns_args}"
  WAIT_DEADLINE_SCALE=1 _wait_retry "${half}" "${exists_desc}" \
    "kubectl ${ns_args} get job ${name} >/dev/null 2>&1" || return 1

  # Phase 2: terminal polling using _wait_retry.
  local remaining; remaining="$(_wait_calc "${scaled} - (${SECONDS} - ${start})")"; remaining="${remaining%%.*}"
  if [ "${remaining}" -le 0 ]; then
    _wait_log "❌ terminal job/${name}${ns_args:+ $ns_args} — deadline ${scaled}s exhausted before terminal check"
    _wait_stat "job/${name}${ns_args:+ $ns_args}" "${start}" "${scaled}" timeout
    _wait_timeout_diagnostics "job/${name}${ns_args:+ $ns_args}" "${start}" "${scaled}" 1
    return 1
  fi

  local term_desc="terminal job/${name}${ns_args:+ $ns_args}"
  local term_cmd
  if [ "${fail_fast}" -eq 1 ]; then
    term_cmd="
      conds=\$(kubectl ${ns_args} get job ${name} -o 'jsonpath={range .status.conditions[*]}{.type}={.status}{\" \"}{end}' 2>/dev/null)
      exits=\$(kubectl ${ns_args} get pods -l 'job-name=${name}' -o 'jsonpath={range .items[*].status.containerStatuses[*]}{.name}={.state.terminated.exitCode}{\" \"}{end}' 2>/dev/null)
      printf '%s' \"\$conds\" | grep -qE '(Complete|Failed)=True' || printf '%s' \"\$exits\" | grep -qE '=[1-9]'
    "
  else
    term_cmd="
      conds=\$(kubectl ${ns_args} get job ${name} -o 'jsonpath={range .status.conditions[*]}{.type}={.status}{\" \"}{end}' 2>/dev/null)
      printf '%s' \"\$conds\" | grep -qE '(Complete|Failed)=True'
    "
  fi

  WAIT_DEADLINE_SCALE=1 _wait_retry "${remaining}" "${term_desc}" "${term_cmd}" || {
    _wait_stat "job/${name}${ns_args:+ $ns_args}" "${start}" "${scaled}" timeout
    return 1
  }

  # Phase 3: condition evaluation.
  local conditions pod_exits
  conditions="$(kubectl ${ns_args} get job "${name}" \
    -o 'jsonpath={range .status.conditions[*]}{.type}={.status}{" "}{end}' 2>/dev/null || true)"
  pod_exits="$(kubectl ${ns_args} get pods -l "job-name=${name}" \
    -o 'jsonpath={range .items[*].status.containerStatuses[*]}{.name}={.state.terminated.exitCode}{" "}{end}' 2>/dev/null || true)"

  local is_complete=0 is_failed=0 has_nonzero_exit=0
  [[ "${conditions}" == *"Complete=True"* ]] && is_complete=1
  [[ "${conditions}" == *"Failed=True"* ]] && is_failed=1
  printf '%s' "${pod_exits}" | grep -qE '=[1-9]' && has_nonzero_exit=1

  case "${for_cond}" in
    complete)
      if [ "${is_complete}" -eq 1 ] && [ "${has_nonzero_exit}" -eq 0 ]; then
        _wait_log "✅ job/${name}${ns_args:+ $ns_args} — complete"
        _wait_stat "job/${name}${ns_args:+ $ns_args}" "${start}" "${scaled}" ok
        return 0
      else
        _wait_log "❌ job/${name}${ns_args:+ $ns_args} — failed (conditions: ${conditions:-none}, exits: ${pod_exits:-none})"
        _wait_stat "job/${name}${ns_args:+ $ns_args}" "${start}" "${scaled}" failed
        return 1
      fi
      ;;
    terminal)
      _wait_log "✅ job/${name}${ns_args:+ $ns_args} — terminal state reached"
      _wait_stat "job/${name}${ns_args:+ $ns_args}" "${start}" "${scaled}" ok
      return 0
      ;;
    failed)
      if [ "${is_failed}" -eq 1 ] || [ "${has_nonzero_exit}" -eq 1 ]; then
        _wait_log "✅ job/${name}${ns_args:+ $ns_args} — failed as expected"
        _wait_stat "job/${name}${ns_args:+ $ns_args}" "${start}" "${scaled}" ok
        return 0
      else
        _wait_log "❌ job/${name}${ns_args:+ $ns_args} — completed but expected failure"
        _wait_stat "job/${name}${ns_args:+ $ns_args}" "${start}" "${scaled}" failed
        return 1
      fi
      ;;
  esac
}

# get_job_logs <name> [-n ns]
# Discovers all pods matching job-name=<name> in the namespace.
# Enforces multi-container targeting: for each pod, queries .spec.initContainers[*].name
# and .spec.containers[*].name.
# For every container name $c, runs:
#   kubectl ${ns_args} logs "$p" -c "$c" 2>/dev/null || true
#   kubectl ${ns_args} logs "$p" -c "$c" --previous 2>/dev/null || true
# shellcheck disable=SC2086
get_job_logs() {
  local name="${1:?job name required}"; shift
  local ns_args=""
  while [ $# -gt 0 ]; do case "$1" in
    -n|--namespace) ns_args="-n $2"; shift 2 ;;
    -n=*|--namespace=*) ns_args="-n ${1#*=}"; shift ;;
    *)  shift ;;
  esac; done

  local pods p init_containers containers c
  pods="$(kubectl ${ns_args} get pods -l "job-name=${name}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  for p in ${pods}; do
    init_containers="$(kubectl ${ns_args} get pod "${p}" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null || true)"
    containers="$(kubectl ${ns_args} get pod "${p}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)"
    for c in ${init_containers} ${containers}; do
      kubectl ${ns_args} logs "${p}" -c "${c}" 2>/dev/null || true
      kubectl ${ns_args} logs "${p}" -c "${c}" --previous 2>/dev/null || true
    done
  done
  return 0
}

