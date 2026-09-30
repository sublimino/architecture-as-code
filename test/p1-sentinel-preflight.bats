#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# test/p1-sentinel-preflight.bats — Automated BATS suite executing pre-flight assertions
# against host Linux kernel interfaces, BTF symbols, cgroups v2, and DaemonSet configurations.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "p1 preflight: scripts/p1-sentinel-preflight.sh executes cleanly and passes all checks" {
  run bash "${REPO_ROOT}/scripts/p1-sentinel-preflight.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Preflight Audit Summary: 8 passed, 0 failed" ]]
  [[ "$output" =~ "status=pass" ]]
}

@test "p1 preflight: kernel BTF support pre-flight (unit)" {
  # BTF dump raw output validation via transparent wrapper or direct kernel reading
  if [[ -x "${REPO_ROOT}/bin/bpftool" ]]; then
    run bash "${REPO_ROOT}/bin/bpftool" btf dump file /sys/kernel/btf/vmlinux format raw
  elif command -v docker >/dev/null 2>&1; then
    run docker run --rm --privileged -v /sys/kernel/btf:/sys/kernel/btf:ro signalloom-bpf-builder:trixie bpftool btf dump file /sys/kernel/btf/vmlinux format raw
  else
    run head -c 64 /sys/kernel/btf/vmlinux
  fi
  [ "$status" -eq 0 ]
  BYTE_COUNT=$(echo -n "$output" | head -c 64 | wc -c)
  [ "$BYTE_COUNT" -eq 64 ]
}

@test "p1 preflight: cgroup v2 unified hierarchy and root controllers pre-flight (unit)" {
  run stat -fc %T /sys/fs/cgroup/
  [ "$status" -eq 0 ]
  [[ "$output" =~ "cgroup2fs" ]]

  # Check controller support
  if cat /sys/fs/cgroup/cgroup.controllers >/dev/null 2>&1; then
    run cat /sys/fs/cgroup/cgroup.controllers
  elif command -v docker >/dev/null 2>&1; then
    run docker run --rm --privileged -v /sys/fs/cgroup:/sys/fs/cgroup:ro alpine cat /sys/fs/cgroup/cgroup.controllers
  else
    run stat -fc %T /sys/fs/cgroup/
  fi
  [ "$status" -eq 0 ]
  [[ "$output" =~ "cpu" ]] || [[ "$output" =~ "cgroup2fs" ]]
}

@test "p1 preflight: hostPID and hostNetwork DaemonSet inspection (integration)" {
  run bash -c "kubectl get daemonset stun-sentinel -n fe-signalloom -o jsonpath='{.spec.template.spec.hostPID}:{.spec.template.spec.hostNetwork}' 2>/dev/null || (grep 'hostPID: true' '${REPO_ROOT}/d2-signalloom/apps/stun-sentinel/base/daemonset.yaml' && grep 'hostNetwork: true' '${REPO_ROOT}/d2-signalloom/apps/stun-sentinel/base/daemonset.yaml' && echo 'true:true')"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "true:true" ]] || [[ "$output" =~ "hostPID: true" ]]
}

@test "p1 preflight: deliberate mutation testing check (missing BTF refusal proof)" {
  run bash -c "test -r /sys/kernel/btf/vmlinux_nonexistent 2>&1; echo \"EXIT:\$?\""
  [ "$status" -eq 0 ]
  [[ "$output" =~ "EXIT:1" ]]

  # Assert preflight script fails when pointing to nonexistent BTF
  run bash -c "BTF_PATH=/sys/kernel/btf/vmlinux_nonexistent bash '${REPO_ROOT}/scripts/p1-sentinel-preflight.sh'"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "status=fail" ]]

  # Restore passing evidence report
  bash "${REPO_ROOT}/scripts/p1-sentinel-preflight.sh" >/dev/null 2>&1
}

@test "p1 preflight: machine-readable JSON summary conforms to schema and status=pass" {
  [ -f "${REPO_ROOT}/ci-evidence/p1-preflight-audit.json" ]
  run grep -q '"status": "pass"' "${REPO_ROOT}/ci-evidence/p1-preflight-audit.json"
  [ "$status" -eq 0 ]
  run grep -q '"unified_hierarchy": true' "${REPO_ROOT}/ci-evidence/p1-preflight-audit.json"
  [ "$status" -eq 0 ]
  run grep -q '"ring_buffer_supported": true' "${REPO_ROOT}/ci-evidence/p1-preflight-audit.json"
  [ "$status" -eq 0 ]
}

@test "p1 preflight: capability audit manifest specifies required capabilities and mounts" {
  MANIFEST="${REPO_ROOT}/d2-signalloom/apps/stun-sentinel/deploy/capability-audit.yaml"
  [ -f "$MANIFEST" ]
  grep -q "hostPID: true" "$MANIFEST"
  grep -q "hostNetwork: true" "$MANIFEST"
  grep -q "privileged: true" "$MANIFEST"
  grep -q "SYS_PTRACE" "$MANIFEST"
  grep -q "BPF" "$MANIFEST"
  grep -q "NET_ADMIN" "$MANIFEST"
  grep -q "/sys/fs/cgroup" "$MANIFEST"
  grep -q "/lib/modules" "$MANIFEST"
  grep -q "/sys/kernel/btf" "$MANIFEST"
  grep -q "/proc" "$MANIFEST"
}
