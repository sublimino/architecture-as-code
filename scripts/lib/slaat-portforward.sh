# shellcheck shell=bash
# slaat-portforward.sh — resilient, auto-restarting kubectl port-forward helper.
#
# SLAAT-P1-1 (Ingress Gateway & Network Isolation Attack Probing) found that a
# single `kubectl port-forward` dies on its FIRST reset connection -- not after
# a pod rollout (the case the P1-PRE errata already documented), but on any
# malformed/adversarial request that resets the proxied TCP stream. Observed
# live against envoy-ingress-cluster-*: a bare IP connection with no SNI hit
# Envoy's `filter_chain_not_found` path, which resets the stream, which kills
# the whole `kubectl port-forward` process ("error: lost connection to pod")
# rather than just that one request. An adversarial probe suite that sends
# deliberately malformed requests will trigger this on almost every run, so the
# forward must supervise-and-restart, not assume a connection is still live
# because the service existed when the suite started.
#
# slaat_portforward_start NS SERVICE LOCAL_PORT REMOTE_PORT LOGFILE
#   Starts a background supervisor loop (setsid, all three fds redirected --
#   see the CLAUDE.md rule on backgrounding across tool calls) that restarts
#   kubectl port-forward on any exit, with a 1s backoff. Echoes the
#   supervisor's PID on stdout.
#
# slaat_portforward_wait_ready HOST PORT [DEADLINE]
#   Blocks until a bare TCP connect to HOST:PORT succeeds, or DEADLINE (default
#   20s) elapses. Safe to call before every single probe, not just once at
#   startup -- that is what makes the suite survive the kill-on-reset failure
#   mode above: each probe waits for the (possibly just-restarted) forward to
#   come back before it sends its request.
#
# slaat_portforward_stop SUPERVISOR_PID
#   Kills the supervisor and any kubectl port-forward child it is currently
#   running. Safe to call even if the PID is already gone.

slaat_portforward_start() {
  local ns="${1:?namespace required}" svc="${2:?service required}"
  local local_port="${3:?local port required}" remote_port="${4:?remote port required}"
  local logfile="${5:?logfile required}"
  local ctx="${SLAAT_KUBE_CONTEXT:-kind-osramp}"

  : >"${logfile}"
  (
    while :; do
      {
        echo "[slaat-portforward] $(date -u +%FT%TZ) starting ${svc} ${local_port}:${remote_port}"
        kubectl --context "${ctx}" -n "${ns}" port-forward "${svc}" "${local_port}:${remote_port}"
        echo "[slaat-portforward] $(date -u +%FT%TZ) port-forward exited rc=$?, restarting in 1s"
      } >>"${logfile}" 2>&1
      sleep 1
    done
  ) </dev/null >>"${logfile}" 2>&1 &
  disown
  echo "$!"
}

slaat_portforward_wait_ready() {
  local host="${1:?host required}" port="${2:?port required}" deadline="${3:-20}"
  local start now
  start=$(date +%s)
  while :; do
    if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
      exec 3>&- 3<&- 2>/dev/null
      return 0
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "${deadline}" ]; then
      return 1
    fi
    sleep 0.3
  done
}

slaat_portforward_stop() {
  local supervisor_pid="${1:-}"
  [ -z "${supervisor_pid}" ] && return 0
  # Kill the supervisor's process group is overkill and risks matching an
  # unrelated PID that was recycled; target the exact PID tree we started.
  pkill -P "${supervisor_pid}" 2>/dev/null || true
  kill "${supervisor_pid}" 2>/dev/null || true
}
