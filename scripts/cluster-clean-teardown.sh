#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/cluster-clean-teardown.sh: clean and deterministic teardown of Kind clusters and networks
#
# @doc   docs/eap/SLDC-MISSION-CERTIFICATION.md
# @lib   scripts/lib/cluster-reset-helpers.sh
#
# Deletes Kind clusters (signalloom-hub and osramp), tears down bridge networks,
# flushes lingering port-forwards and veths, and ensures zero running containers
# matching osramp or signalloom.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=scripts/lib/cluster-reset-helpers.sh
source "$SCRIPT_DIR/lib/cluster-reset-helpers.sh"

SAVED_CONTAINERS_FILE="/tmp/sldc-saved-containers.txt"
rm -f "$SAVED_CONTAINERS_FILE"

echo "════ Cluster Clean Teardown ════"

# 1. Terminate lingering port-forward processes
echo "Stopping lingering kubectl port-forwards..."
pkill -f 'kubectl.*port-forward' 2>/dev/null || true

# 2. Delete Kind clusters
if command -v kind >/dev/null 2>&1; then
  for cluster in signalloom-hub osramp; do
    if kind get clusters 2>/dev/null | grep -qx "$cluster"; then
      echo "Deleting Kind cluster $cluster..."
      kind delete cluster --name "$cluster" 2>/dev/null || true
    fi
  done
fi

# 3. Clean up any lingering containers with osramp or signalloom in name
if command -v docker >/dev/null 2>&1; then
  lingering="$(docker ps --filter 'name=osramp|signalloom' --format '{{.Names}}' 2>/dev/null || true)"
  if [ -n "$lingering" ]; then
    echo "Stopping lingering containers: $lingering"
    while IFS= read -r cname; do
      [ -z "$cname" ] && continue
      echo "$cname" >> "$SAVED_CONTAINERS_FILE"
      docker stop "$cname" 2>/dev/null || true
    done <<<"$lingering"
  fi

  # 4. Remove Docker bridge networks
  for net in signalloom-bridge kind; do
    if docker network inspect "$net" >/dev/null 2>&1; then
      echo "Removing docker network $net..."
      docker network rm "$net" 2>/dev/null || true
    fi
  done
fi

# 5. Clean orphaned veth interfaces and kind iptables
cleanup_orphaned_veths 0
cleanup_kind_iptables 0

# 6. Verify zero lingering containers matching osramp or signalloom
REMAINING=0
if command -v docker >/dev/null 2>&1; then
  REMAINING="$(docker ps -q --filter 'name=osramp|signalloom' 2>/dev/null | wc -l)"
fi

echo "────────────────────────────────────────────────"
if [ "$REMAINING" -eq 0 ]; then
  echo "VERDICT: PASS (0 lingering containers matching osramp|signalloom)"
  exit 0
else
  echo "VERDICT: FAIL ($REMAINING lingering containers)" >&2
  exit 1
fi
