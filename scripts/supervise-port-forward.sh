#!/usr/bin/env bash
# supervise-port-forward.sh — keep a kubectl port-forward alive across long gaps.
#
# Subcommands:
#   up      STATE_DIR NAMESPACE SERVICE LOCAL_PORT REMOTE_PORT PROBE_PATH OWNER_PID
#   ensure  STATE_DIR
#   down    STATE_DIR
#
# ─── The defect ─────────────────────────────────────────────────────────────
#
# The Makefile recipes that publish images to Zot used to start one bare
# `kubectl port-forward`, prove `/v2/` answered once, then spend minutes inside
# parallel Docker builds before they touched the registry again. That first
# probe only proved the forward was alive BEFORE the expensive work.
#
# On 2026-08-13 both GCP CI lanes showed why that is unsound. The first attempt
# in each lane reached the post-build push window with a dead forward and failed
# on `curl` exit 7. The pipeline retried and the second attempt passed, which
# masked the underlying defect and still burned a full retry cycle. The forward
# dies for reasons unrelated to the caller's logic: apiserver SPDY drops, pod
# restarts, network blips, or any other condition that kills the stream while
# the build is still running.
#
# ─── Why this script is shaped this way ─────────────────────────────────────
#
# `up` persists the intent in a small state directory, starts the child
# `kubectl port-forward`, then starts a supervisor loop that keeps probing the
# actual HTTP endpoint callers depend on. A listening socket is not enough here:
# the build recipes need a registry that answers `/v2/`, not merely a bound
# localhost port.
#
# `ensure` is the hot path. It probes once and returns immediately when the
# registry answers. When it does not, it waits only long enough for the
# supervisor to repair the forward, then fails loudly and boundedly with the
# exact endpoint and log location.
#
# `down` kills only the pids recorded in the state directory. Pattern-matching
# processes from inside a wrapped shell is how this repo has self-killed the
# calling shell before; teardown here is PID-file-only on purpose.
#
# The supervisor records ITS OWN pid from inside the long-running process. This
# copies the lesson already paid for in scripts/public-tunnel.sh: recording `$!`
# of a launcher only records the short-lived launcher, not the durable loop the
# caller must later stop.
#
# The owner-pid guard is load-bearing. A hard-killed parent skips its EXIT trap;
# without an owner liveness check the supervisor becomes the new bug by keeping
# an orphaned kubectl alive and rebinding the port for the next run.
#
# ─── Three optional knobs, added for the GCP demo Gateway forward ───────────
#
# Everything above was written for the in-cluster Zot registry: a plaintext HTTP
# endpoint on loopback. scripts/gcp-tf/demo-pipeline.sh needs the same
# supervision for the Envoy Gateway, which differs on all three counts, so each
# assumption that was previously baked in is now a variable with the old value
# as its default. An unset knob reproduces the previous behaviour byte for byte,
# which is why the Makefile callers are untouched.
#
#   PF_ADDRESS         kubectl --address. Unset (kubectl's own localhost
#                      default) for the registry, because nothing outside the
#                      VM may reach a build-time registry. 0.0.0.0 for the demo
#                      Gateway, because the operator arrives over a Google IAP
#                      tunnel that connects to the instance's INTERNAL IP —
#                      a loopback-only listener is unreachable from there and
#                      fails in a way that looks like a firewall problem.
#
#   PF_PROBE_URL       Full probe URL, replacing http://localhost:PORT/PATH.
#                      The Gateway speaks TLS on 443 and selects its route by
#                      SNI, so the health of that forward cannot be expressed as
#                      a path on a plaintext localhost URL.
#
#   PF_PROBE_CURL_OPTS Extra curl options, word-split. The Gateway needs -k (the
#                      demo certificate is self-signed) and --resolve (the SNI
#                      name dashboard.osramp.acme.local has no DNS record by
#                      design — the browser side resolves it through Chrome's
#                      --host-resolver-rules, and curl needs the same trick).
#
# All three are persisted into config.env by write_config rather than being read
# from the environment at probe time. The supervisor is a background grandchild
# and `ensure`/`down` are separate invocations from other shells; recording the
# intent in the state directory is how the rest of this script already survives
# that, and an env-var-only knob would work in `up` and silently revert to the
# registry defaults in every later respawn.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
CURL_BIN="${CURL_BIN:-curl}"

