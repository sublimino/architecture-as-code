#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/cluster-scratch-standup.sh: zero-state scratch standup orchestrator
#
# @doc   docs/eap/SLDC-MISSION-CERTIFICATION.md
# @tests test/e2e-scratch-coldstart-replay.bats
#
# Rebuilds the foundation Kind cluster, in-cluster Zot registry, Flux Operator,
# dual-cluster topology, and core application slices entirely from scratch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

SAVED_CONTAINERS_FILE="${SLDC_SAVED_CONTAINERS_FILE:-${XDG_RUNTIME_DIR:-$REPO_ROOT/.evidence}/sldc-saved-containers.txt}"

echo "════ Cluster Scratch Standup Orchestrator ════"

# 1. Restore any saved non-cluster auxiliary containers
if [ -f "$SAVED_CONTAINERS_FILE" ] && command -v docker >/dev/null 2>&1; then
  echo "Restoring saved auxiliary containers..."
  while IFS= read -r cname; do
    [ -z "$cname" ] && continue
    # Only restart if not a kind control plane
    if [[ ! "$cname" =~ control-plane ]]; then
      docker start "$cname" 2>/dev/null || true
    fi
  done < "$SAVED_CONTAINERS_FILE"
  rm -f "$SAVED_CONTAINERS_FILE"
fi

# 2. Stand up Kind cluster osramp and foundation
echo "Bringing up shared foundation (Kind osramp, Zot, keys, Flux)..."
make -C "$REPO_ROOT" up

# 3. Bring up dual-cluster topology (signalloom-hub + bridge networking)
if [ -f "$REPO_ROOT/scripts/dual-cluster-up.sh" ]; then
  echo "Provisioning dual-cluster topology (signalloom-hub)..."
  bash "$REPO_ROOT/scripts/dual-cluster-up.sh"
fi

# 4. Deploy Signal Loom governance platform
echo "Deploying Signal Loom slice..."
make -C "$REPO_ROOT" demo-signalloom-up

# 5. Deploy Agent Trust slice
echo "Deploying Agent Trust slice..."
make -C "$REPO_ROOT" demo-agent-trust-up

# 6. Verify health
echo "Executing foundation healthcheck..."
make -C "$REPO_ROOT" healthcheck

echo "──────────────────────────────────────────────"
echo "VERDICT: PASS (Zero-state scratch standup complete)"
exit 0
