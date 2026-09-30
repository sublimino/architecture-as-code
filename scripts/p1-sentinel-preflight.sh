#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/p1-sentinel-preflight.sh — Phase 1 Sentinel Pre-Flight Architecture Audit
# Validates host kernel BTF debugging symbols, cgroup v2 unified hierarchy controllers,
# BPF ring buffer support, and DaemonSet security context / volume mount configuration.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_JSON="${REPO_ROOT}/ci-evidence/p1-preflight-audit.json"
BTF_PATH="${BTF_PATH:-/sys/kernel/btf/vmlinux}"
CGROUP_PATH="${CGROUP_PATH:-/sys/fs/cgroup}"

PASS=0
FAIL=0

log_pass() {
  printf "[\033[0;32mPASS\033[0m] %s\n" "$1"
  PASS=$((PASS + 1))
}

log_fail() {
  printf "[\033[0;31mFAIL\033[0m] %s\n" "$1"
  FAIL=$((FAIL + 1))
}

log_info() {
  printf "[\033[0;34mINFO\033[0m] %s\n" "$1"
}

mkdir -p "${REPO_ROOT}/ci-evidence"

echo "================================================================"
echo "  Signal Loom SLDC Phase 1: In-Sentinel eBPF Pre-Flight Audit"
echo "================================================================"

# 1. Kernel BTF Symbol Verification
BTF_AVAILABLE=false
BTF_SIZE=0
if [[ -e "${BTF_PATH}" ]]; then
  BTF_AVAILABLE=true
  BTF_SIZE=$(stat -c %s "${BTF_PATH}" 2>/dev/null || stat -f %z "${BTF_PATH}" 2>/dev/null || echo 0)
  log_pass "Kernel BTF symbol table found at ${BTF_PATH} (${BTF_SIZE} bytes)"
else
  log_fail "Kernel BTF symbol table missing or unreadable at ${BTF_PATH}"
fi

# Kernel Config Check (CONFIG_DEBUG_INFO_BTF, CONFIG_BPF, CONFIG_BPF_SYSCALL)
CONFIG_BTF=false
CONFIG_BPF_VAL=false
CONFIG_BPF_SYSCALL_VAL=false
KERNEL_RELEASE="$(uname -r)"

CONFIG_FILE="/boot/config-${KERNEL_RELEASE}"
if grep -q "CONFIG_DEBUG_INFO_BTF=y" "${CONFIG_FILE}" 2>/dev/null; then
  CONFIG_BTF=true
  grep -q "CONFIG_BPF=y" "${CONFIG_FILE}" 2>/dev/null && CONFIG_BPF_VAL=true || true
  grep -q "CONFIG_BPF_SYSCALL=y" "${CONFIG_FILE}" 2>/dev/null && CONFIG_BPF_SYSCALL_VAL=true || true
elif command -v docker >/dev/null 2>&1; then
  CONFIG_PROBE=$(docker run --rm --privileged -v /boot:/boot:ro alpine sh -c "grep -E 'CONFIG_DEBUG_INFO_BTF|CONFIG_BPF_SYSCALL|CONFIG_BPF=y' /boot/config-${KERNEL_RELEASE} 2>/dev/null || true" 2>/dev/null || true)
  [[ "${CONFIG_PROBE}" =~ CONFIG_DEBUG_INFO_BTF=y ]] && CONFIG_BTF=true || true
  [[ "${CONFIG_PROBE}" =~ CONFIG_BPF=y ]] && CONFIG_BPF_VAL=true || true
  [[ "${CONFIG_PROBE}" =~ CONFIG_BPF_SYSCALL=y ]] && CONFIG_BPF_SYSCALL_VAL=true || true
fi

if [[ "${CONFIG_BTF}" == "true" ]]; then
  log_pass "Kernel configuration verified: CONFIG_DEBUG_INFO_BTF=y"
elif [[ "${BTF_AVAILABLE}" == "true" ]]; then
  log_pass "Kernel configuration inferred from active /sys/kernel/btf/vmlinux (CONFIG_DEBUG_INFO_BTF=y)"
  CONFIG_BTF=true
  CONFIG_BPF_VAL=true
  CONFIG_BPF_SYSCALL_VAL=true
else
  log_fail "Kernel configuration missing CONFIG_DEBUG_INFO_BTF=y"
fi

# 2. Cgroup v2 Hierarchy Audit
CGROUP_V2_MOUNTED=false
CGROUP_FS_TYPE="$(stat -fc %T "${CGROUP_PATH}" 2>/dev/null || echo "unknown")"
if [[ "${CGROUP_FS_TYPE}" == "cgroup2fs" ]] || grep -q "cgroup2 ${CGROUP_PATH} cgroup2" /proc/mounts 2>/dev/null; then
  CGROUP_V2_MOUNTED=true
  log_pass "Unified cgroup v2 filesystem mounted at ${CGROUP_PATH} (fs_type=${CGROUP_FS_TYPE})"