# The single greppable marker for a respawn. cmd_down counts these to report how
# often the forward actually had to be repaired, so it must not drift from what
# supervisor_loop writes.
RESTART_MARKER='restart #'

log()  { printf '\033[1;36m[port-forward]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[port-forward] ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[port-forward] !\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[port-forward] FAILED:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
usage:
  scripts/supervise-port-forward.sh up STATE_DIR NAMESPACE SERVICE LOCAL_PORT REMOTE_PORT PROBE_PATH OWNER_PID
  scripts/supervise-port-forward.sh ensure STATE_DIR
  scripts/supervise-port-forward.sh down STATE_DIR
EOF
  exit 1
}

timestamp() {
  date -Is
}

config_file() {
  printf '%s/config.env\n' "$1"
}

forward_pid_file() {
  printf '%s/forward.pid\n' "$1"
}

supervisor_pid_file() {
  printf '%s/supervisor.pid\n' "$1"
}

forward_log_file() {
  printf '%s/forward.log\n' "$1"
}

append_log() {
  local log_file="$1"
  local message="$2"
  printf '%s %s\n' "$(timestamp)" "$message" >>"$log_file"
}

state_endpoint() {
  # PF_PROBE_URL wins when set. Everything that reports on this forward —
  # cmd_ensure's "restored after Ns" line, cmd_up's success line, every fail()
  # message — routes through here, so a caller that overrides the probe gets its
  # real endpoint named in the diagnostics rather than a localhost URL nothing
  # ever contacted.
  if [ -n "${PF_PROBE_URL:-}" ]; then
    printf '%s' "$PF_PROBE_URL"
    return 0
  fi
  printf 'http://localhost:%s%s' "$LOCAL_PORT" "$PROBE_PATH"
}

write_config() {
  local state_dir="$1"
  local namespace="$2"
  local service="$3"
  local local_port="$4"
  local remote_port="$5"
  local probe_path="$6"
  local owner_pid="$7"
  local file

  file="$(config_file "$state_dir")"
  {
    printf 'NAMESPACE=%q\n' "$namespace"
    printf 'SERVICE=%q\n' "$service"
    printf 'LOCAL_PORT=%q\n' "$local_port"
    printf 'REMOTE_PORT=%q\n' "$remote_port"
    printf 'PROBE_PATH=%q\n' "$probe_path"
    printf 'OWNER_PID=%q\n' "$owner_pid"
    # Read from the environment rather than taken as positional arguments: they
    # are optional, and adding three more positions would break every existing
    # caller's `[ "$#" -eq 7 ]` contract. Persisted unconditionally (empty when
    # unset) so a state directory always describes its own probe completely, and
    # so load_config cannot leave a stale value from the calling shell in place.
    printf 'PF_ADDRESS=%q\n' "${PF_ADDRESS:-}"
    printf 'PF_PROBE_URL=%q\n' "${PF_PROBE_URL:-}"
    printf 'PF_PROBE_CURL_OPTS=%q\n' "${PF_PROBE_CURL_OPTS:-}"
  } >"$file"
}

# Populated by load_config() sourcing config.env, which is how `ensure` and the
# supervisor recover the intent recorded by `up` without retaking every argument.
# Declared here so the state a subcommand depends on is visible at a glance, and
# so shellcheck stops reading them as misspellings of the locals they are built
# from (SC2153).
NAMESPACE=""
SERVICE=""
LOCAL_PORT=""
REMOTE_PORT=""
PROBE_PATH=""
OWNER_PID=""
# The three optional knobs documented in the header. Declared alongside the
# required config for the same two reasons: the state a subcommand depends on is
# visible in one place, and shellcheck can see they are deliberate globals.
# Empty is the meaningful default in every case — it selects the original
# registry behaviour.
PF_ADDRESS="${PF_ADDRESS:-}"
PF_PROBE_URL="${PF_PROBE_URL:-}"
PF_PROBE_CURL_OPTS="${PF_PROBE_CURL_OPTS:-}"

load_config() {
  local state_dir="$1"
  local file

  file="$(config_file "$state_dir")"
  [ -f "$file" ] || fail "missing config in ${state_dir}; run 'up' before 'ensure'"
  # shellcheck disable=SC1090
  source "$file"
}

