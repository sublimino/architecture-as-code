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
#   WAIT_QUIET            if set, suppress progress chatter (⏳/✅ lines)
#   WAIT_SOFT_RATIO       soft-threshold fraction of the deadline (default 0.6).
#                         On crossing it, a wait emits a one-time ⚠ "slow"
#                         warning naming the site + the retry command, then
#                         KEEPS WAITING to the hard deadline. No pause, no decay.
#   WAIT_STAT_FILE        if set, every wait appends a structured completion line
#                         (WAIT_STAT site=… elapsed=… deadline=… ratio=…). Sort
#                         that file by ratio after a run for a deterministic,
#                         ranked list of exactly which deadlines to raise.
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
  local ratio; ratio="$(_wait_calc "(${deadline} <= 0) ? 0 : (${elapsed} * 100.0 / ${deadline})")"
  ratio="${ratio%%.*}"
  local line; line="$(printf 'WAIT_STAT site="%s" elapsed=%ss deadline=%ss ratio=%s%% result=%s' \
    "${desc}" "${elapsed}" "${deadline}" "${ratio}" "${result}")"
  printf '%s\n' "${line}" >&2
  [ -n "${WAIT_STAT_FILE:-}" ] && printf '%s\n' "${line}" >> "${WAIT_STAT_FILE}" 2>/dev/null
  return 0
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

  local attempt=0 rc cur_sleep soft_warned=
  local have_timeout=; command -v timeout >/dev/null 2>&1 && have_timeout=1

  _wait_log "⏳ ${desc} (deadline ${dl_int}s, soft ${soft}s, backoff ${backoff}, jitter ${jitter})"
  while :; do
    if [ -n "${have_timeout}" ]; then
      if timeout "${attempt_timeout}" bash -c "${cmd}"; then
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

    if [ "${SECONDS}" -ge "${end}" ]; then
      _wait_log "❌ ${desc} — deadline ${dl_int}s exceeded after $((attempt + 1)) attempt(s)"
      _wait_stat "${desc}" "${start}" "${dl_int}" timeout
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
    # exponential backoff
    cur_sleep="$(_wait_calc "${sleep_s} * (${backoff} ^ ${attempt})")"
    # jitter: +/- fraction, clamped >= 0
    cur_sleep="$(_wait_calc "j = ${cur_sleep} * (1 + ${jitter} * ((${RANDOM} / 32767.0) * 2 - 1)); (j < 0) ? 0 : j")"
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
  WAIT_DEADLINE_SCALE=1 _wait_retry "${half}" "exists ${kind}/${name} ${ns_args}" \
    "kubectl ${ns_args} get ${kind} ${name} >/dev/null 2>&1" || return 1

  # Phase 2: readiness within whatever budget remains.
  local remaining; remaining="$(_wait_calc "${scaled} - (${SECONDS} - ${start})")"; remaining="${remaining%%.*}"
  [ "${remaining}" -lt 15 ] && remaining=15
  _wait_log "⏳ ready ${kind}/${name} ${ns_args} (--for=${cond}, ${remaining}s left)"
  if kubectl ${ns_args} wait "${kind}/${name}" "--for=${cond}" "--timeout=${remaining}s"; then
    _wait_stat "ready ${kind}/${name} ${ns_args}" "${start}" "${scaled}" ok
  else
    _wait_stat "ready ${kind}/${name} ${ns_args}" "${start}" "${scaled}" timeout
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
  WAIT_DEADLINE_SCALE=1 _wait_retry "${half}" "exists deploy/${name} ${ns_args}" \
    "kubectl ${ns_args} get deploy ${name} >/dev/null 2>&1" || return 1
  local remaining; remaining="$(_wait_calc "${scaled} - (${SECONDS} - ${start})")"; remaining="${remaining%%.*}"
  [ "${remaining}" -lt 15 ] && remaining=15
  _wait_log "⏳ rollout deploy/${name} ${ns_args} (${remaining}s left)"
  if kubectl ${ns_args} rollout status "deploy/${name}" "--timeout=${remaining}s"; then
    _wait_stat "rollout deploy/${name} ${ns_args}" "${start}" "${scaled}" ok
  else
    _wait_stat "rollout deploy/${name} ${ns_args}" "${start}" "${scaled}" timeout
    return 1
  fi
}

# wait_flux_ready <kind> <name> [-n ns] [deadline_s]  — Flux Kustomization/
# ResourceSet Ready. Existence-first, then wait on the Ready condition.
wait_flux_ready() {
  local kind="${1:?kind required}"; local name="${2:?name required}"; shift 2
  wait_k8s_ready "${kind}" "${name}" "$@" --for "condition=ready"
}

# wait_pods_ready <selector> [-n ns] [deadline_s]  — all matching pods Ready.
# Correct "all containers actually ready" semantics (kwaitpod-ready): requires
# at least one matching pod AND none not-ready.
wait_pods_ready() {
  local selector="${1:?selector required}"; shift
  local ns_args="" deadline=300
  while [ $# -gt 0 ]; do case "$1" in
    -n) ns_args="-n $2"; shift 2 ;;
    *)  deadline="$1"; shift ;;
  esac; done
  _wait_retry "${deadline}" "pods ready ${selector} ${ns_args}" "
    out=\$(kubectl ${ns_args} get pods -l '${selector}' \
      -o 'jsonpath={range .items[*]}{.status.containerStatuses[*].ready}{\"\n\"}{end}' 2>/dev/null)
    [ -n \"\$out\" ] && ! printf '%s' \"\$out\" | grep -q false
  "
}
