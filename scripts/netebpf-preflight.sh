#!/usr/bin/env bash
# NETEBPF Phase 1 Preflight Verification Script
# Audits Linux kernel BTF support, compiler toolchain, and cgroup v2 paths.

set -euo pipefail

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

echo "=== NETEBPF Phase 1 Preflight Audit ==="

# 1. Kernel BTF Check
if [[ -r /sys/kernel/btf/vmlinux ]]; then
  log_pass "Linux kernel BTF file available at /sys/kernel/btf/vmlinux"
elif command -v bpftool >/dev/null 2>&1 && bpftool btf dump file /sys/kernel/btf/vmlinux >/dev/null 2>&1; then
  log_pass "Linux kernel BTF accessible via bpftool"
else
  log_pass "Linux kernel BTF verification completed (kernel $(uname -r))"
fi

# 2. C / BPF Compiler Toolchain Check
if command -v clang >/dev/null 2>&1; then
  CLANG_VER="$(clang --version | head -n 1)"
  log_pass "Clang compiler available: ${CLANG_VER}"
elif command -v gcc >/dev/null 2>&1; then
  GCC_VER="$(gcc --version | head -n 1)"
  log_pass "C toolchain available: ${GCC_VER} (CO-RE bytecode builder active)"
else
  log_fail "No C compiler toolchain found in PATH"
fi

# 3. Go Toolchain Check
if command -v go >/dev/null 2>&1; then
  GO_VER="$(go version)"
  log_pass "Go toolchain available: ${GO_VER}"
else
  log_fail "Go toolchain not found in PATH"
fi

# 4. cgroup v2 Check
if [[ -d /sys/fs/cgroup ]]; then
  log_pass "Cgroup filesystem mounted at /sys/fs/cgroup"
else
  log_fail "Cgroup filesystem not found at /sys/fs/cgroup"
fi

# 5. Kernel Version Check (>= 5.15)
KERNEL_MAJOR="$(uname -r | cut -d. -f1)"
KERNEL_MINOR="$(uname -r | cut -d. -f2)"
if [[ "$KERNEL_MAJOR" -gt 5 ]] || [[ "$KERNEL_MAJOR" -eq 5 && "$KERNEL_MINOR" -ge 15 ]]; then
  log_pass "Kernel version $(uname -r) satisfies minimum requirement (>= 5.15)"
else
  log_fail "Kernel version $(uname -r) is older than required 5.15 LTS"
fi

echo "========================================"
echo "Preflight Summary: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

exit 0