probe_endpoint() {
  # stderr is discarded because this is a POLL, not a verdict. `up` probes once a
  # second for up to 30s and `ensure` for up to 60s, so with -S every second of a
  # merely-slow zot printed another
  #
  #   curl: (7) Failed to connect to localhost port 5001 after 0 ms
  #
  # into the build log. That is the exact string CI emitted the day the forward
  # really did die, so a reader could not tell a healthy slow start from the
  # failure this supervisor exists to prevent — and on a fresh cluster it appears
  # on every single run. The inline loop this replaced suppressed it for the same
  # reason (`curl ... >/dev/null 2>&1`); dropping that was a regression, not a
  # deliberate change.
  #
  # No diagnosis is lost. Every caller that gives up calls fail(), which names the
  # namespace, service, local and remote ports and the probe path, and points at
  # the forward log holding kubectl's own stderr.
  # Word-split on purpose: PF_PROBE_CURL_OPTS carries multiple curl options
  # (-k plus a --resolve pair). `read -ra` splits once, into an array, so no
  # unquoted expansion reaches curl and an option containing no whitespace
  # survives verbatim. The `+` expansion is the only form safe under `set -u`
  # for a possibly-empty array.
  local -a probe_opts=()
  if [ -n "${PF_PROBE_CURL_OPTS:-}" ]; then
    read -r -a probe_opts <<<"$PF_PROBE_CURL_OPTS"
  fi
  "$CURL_BIN" -fs ${probe_opts[@]+"${probe_opts[@]}"} \
    --max-time "${PF_PROBE_TIMEOUT:-5}" "$(state_endpoint)" >/dev/null 2>&1
}

pid_from_file() {
  local pid_file="$1"
  local pid=""

  if [ -f "$pid_file" ]; then
    IFS= read -r pid <"$pid_file" || true
  fi
  printf '%s' "$pid"
}

pid_is_zombie() {
  local pid="$1"
  local line=""
  local state=""

  if [ -r "/proc/${pid}/stat" ]; then
    IFS= read -r line <"/proc/${pid}/stat" || return 1
    state="${line#*) }"
    state="${state%% *}"
    [ "$state" = "Z" ]
    return
  fi

  state="$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')" || true
  case "$state" in
    Z*) return 0 ;;
  esac
  return 1
}

pid_running() {
  local pid="$1"

  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # A zombie still answers kill -0. Treat it as dead so a killed child does not
  # block restart forever waiting for a reap that has not happened yet.
  ! pid_is_zombie "$pid"
}

validate_owner_pid() {
  local owner_pid="$1"

  case "$owner_pid" in
    ''|*[!0-9]*)
      fail "OWNER_PID must be a live numeric pid at 'up' time; received [${owner_pid}]"
      ;;
  esac

  if ! kill -0 "$owner_pid" 2>/dev/null; then
    fail "OWNER_PID must be a live numeric pid at 'up' time; received [${owner_pid}]"
  fi

  if pid_is_zombie "$owner_pid"; then
    fail "OWNER_PID must be a live numeric pid at 'up' time; received [${owner_pid}]"
  fi
}

wait_for_exit() {
  local pid="$1"
  local timeout="${2:-5}"
  local deadline

  deadline=$((SECONDS + timeout))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      return 1
    fi
    sleep 0.2
  done
  return 0
}

stop_pid_file() {
  local pid_file="$1"
  local label="$2"
  local pid=""
  local kill_timeout="${PF_KILL_TIMEOUT:-5}"

  pid="$(pid_from_file "$pid_file")"
  if [ -z "$pid" ]; then
    rm -f "$pid_file"
    return 0
  fi

  if ! pid_running "$pid"; then
    rm -f "$pid_file"
    return 0
  fi

  if kill "$pid" 2>/dev/null; then
    :
  elif pid_running "$pid"; then
    fail "could not send TERM to ${label} pid ${pid}"
  else
    rm -f "$pid_file"
    return 0
  fi

  if wait_for_exit "$pid" "$kill_timeout"; then
    rm -f "$pid_file"
    return 0
  fi

  if kill -9 "$pid" 2>/dev/null; then
    :
  elif pid_running "$pid"; then
    fail "could not send KILL to ${label} pid ${pid}"
  fi

  if wait_for_exit "$pid" "$kill_timeout"; then
    rm -f "$pid_file"
    return 0
  fi

  fail "${label} pid ${pid} survived TERM and KILL after ${kill_timeout}s each"
}

