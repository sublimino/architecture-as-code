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

SAVED_CONTAINERS_FILE="${SLDC_SAVED_CONTAINERS_FILE:-${XDG_RUNTIME_DIR:-$REPO_ROOT/docs/records/eap-evidence}/sldc-saved-containers.txt}"

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

# 2. Bring up the dual-cluster topology FIRST (osramp + signalloom-hub + bridge).
#    dual-cluster-up.sh creates osramp from infra/kind/cluster-osramp.yaml, which
#    disables the default CNI and installs Cilium. `make up` alone creates osramp
#    with kindnet (scripts/create-kind-cluster.sh generates its own config), and
#    dual-cluster-up.sh never installs Cilium on a cluster it did not create.
#    Found on the 2026-10-03 zero-state rebuild: fe-signalloom/apps failed its
#    dry-run on CiliumNetworkPolicy because the fresh cluster had no Cilium CRDs.
if [ -f "$REPO_ROOT/scripts/dual-cluster-up.sh" ]; then
  echo "Provisioning dual-cluster topology (osramp with Cilium, signalloom-hub)..."
  bash "$REPO_ROOT/scripts/dual-cluster-up.sh"
fi

# 3. Stand up the foundation on the existing osramp cluster (Zot, keys, Flux)
echo "Bringing up shared foundation (Zot, keys, Flux)..."
make -C "$REPO_ROOT" up

# 4. Install Kagent (CRDs + control plane) before the Signal Loom slice: the
#    agent-swarm-base Kustomization declares kagent.dev/v1alpha2 RemoteMCPServer
#    and Agent objects, and nothing under demo-signalloom-up installs the CRDs
#    (AGENTS.md: "Kagent needs make swarm-kagent-up before"). Found on the
#    2026-10-03 zero-state rebuild: agent-swarm-base dry-run failed, no matches
#    for kind RemoteMCPServer.
echo "Installing Kagent CRDs and control plane..."
make -C "$REPO_ROOT" swarm-kagent-up
# 4b. Knative Serving (+Kourier) and Eventing: two swarm agents are ksvc-backed
#     and nothing else installs the CRDs (2026-10-03 zero-state rebuild).
echo "Installing Knative Serving and Eventing..."
make -C "$REPO_ROOT" swarm-knative-up
# 5. Deploy Signal Loom governance platform
echo "Deploying Signal Loom slice..."
make -C "$REPO_ROOT" demo-signalloom-up
# 5b. The eight declarative Kagent agents: the estate acceptance suite asserts the
#     swarm, its detail pages and timelines, and nothing else deploys them
#     (2026-10-04: 16 acceptance failures on every fresh estate traced here).
#     The agents need a real model credential (Secret kagent-anthropic-key, minted
#     from ANTHROPIC_API_KEY through OpenBao by demo-kagent-credentials, which
#     refuses to run without one). Without the key the eight pods would sit in
#     CreateContainerConfigError, so the step is skipped loudly instead.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "Deploying the Kagent agent swarm..."
  make -C "$REPO_ROOT" demo-kagent-credentials
  make -C "$REPO_ROOT" demo-kagent-up
else
  echo "WARN: ANTHROPIC_API_KEY is unset; skipping the Kagent agent swarm (export it and run: make demo-kagent-credentials demo-kagent-up)" >&2
fi

# 6. Deploy Agent Trust slice
echo "Deploying Agent Trust slice..."
make -C "$REPO_ROOT" demo-agent-trust-up

# 7. Verify health
echo "Executing foundation healthcheck..."
make -C "$REPO_ROOT" healthcheck

echo "──────────────────────────────────────────────"
echo "VERDICT: PASS (Zero-state scratch standup complete)"
exit 0
