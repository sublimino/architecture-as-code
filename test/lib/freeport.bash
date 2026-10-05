# shellcheck shell=bash
# free_port: hand out a TCP port that nothing is listening on right now.
#
# Why this exists: a bats test that hardcodes a port owns a machine-global name.
# Two concurrent runs of the same suite then either collide (EADDRINUSE on the
# second) or — worse — the second one skips itself and silently loses coverage,
# which is what test/p2-dualcluster-preflight.bats did with port 34788.
#
# Honest about what it is: this is an ask-then-bind, so there is a window between
# "I found 49213 free" and "I bound 49213". The window is unavoidable for a
# caller that must know the port BEFORE the server starts (nc, a preflight script
# told which port to gate). Two defences:
#   - the kernel picks the candidate, by binding port 0 and reading back what it
#     got, so two concurrent callers get different answers rather than racing on
#     the same guess from a fixed base
#   - FREE_PORT_EXCLUDE lets one test hold several ports at once without
#     handing out the same one twice
# Where the caller can bind port 0 itself and read the result afterwards, do that
# instead — it has no window at all. That is what
# test/afm-rbac-exporter-push.bats does, and it is the better pattern.
#
# @id    freeport
# @doc   docs/signalloom/runbooks/parallel-tests.md
# @tests test/freeport-lib.bats

# free_port [count]
# Echoes `count` (default 1) space-separated free ports, each distinct.
free_port() {
  local want="${1:-1}" got=() p tries
  local -a exclude=()
  # shellcheck disable=SC2206
  [ -z "${FREE_PORT_EXCLUDE:-}" ] || exclude=(${FREE_PORT_EXCLUDE})
  while [ "${#got[@]}" -lt "$want" ]; do
    tries=0
    while :; do
      p="$(_free_port_one)" || return 1
      # distinct from what this call already handed out, and from the caller's
      # own held set
      if ! _free_port_in "$p" "${got[@]:-}" && ! _free_port_in "$p" "${exclude[@]:-}"; then
        break
      fi
      tries=$((tries + 1))
      [ "$tries" -lt 50 ] || { echo "free_port: no distinct port after 50 tries" >&2; return 1; }
    done
    got+=("$p")
  done
  echo "${got[@]}"
}

_free_port_in() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [ "$x" != "$needle" ] || return 0; done
  return 1
}

# _free_port_one: bind :0, read back the kernel's choice, release it.
# python3 is the primary because it is already a hard dependency of this suite
# (SLDC_OFFLINE_BATS runs pytest). The bash fallback exists so the library does
# not silently become a python dependency for a one-line need.
_free_port_one() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()' && return 0
  fi
  _free_port_probe
}

# _free_port_probe: walk the ephemeral range from a random offset, returning the
# first port that refuses a connection. Strictly worse than the :0 bind (a port
# that refuses a connect is not necessarily bindable), so it is the fallback.
_free_port_probe() {
  local lo=20000 hi=60000 span=40000 start p i
  start=$(( (RANDOM * 32768 + RANDOM) % span ))
  for ((i = 0; i < 500; i++)); do
    p=$(( lo + (start + i) % span ))
    if command -v ss >/dev/null 2>&1; then
      ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE ":${p}\$" && continue
    fi
    if ! (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then
      echo "$p"; return 0
    fi
    exec 3>&- 2>/dev/null || true
  done
  echo "free_port: no free port in ${lo}-${hi}" >&2
  return 1
}

# wait_for_listen PORT [timeout_seconds]
# Poll until PORT appears in LISTEN state, WITHOUT connecting to it.
#
# Use this, not wait_for_port, for a one-shot listener. `nc -l` without -k
# accepts exactly one connection and exits, so a readiness probe that dials the
# port consumes the listener and the thing under test then finds nothing bound.
# That cost one silently-vanished bats test in p2-dualcluster-preflight.
wait_for_listen() {
  local port="$1" budget="${2:-10}"
  local scale="${TEST_TIMEOUT_SCALE:-1}"
  local deadline=$(( $(date +%s) + budget * scale ))
  command -v ss >/dev/null 2>&1 || { sleep 0.5; return 0; }
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE ":${port}\$"; then
      return 0
    fi
    sleep 0.05
  done
  echo "wait_for_listen: nothing listening on :${port} within $(( budget * scale ))s" >&2
  return 1
}

# wait_for_port HOST PORT [timeout_seconds]
# Poll until something accepts on HOST:PORT. Scaled by TEST_TIMEOUT_SCALE so a
# loaded host gets proportionally longer, without changing what is asserted.
wait_for_port() {
  local host="$1" port="$2" budget="${3:-10}"
  local scale="${TEST_TIMEOUT_SCALE:-1}"
  local deadline=$(( $(date +%s) + budget * scale ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
      exec 3>&- 2>/dev/null || true
      return 0
    fi
    sleep 0.05
  done
  echo "wait_for_port: ${host}:${port} never accepted within $(( budget * scale ))s" >&2
  return 1
}
