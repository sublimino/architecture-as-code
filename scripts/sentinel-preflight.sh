#!/usr/bin/env bash
# STUNSWARM P1-PRE: prove the node prerequisites for the Sentinel.
# This is intentionally fail-closed. It never changes Kubernetes objects.
set -Euo pipefail

KIND_NODE_CONTAINER=${KIND_NODE_CONTAINER:-osramp-control-plane}
SPIRE_NAMESPACE=${SPIRE_NAMESPACE:-inf-bao}
SPIRE_SELECTOR=${SPIRE_SELECTOR:-app.kubernetes.io/name=spire-agent}
SPIRE_SOCKET=${SPIRE_SOCKET:-/run/spire/sockets/agent.sock}
OPENBAO_NAMESPACE=${OPENBAO_NAMESPACE:-inf-bao}
OPENBAO_SELECTOR=${OPENBAO_SELECTOR:-app.kubernetes.io/name=openbao}

failures=0
attached_devices=()
docker_config_dir=$(mktemp -d)

pass() { printf "PASS %-24s %s\n" "$1" "$2"; }
fail() { printf "FAIL %-24s %s\n" "$1" "$2" >&2; failures=$((failures + 1)); }
info() { printf "INFO %-24s %s\n" "$1" "$2"; }

node_exec() {
  if docker --config "$docker_config_dir" inspect "$KIND_NODE_CONTAINER" >/dev/null 2>&1; then
    docker --config "$docker_config_dir" exec "$KIND_NODE_CONTAINER" "$@"
  else
    "$@"
  fi
}

cleanup() {
  local device
  for device in "${attached_devices[@]}"; do
    node_exec tc qdisc del dev "$device" clsact >/dev/null 2>&1 || true
    info "tc-cleanup-$device" "removed preflight clsact qdisc"
  done
  rmdir "$docker_config_dir" 2>/dev/null || true
}
trap cleanup EXIT

printf "%s\n" "STUNSWARM P1-PRE sentinel preflight"
info "runtime" "node=${KIND_NODE_CONTAINER} spire=${SPIRE_NAMESPACE} socket=${SPIRE_SOCKET}"

if node_exec test -r /sys/fs/cgroup/cgroup.controllers; then
  pass cgroup-controllers readable
else
  fail cgroup-controllers "cgroup.controllers is unreadable"
fi

cgroup_type=$(node_exec stat -fc "%T" /sys/fs/cgroup 2>/dev/null || true)
if [ "$cgroup_type" = cgroup2fs ]; then
  pass cgroup-v2 "filesystem=${cgroup_type}"
else
  fail cgroup-v2 "expected cgroup2fs, got ${cgroup_type:-unresolved}"
fi

controllers=$(node_exec cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null || true)
for controller in cpu memory pids; do
  case " $controllers " in
    *" $controller "*) pass "cgroup-$controller" "controller present" ;;
    *) fail "cgroup-$controller" "required controller missing" ;;
  esac
done

if node_exec test -d /sys/fs/cgroup/kubepods.slice || node_exec test -d /sys/fs/cgroup/kubelet.slice/kubelet-kubepods.slice; then
  pass cgroup-kubepods "kubepods slice exists"
else
  fail cgroup-kubepods "kubepods slice is absent"
fi

if node_exec test -e /sys/fs/cgroup/cgroup.freeze || node_exec test -e /sys/fs/cgroup/kubelet.slice/cgroup.freeze; then
  pass cgroup-freeze "cgroup.freeze exists"
else
  fail cgroup-freeze "cgroup.freeze is absent"
fi

df_output=$(node_exec df -h /sys/fs/cgroup 2>/dev/null || true)
if [ -n "$df_output" ]; then
  pass cgroup-disk "$df_output"
else
  fail cgroup-disk "unable to read cgroup filesystem usage"
fi

jit=$(node_exec sh -c "cat /proc/sys/net/core/bpf_jit_enable 2>/dev/null" || true)
if [ "$jit" = 1 ] || [ "$(cat /proc/sys/net/core/bpf_jit_enable 2>/dev/null || true)" = 1 ]; then
  pass bpf-jit "enabled"
else
  fail bpf-jit "expected 1, got ${jit:-absent}"
fi

if node_exec sh -c "test -d /sys/fs/bpf && test -r /sys/kernel/btf/vmlinux"; then
  pass bpf-subsystem "BPF filesystem and kernel BTF are available"
else
  fail bpf-subsystem "kernel BPF support is unavailable"
fi

if node_exec sh -c "command -v tc" >/dev/null 2>&1; then
  pass tc-command "$(node_exec sh -c "command -v tc")"
else
  fail tc-command "tc is unavailable on the node"
fi

if node_exec sh -c "grep -q "^sch_clsact " /proc/modules" 2>/dev/null; then
  pass sch-clsact "module loaded"
else
  info sch-clsact "module not listed; tc may provide built-in support"
fi

