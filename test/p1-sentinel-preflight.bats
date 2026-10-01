#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# test/p1-sentinel-preflight.bats — scripts/p1-sentinel-preflight.sh.
#
# Test 1 audits the real host kernel (BTF, cgroup v2, kernel >= 5.8) against the
# real canonical DaemonSet. Every other test drives one refusal path with an
# injected fixture. docker is stubbed to fail so no fallback can reach the host,
# and the report goes to a temp file so the tracked ci-evidence copy is never
# rewritten by a test run.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/p1-sentinel-preflight.sh"
  # THE sentinel DaemonSet. apps/stun-sentinel/base/daemonset.yaml was one of
  # four competing copies and is deleted; this is the one that deploys.
  BASE_DS="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml"
  export P1_PREFLIGHT_OUT="${BATS_TEST_TMPDIR}/audit.json"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/bin/sh\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/docker"
  chmod +x "${BATS_TEST_TMPDIR}/bin/docker"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

report() { jq -r "$1" "$P1_PREFLIGHT_OUT"; }

manifest_with() {
  local out="${BATS_TEST_TMPDIR}/ds.yaml"
  yq "$1" "$BASE_DS" >"$out"
  echo "$out"
}

@test "p1 preflight: this host and the base DaemonSet pass all 8 checks" {
  [ -r /sys/kernel/btf/vmlinux ] || skip "host has no readable /sys/kernel/btf/vmlinux"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Preflight Audit Summary: 8 passed, 0 failed (status=pass)"* ]]
  [ "$(report .summary.status)" = pass ]
  [ "$(report .daemonset_security.manifest_inspected)" = "$BASE_DS" ]
  git -C "$REPO_ROOT" diff --quiet -- ci-evidence/p1-preflight-audit.json
}

@test "p1 preflight: missing BTF fails with the path named and btf.available=false" {
  run env BTF_PATH=/nonexistent/vmlinux bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Kernel BTF symbol table missing or unreadable at /nonexistent/vmlinux"* ]]
  [ "$(report .summary.status)" = fail ]
  [ "$(report .btf.available)" = false ]
}

@test "p1 preflight: unreadable cgroup controllers are reported, never assumed" {
  run env CGROUP_PATH="$BATS_TEST_TMPDIR" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cgroup v2 root controllers missing required set (cpu=false, memory=false, pids=false)"* ]]
  [ "$(report .cgroup_v2.controllers_raw)" = "" ]
}

@test "p1 preflight: a controller set without pids fails" {
  echo "cpuset cpu memory" >"${BATS_TEST_TMPDIR}/cgroup.controllers"
  run env CGROUP_PATH="$BATS_TEST_TMPDIR" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(cpu=true, memory=true, pids=false)"* ]]
}

@test "p1 preflight: kernel config that could not be read is reported as unknown" {
  run env KERNEL_CONFIG=/nonexistent/config bash "$SCRIPT"
  [ "$(report .kernel.config_bpf)" = null ]
  [ "$(report .kernel.config_bpf_syscall)" = null ]
}

@test "p1 preflight: a DaemonSet without hostPID fails" {
  run env P1_SENTINEL_MANIFEST="$(manifest_with 'select(.kind == "DaemonSet").spec.template.spec.hostPID = false')" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"hostPID=false, hostNetwork=true"* ]]
}

@test "p1 preflight: a capability named only in a comment does not count" {
  local m
  m="$(manifest_with '(select(.kind == "DaemonSet").spec.template.spec.containers[0].securityContext) |= (.privileged = false | .capabilities.add = ["BPF"])')"
  echo "# SYS_PTRACE NET_ADMIN privileged: true" >>"$m"
  run env P1_SENTINEL_MANIFEST="$m" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DaemonSet missing required capabilities"* ]]
  [ "$(report .daemonset_security.capabilities.sys_ptrace)" = false ]
}

@test "p1 preflight: a missing DaemonSet manifest fails closed" {
  run env P1_SENTINEL_MANIFEST=/nonexistent/ds.yaml bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DaemonSet manifest not found: /nonexistent/ds.yaml"* ]]
}