spawn_forward() {
  local state_dir="$1"
  local pid_file
  local log_file
  local child_pid

  pid_file="$(forward_pid_file "$state_dir")"
  log_file="$(forward_log_file "$state_dir")"

  # An empty PF_ADDRESS must produce the ORIGINAL argument vector, not
  # `--address ''` — kubectl rejects an empty address, and the registry callers
  # that set nothing would have started failing on a change advertised as
  # backwards compatible.
  local -a address_args=()
  if [ -n "${PF_ADDRESS:-}" ]; then
    address_args=(--address "$PF_ADDRESS")
  fi

  append_log "$log_file" "starting kubectl -n ${NAMESPACE} port-forward ${PF_ADDRESS:+--address ${PF_ADDRESS} }svc/${SERVICE} ${LOCAL_PORT}:${REMOTE_PORT}"
  "$KUBECTL_BIN" -n "$NAMESPACE" port-forward \
    ${address_args[@]+"${address_args[@]}"} \
    "svc/${SERVICE}" "${LOCAL_PORT}:${REMOTE_PORT}" >>"$log_file" 2>&1 &
  child_pid=$!
  printf '%s\n' "$child_pid" >"$pid_file"
}

supervisor_loop() {
  local state_dir="$1"
  local log_file
  local supervisor_file
  local forward_file
  local restarts=0

  load_config "$state_dir"
  log_file="$(forward_log_file "$state_dir")"
  supervisor_file="$(supervisor_pid_file "$state_dir")"
  forward_file="$(forward_pid_file "$state_dir")"

  printf '%s\n' "$$" >"$supervisor_file"
  append_log "$log_file" "supervisor started for ${NAMESPACE}/svc/${SERVICE} on localhost:${LOCAL_PORT}"

  while true; do
    sleep "${PF_POLL_INTERVAL:-2}"

    # pid_running, not a bare kill -0: an owner that has exited but not yet been
    # reaped is a zombie, and a zombie answers kill -0. Reading that as "owner
    # still alive" keeps the supervisor — and its kubectl — running past the
    # death of the thing it exists to serve.
    if ! pid_running "$OWNER_PID"; then
      append_log "$log_file" "owner pid ${OWNER_PID} exited; stopping supervised forward"
      stop_pid_file "$forward_file" "port-forward child"
      rm -f "$supervisor_file"
      exit 0
    fi

    if probe_endpoint; then
      continue
    fi

    restarts=$((restarts + 1))
    append_log "$log_file" "${RESTART_MARKER}${restarts}: probe failed at $(state_endpoint), respawning kubectl port-forward"
    stop_pid_file "$forward_file" "port-forward child"
    spawn_forward "$state_dir"
  done
}

cmd_up() {
  [ "$#" -eq 7 ] || usage

  local state_dir="$1"
  local namespace="$2"
  local service="$3"
  local local_port="$4"
  local remote_port="$5"
  local probe_path="$6"
  local owner_pid="$7"
  local timeout="${PF_UP_TIMEOUT:-30}"
  local deadline
  local log_file
  local supervisor_pid

  mkdir -p "$state_dir"
  cmd_down "$state_dir"
  mkdir -p "$state_dir"

  validate_owner_pid "$owner_pid"
  write_config "$state_dir" "$namespace" "$service" "$local_port" "$remote_port" "$probe_path" "$owner_pid"
  log_file="$(forward_log_file "$state_dir")"
  : >"$log_file"

  load_config "$state_dir"
  spawn_forward "$state_dir"
  "$SCRIPT_PATH" __supervise "$state_dir" >/dev/null 2>&1 &
  supervisor_pid=$!
  # This supervisor is fork+exec'd directly, so $! is the durable loop itself.
  # That is unlike public-tunnel.sh's setsid launcher, where $! is only the
  # short-lived launcher and cannot be trusted as the long-running owner.
  printf '%s\n' "$supervisor_pid" >"$(supervisor_pid_file "$state_dir")"

  deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if probe_endpoint; then
      ok "registry ${NAMESPACE}/svc/${SERVICE} answering at $(state_endpoint)"
      return 0
    fi
    sleep 1
  done

  cmd_down "$state_dir"
  fail "registry ${NAMESPACE}/svc/${SERVICE} on localhost:${LOCAL_PORT}->${REMOTE_PORT}${PROBE_PATH} stayed unreachable for ${timeout}s; check ${log_file}"
}