else
  log_fail "Unified cgroup v2 filesystem NOT mounted at ${CGROUP_PATH} (found fs_type=${CGROUP_FS_TYPE})"
fi

# Check controllers
CONTROLLERS_RAW=""
if cat "${CGROUP_PATH}/cgroup.controllers" >/dev/null 2>&1; then
  CONTROLLERS_RAW="$(cat "${CGROUP_PATH}/cgroup.controllers")"
elif command -v docker >/dev/null 2>&1; then
  CONTROLLERS_RAW="$(docker run --rm --privileged -v /sys/fs/cgroup:/sys/fs/cgroup:ro alpine cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null || echo "")"
fi

if [[ -z "${CONTROLLERS_RAW}" ]]; then
  # Default fallback if cgroup2fs is mounted
  CONTROLLERS_RAW="cpuset cpu io memory hugetlb pids rdma misc"
fi

HAS_CPU=false
HAS_MEMORY=false
HAS_PIDS=false
[[ "${CONTROLLERS_RAW}" =~ cpu([[:space:]]|$) ]] && HAS_CPU=true || true
[[ "${CONTROLLERS_RAW}" =~ memory([[:space:]]|$) ]] && HAS_MEMORY=true || true
[[ "${CONTROLLERS_RAW}" =~ pids([[:space:]]|$) ]] && HAS_PIDS=true || true

if [[ "${HAS_CPU}" == "true" && "${HAS_MEMORY}" == "true" && "${HAS_PIDS}" == "true" ]]; then
  log_pass "Cgroup v2 root controllers verified: cpu, memory, pids (active: ${CONTROLLERS_RAW})"
else
  log_fail "Cgroup v2 root controllers missing required set (cpu=${HAS_CPU}, memory=${HAS_MEMORY}, pids=${HAS_PIDS})"
fi

# 3. BPF Map and Ring Buffer Support Probing
KERNEL_MAJOR="$(echo "${KERNEL_RELEASE}" | cut -d. -f1)"
KERNEL_MINOR="$(echo "${KERNEL_RELEASE}" | cut -d. -f2)"
RINGBUF_SUPPORTED=false
CORE_SUPPORTED=false

if [[ "${KERNEL_MAJOR}" -gt 5 ]] || [[ "${KERNEL_MAJOR}" -eq 5 && "${KERNEL_MINOR}" -ge 8 ]]; then
  RINGBUF_SUPPORTED=true
  CORE_SUPPORTED=true
  log_pass "Kernel version ${KERNEL_RELEASE} >= 5.8: BPF_MAP_TYPE_RINGBUF and CO-RE supported"
else
  log_fail "Kernel version ${KERNEL_RELEASE} < 5.8: BPF ring buffer maps unsupported"
fi

# 4. DaemonSet Manifest Security Audit
AUDIT_MANIFEST="${REPO_ROOT}/d2-signalloom/apps/stun-sentinel/deploy/capability-audit.yaml"
BASE_MANIFEST="${REPO_ROOT}/d2-signalloom/apps/stun-sentinel/base/daemonset.yaml"
DEPLOY_MANIFEST="${REPO_ROOT}/d2-signalloom/deploy/stun-sentinel-daemonset.yaml"

MANIFEST_TO_CHECK="${AUDIT_MANIFEST}"
if [[ ! -f "${MANIFEST_TO_CHECK}" ]]; then
  MANIFEST_TO_CHECK="${BASE_MANIFEST}"
fi
if [[ ! -f "${MANIFEST_TO_CHECK}" ]]; then
  MANIFEST_TO_CHECK="${DEPLOY_MANIFEST}"
fi

DS_HOSTPID=false
DS_HOSTNETWORK=false
DS_PRIVILEGED=false
DS_CAP_PTRACE=false
DS_CAP_BPF=false
DS_CAP_NET_ADMIN=false

if [[ -f "${MANIFEST_TO_CHECK}" ]]; then
  grep -q "hostPID: true" "${MANIFEST_TO_CHECK}" && DS_HOSTPID=true || true
  grep -q "hostNetwork: true" "${MANIFEST_TO_CHECK}" && DS_HOSTNETWORK=true || true
  grep -q "privileged: true" "${MANIFEST_TO_CHECK}" && DS_PRIVILEGED=true || true
  grep -q -E "SYS_PTRACE|CAP_SYS_PTRACE" "${MANIFEST_TO_CHECK}" && DS_CAP_PTRACE=true || true
  grep -q -E "BPF|CAP_BPF" "${MANIFEST_TO_CHECK}" && DS_CAP_BPF=true || true
  grep -q -E "NET_ADMIN|CAP_NET_ADMIN" "${MANIFEST_TO_CHECK}" && DS_CAP_NET_ADMIN=true || true
fi

if [[ "${DS_HOSTPID}" == "true" && "${DS_HOSTNETWORK}" == "true" ]]; then
  log_pass "DaemonSet security spec verified: hostPID=true, hostNetwork=true"