probe_clsact() {
  local name=$1 device=$2 before add_stderr
  before=$(node_exec tc qdisc show dev "$device" 2>/dev/null || true)
  if [[ "$before" == *clsact* ]]; then
    pass "$name-present" "${device} already exposes clsact"
    return 0
  fi

  add_stderr=$(node_exec tc qdisc add dev "$device" clsact 2>&1) || {
    fail "$name-add" "${device}: ${add_stderr:-tc add failed}"
    return 0
  }
  if [ -n "$add_stderr" ]; then
    fail "$name-warning" "${device}: ${add_stderr}"
  else
    pass "$name-add" "${device}: attached without warnings"
  fi
  attached_devices+=("$device")
  if [[ "$(node_exec tc qdisc show dev "$device" 2>/dev/null || true)" == *clsact* ]]; then
    pass "$name-show" "${device}: clsact is observable"
  else
    fail "$name-show" "${device}: clsact is not observable"
  fi
}

if node_exec tc qdisc show dev lo >/dev/null 2>&1; then
  probe_clsact tc-lo lo
else
  fail tc-lo "loopback interface is unavailable"
fi

# shellcheck disable=SC2016
veth_interface=$(node_exec sh -c 'for p in /sys/class/net/*; do [ -e "$p" ] || continue; d="${p##*/}"; [ "$d" = "lo" ] && continue; printf "%s" "$d"; break; done' 2>/dev/null || true)
if [ -n "$veth_interface" ]; then
  pass tc-target "selected ${veth_interface}"
  probe_clsact tc-nonloopback "$veth_interface"
else
  fail tc-target "no container veth or dummy interface is available"
fi

spire_pod=$(kubectl -n "$SPIRE_NAMESPACE" get pods -l "$SPIRE_SELECTOR" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || true)
if [ -n "$spire_pod" ]; then
  pass spire-pod "${SPIRE_NAMESPACE}/${spire_pod}"
  spire_phase=$(kubectl -n "$SPIRE_NAMESPACE" get pod "$spire_pod" -o jsonpath="{.status.phase}" 2>/dev/null || true)
  if [ "$spire_phase" = Running ]; then
    pass spire-running "$spire_phase"
  else
    fail spire-running "${spire_phase:-unresolved}"
  fi
  spire_ready=$(kubectl -n "$SPIRE_NAMESPACE" get pod "$spire_pod" -o jsonpath="{.status.containerStatuses[0].ready}" 2>/dev/null || true)
  if [ "$spire_ready" = true ]; then
    pass spire-ready "one ready container"
  else
    fail spire-ready "ready=${spire_ready:-unresolved}"
  fi
  health_output=$(kubectl -n "$SPIRE_NAMESPACE" exec "$spire_pod" -- /opt/spire/bin/spire-agent healthcheck -socketPath "$SPIRE_SOCKET" 2>&1) || {
    fail spire-socket "${health_output:-healthcheck failed}"
  }
  if [ -n "${health_output:-}" ]; then
    pass spire-response "${health_output}"
  fi
else
  fail spire-pod "no pod matches ${SPIRE_NAMESPACE}/${SPIRE_SELECTOR}"
fi

openbao_pod=$(kubectl -n "$OPENBAO_NAMESPACE" get pods -l "$OPENBAO_SELECTOR" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || true)
if [ -n "$openbao_pod" ]; then
  pass openbao-pod "${OPENBAO_NAMESPACE}/${openbao_pod}"
  bao_phase=$(kubectl -n "$OPENBAO_NAMESPACE" get pod "$openbao_pod" -o jsonpath="{.status.phase}" 2>/dev/null || true)
  if [ "$bao_phase" = Running ]; then
    pass openbao-running "$bao_phase"
  else
    fail openbao-running "${bao_phase:-unresolved}"
  fi
  bao_ready=$(kubectl -n "$OPENBAO_NAMESPACE" get pod "$openbao_pod" -o jsonpath="{.status.containerStatuses[0].ready}" 2>/dev/null || true)
  if [ "$bao_ready" = true ]; then
    pass openbao-ready "one ready container"
  else
    fail openbao-ready "ready=${bao_ready:-unresolved}"
  fi
  bao_status=$(kubectl -n "$OPENBAO_NAMESPACE" exec "$openbao_pod" -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 bao status -format=json' 2>&1) || {
    fail openbao-status "${bao_status:-status command failed}"
  }
  if echo "$bao_status" | grep -q '"initialized": true' && echo "$bao_status" | grep -q '"sealed": false'; then
    pass openbao-status "initialized=true sealed=false"
  else
    fail openbao-status "not initialized and unsealed: ${bao_status:-empty}"
  fi
else
  fail openbao-pod "no pod matches ${OPENBAO_NAMESPACE}/${OPENBAO_SELECTOR}"
fi

if [ "$failures" -eq 0 ]; then
  printf "RESULT PASS assertions=0 failures=0\n"
else
  printf "RESULT FAIL failures=%s\n" "$failures" >&2
fi
exit "$failures"