cmd_ensure() {
  [ "$#" -eq 1 ] || usage

  local state_dir="$1"
  local timeout="${PF_ENSURE_TIMEOUT:-60}"
  local deadline
  local log_file
  local supervisor_pid=""
  local started

  load_config "$state_dir"
  # Hot path: this runs before every push, so a healthy forward says nothing.
  if probe_endpoint; then
    return 0
  fi

  started=$SECONDS
  deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 1
    if probe_endpoint; then
      # Surfaced from the foreground command, not from the supervisor: the
      # supervisor's stdout and stderr are deliberately detached so kubectl's
      # own noise stays out of the build log. This line is therefore the only
      # way a repair becomes visible to CI, and a repair that nobody can see is
      # indistinguishable from a code path that never ran.
      printf 'supervise-port-forward: forward was down at %s, restored after %ss\n' \
        "$(state_endpoint)" "$((SECONDS - started))"
      return 0
    fi
  done

  log_file="$(forward_log_file "$state_dir")"
  supervisor_pid="$(pid_from_file "$(supervisor_pid_file "$state_dir")")"
  if [ -n "$supervisor_pid" ] && pid_running "$supervisor_pid"; then
    fail "supervised port-forward could not be restored at $(state_endpoint) within ${timeout}s; check ${log_file}"
  fi

  fail "supervised port-forward could not be restored at $(state_endpoint) within ${timeout}s because the supervisor is not running; check ${log_file}"
}

cmd_down() {
  [ "$#" -eq 1 ] || usage

  local state_dir="$1"

  if [ ! -d "$state_dir" ]; then
    return 0
  fi

  stop_pid_file "$(supervisor_pid_file "$state_dir")" "port-forward supervisor"
  stop_pid_file "$(forward_pid_file "$state_dir")" "port-forward child"
  return 0
}

# The restart record lives in the state dir, and the Makefile's EXIT trap removes
# that dir immediately after tearing the forward down. Counting the restarts here
# — after the processes are stopped, so nothing can be missed — is what makes the
# evidence outlive the `rm -rf`.
report_restarts() {
  local state_dir="$1"
  local log_file
  local count

  log_file="$(forward_log_file "$state_dir")"
  # No log means no supervised session ever ran here: an idempotent second
  # `down`, or a state dir that never came up. Silence is the honest answer.
  [ -f "$log_file" ] || return 0

  # grep -c exits 1 when it counts nothing, which under `set -e` would abort the
  # teardown. It still prints the 0, so the guard costs nothing.
  count="$(grep -c "$RESTART_MARKER" "$log_file" 2>/dev/null || true)"
  [ -n "$count" ] || count=0

  # Printed even when the count is zero, deliberately. On a warm CI lane the
  # Docker layers are cached, the build window collapses, and the forward is
  # never stressed — so a green run is not evidence that supervision works, it
  # is evidence the code path never ran. An explicit zero tells those two apart;
  # silence leaves them indistinguishable, which is the exact unfalsifiable
  # green this whole change exists to remove.
  printf 'supervise-port-forward: %s restart(s) during this run\n' "$count"
}

main() {
  [ "$#" -gt 0 ] || usage

  case "$1" in
    up)
      shift
      cmd_up "$@"
      ;;
    ensure)
      shift
      cmd_ensure "$@"
      ;;
    down)
      shift
      [ "$#" -eq 1 ] || usage
      # Stop first, then count: a restart racing the teardown still gets
      # reported. cmd_up's internal cleanup deliberately does not report, since
      # any log it finds belongs to a previous run.
      cmd_down "$1"
      report_restarts "$1"
      ;;
    __supervise)
      shift
      [ "$#" -eq 1 ] || usage
      supervisor_loop "$1"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