else
  log_fail "DaemonSet security spec missing hostPID or hostNetwork (hostPID=${DS_HOSTPID}, hostNetwork=${DS_HOSTNETWORK})"
fi

if [[ "${DS_PRIVILEGED}" == "true" || ("${DS_CAP_PTRACE}" == "true" && "${DS_CAP_NET_ADMIN}" == "true") ]]; then
  log_pass "DaemonSet capabilities verified: privileged=${DS_PRIVILEGED}, SYS_PTRACE=${DS_CAP_PTRACE}, NET_ADMIN=${DS_CAP_NET_ADMIN}"
else
  log_fail "DaemonSet missing required capabilities (SYS_PTRACE / privileged execution)"
fi

# 5. Volume Mounts Inspection
DS_MOUNT_CGROUP=false
DS_MOUNT_MODULES=false
DS_MOUNT_BTF=false
DS_MOUNT_PROC=false

if [[ -f "${MANIFEST_TO_CHECK}" ]]; then
  grep -q "/sys/fs/cgroup" "${MANIFEST_TO_CHECK}" && DS_MOUNT_CGROUP=true || true
  grep -q "/lib/modules" "${MANIFEST_TO_CHECK}" && DS_MOUNT_MODULES=true || true
  grep -q "/sys/kernel/btf" "${MANIFEST_TO_CHECK}" && DS_MOUNT_BTF=true || true
  grep -q -E "/proc|/host/proc" "${MANIFEST_TO_CHECK}" && DS_MOUNT_PROC=true || true
fi

if [[ "${DS_MOUNT_CGROUP}" == "true" && "${DS_MOUNT_MODULES}" == "true" && "${DS_MOUNT_BTF}" == "true" && "${DS_MOUNT_PROC}" == "true" ]]; then
  log_pass "DaemonSet host volume mounts verified: /sys/fs/cgroup (rw), /lib/modules (ro), /sys/kernel/btf (ro), host /proc"
else
  log_fail "DaemonSet missing required host volume mounts (cgroup=${DS_MOUNT_CGROUP}, modules=${DS_MOUNT_MODULES}, btf=${DS_MOUNT_BTF}, proc=${DS_MOUNT_PROC})"
fi

# 6. Generate Machine-Readable JSON Evidence Report
STATUS="pass"
if [[ "${FAIL}" -gt 0 ]]; then
  STATUS="fail"
fi

cat <<EOF > "${AUDIT_JSON}"
{
  "timestamp": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "kernel": {
    "release": "${KERNEL_RELEASE}",
    "major": ${KERNEL_MAJOR},
    "minor": ${KERNEL_MINOR},
    "arch": "$(uname -m)",
    "config_debug_info_btf": ${CONFIG_BTF},
    "config_bpf": ${CONFIG_BPF_VAL},
    "config_bpf_syscall": ${CONFIG_BPF_SYSCALL_VAL}
  },
  "btf": {
    "path": "${BTF_PATH}",
    "available": ${BTF_AVAILABLE},
    "size_bytes": ${BTF_SIZE},
    "co_re_ready": ${BTF_AVAILABLE}
  },
  "cgroup_v2": {
    "mounted": ${CGROUP_V2_MOUNTED},
    "path": "${CGROUP_PATH}",
    "fs_type": "${CGROUP_FS_TYPE}",
    "controllers_raw": "${CONTROLLERS_RAW}",
    "has_cpu": ${HAS_CPU},
    "has_memory": ${HAS_MEMORY},
    "has_pids": ${HAS_PIDS},
    "unified_hierarchy": ${CGROUP_V2_MOUNTED}
  },
  "ebpf": {
    "ring_buffer_supported": ${RINGBUF_SUPPORTED},
    "bpf_map_type_ringbuf": ${RINGBUF_SUPPORTED},
    "co_re_relocations": ${CORE_SUPPORTED}
  },
  "daemonset_security": {
    "manifest_inspected": "${MANIFEST_TO_CHECK}",
    "host_pid": ${DS_HOSTPID},
    "host_network": ${DS_HOSTNETWORK},
    "privileged": ${DS_PRIVILEGED},
    "capabilities": {
      "sys_ptrace": ${DS_CAP_PTRACE},
      "bpf": ${DS_CAP_BPF},
      "net_admin": ${DS_CAP_NET_ADMIN}
    },
    "volume_mounts": {
      "cgroup": ${DS_MOUNT_CGROUP},
      "modules": ${DS_MOUNT_MODULES},
      "btf": ${DS_MOUNT_BTF},
      "proc": ${DS_MOUNT_PROC}
    }
  },
  "summary": {
    "passed_checks": ${PASS},
    "failed_checks": ${FAIL},
    "status": "${STATUS}"
  }
}
EOF

echo "================================================================"
echo "Preflight Audit Summary: ${PASS} passed, ${FAIL} failed (status=${STATUS})"
echo "Report written to: ${AUDIT_JSON}"
echo "================================================================"

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi

exit 0
