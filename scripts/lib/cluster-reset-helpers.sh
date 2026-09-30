#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/lib/cluster-reset-helpers.sh: cluster teardown and reset verification helpers
#
# @doc   docs/eap/SLDC-P6-PREFLIGHT.md
# @spec  test/fixtures/cold-start-manifests.tsv
#
# Utility functions to inspect, verify, and clean host network and container
# resources prior to cold-start dual-cluster provisioning.

# A veth enslaved to a bridge (docker0, br-*, kind) carries a live
# container's traffic; only a veth attached to no master is an orphan.
find_orphaned_veths() {
  local orphaned=()
  if command -v ip >/dev/null 2>&1; then
    while IFS= read -r iface; do
      [ -n "$iface" ] && orphaned+=("$iface")
    done < <(ip -o link show type veth 2>/dev/null | awk -F': ' '$0 !~ / master / {print $2}' | cut -d'@' -f1)
  fi
  [ "${#orphaned[@]}" -eq 0 ] || printf '%s\n' "${orphaned[@]}"
}

cleanup_orphaned_veths() {
  local dry_run="${1:-0}"
  local count=0
  for iface in $(find_orphaned_veths); do
    [ -z "$iface" ] && continue
    if [ "$dry_run" = "1" ]; then
      printf 'DRY-RUN: would remove orphaned veth %s\n' "$iface"
    else
      ip link delete "$iface" 2>/dev/null || true
      count=$((count + 1))
    fi
  done
  return 0
}

find_kind_iptables_residue() {
  local residue=()
  if command -v iptables >/dev/null 2>&1; then
    while IFS= read -r chain; do
      [ -n "$chain" ] && residue+=("$chain")
    done < <(iptables -S 2>/dev/null | grep -E '(-N KUBE-|-N KIND-|-A POSTROUTING.*172\.19\.)' || true)
  fi
  printf '%s\n' "${residue[@]:-}"
}

cleanup_kind_iptables() {
  local dry_run="${1:-0}"
  if [ "$dry_run" = "1" ]; then
    printf 'DRY-RUN: would flush kind iptables residue\n'
    return 0
  fi
  return 0
}

verify_docker_bridge_released() {
  local bridge_name="${1:-signalloom-bridge}"
  local subnet="${2:-172.19.0.0/16}"
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi
  local attached
  attached="$(docker network inspect "$bridge_name" --format '{{len .Containers}}' 2>/dev/null || echo "0")"
  if [ "$attached" -gt 0 ]; then
    printf 'WARN: %s still has %s container(s) attached\n' "$bridge_name" "$attached"
    return 1
  fi
  return 0
}

check_cgroup_v2_status() {
  if [ -f "${CGROUP_ROOT:-/sys/fs/cgroup}/cgroup.controllers" ]; then
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    local v
    v="$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || echo "")"
    if [ "$v" = "2" ]; then
      return 0
    fi
  fi
  return 1
}

check_zot_cache_status() {
  local repo_root="${1:-$PWD}"
  local zot_dir="$repo_root/.cache/zot"
  if [ -d "$zot_dir" ]; then
    local count
    count="$(find "$zot_dir" -type f 2>/dev/null | wc -l)"
    printf 'Zot cache present: %s files in %s\n' "$count" "$zot_dir"
    return 0
  fi
  printf 'Zot cache directory not found at %s (will bootstrap cleanly)\n' "$zot_dir"
  return 0
}
