#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/dual-cluster-down.sh : tear down the SLDC dual Kind topology
#
# @doc    docs/eap/SLDC-P2-DUAL-CLUSTER.md
# @tests  test/dual-cluster-networking.bats
# @lib    scripts/lib/dual-cluster.sh
#
# Default: delete kind-signalloom-hub. The workload cluster is left running,
# but with everything dual-cluster-up.sh added to it removed: the probe, the
# sldc-bridge-dns responder, the stub and identity ConfigMaps, the managed Corefile block,
# and the bridge interface. kind-osramp is the SHARED demo cluster, and
# destroying it is an explicit choice, never a default.
#
# Usage: scripts/dual-cluster-down.sh [--delete-osramp] [--remove-bridge]
#   --delete-osramp  also `kind delete` the workload cluster (destructive:
#                    shared demo state, Flux, Zot cache pointers)
#   --remove-bridge  also remove the signalloom-bridge docker network
#                    (refused while any container is still attached)
#
# After teardown the script asserts that nothing is left dangling: no
# container or volume labelled for a deleted cluster, and no bridge endpoint
# on a deleted node.
#
# Exit: 0 clean, 1 residue or failure, 2 usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=scripts/lib/dual-cluster.sh
source "$SCRIPT_DIR/lib/dual-cluster.sh"

DELETE_OSRAMP=0
REMOVE_BRIDGE=0

usage() { sed -n '/^# Usage:/,/^# After teardown/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --delete-osramp) DELETE_OSRAMP=1 ;;
    --remove-bridge) REMOVE_BRIDGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

delete_cluster() {
  local name="$1" vols v
  if sldc_cluster_exists "$name"; then
    # Kind nodes carry anonymous volumes (/var). Record them first so the
    # residue check can prove `kind delete` removed them.
    vols="$("$DOCKER_BIN" inspect "$(sldc_node "$name")" \
      --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' 2>/dev/null || true)"
    "$KIND_BIN" delete cluster --name "$name" >/dev/null
    for v in $vols; do
      if "$DOCKER_BIN" volume inspect "$v" >/dev/null 2>&1; then
        sldc_die "residue: volume $v of $name survived kind delete"
      fi
    done
    sldc_log "deleted cluster $name (volumes removed: ${vols:-none})"
  else
    sldc_log "cluster $name: absent"
  fi
}

# Undo dual-cluster-up.sh's in-cluster changes on a cluster that survives.
unwire_cluster() {
  local k="$1" current next patch
  "$k" version --request-timeout=10s >/dev/null 2>&1 || { sldc_log "unwire: $k unreachable, skipping"; return 0; }
  "$k" -n default delete deployment probe --ignore-not-found >/dev/null
  "$k" -n kube-system delete deployment sldc-bridge-dns --ignore-not-found >/dev/null
  "$k" -n kube-system delete configmap sldc-bridge-identity --ignore-not-found >/dev/null
  "$k" -n default delete networkpolicy allow-sldc-probe-egress --ignore-not-found >/dev/null
  "$k" -n kube-system delete configmap sldc-cross-cluster-stubs --ignore-not-found >/dev/null
  current="$("$k" -n kube-system get configmap coredns -o json | jq -r '.data.Corefile')"
  next="$(printf '%s\n' "$current" | sldc_strip_corefile)"
  if [ "$next" != "$current" ]; then
    patch="$(jq -n --arg c "$next" '{data: {Corefile: $c}}')"
    printf '%s' "$patch" | "$k" -n kube-system patch configmap coredns --type merge --patch-file /dev/stdin >/dev/null
    "$k" -n kube-system rollout restart deployment/coredns >/dev/null
    "$k" -n kube-system rollout status deployment/coredns --timeout=180s >/dev/null
    sldc_log "unwire: removed managed block from kube-system/coredns"
  fi
}

detach_node() {
  local node="$1"
  if [ -n "$(sldc_container_ip "$node" "$SLDC_BRIDGE_NAME")" ]; then
    "$DOCKER_BIN" network disconnect "$SLDC_BRIDGE_NAME" "$node" >/dev/null
    sldc_log "detached $node from $SLDC_BRIDGE_NAME"
  fi
}

# Residue check: containers or volumes still labelled for a deleted cluster.
assert_no_residue() {
  local name="$1" left
  left="$("$DOCKER_BIN" ps -a --filter "label=io.x-k8s.kind.cluster=$name" --format '{{.Names}}')"
  [ -z "$left" ] || sldc_die "residue: containers still present for $name: $left"
  left="$("$DOCKER_BIN" volume ls --filter "label=io.x-k8s.kind.cluster=$name" --format '{{.Name}}')"
  [ -z "$left" ] || sldc_die "residue: volumes still present for $name: $left"
}

main() {
  delete_cluster "$SLDC_HUB_CLUSTER"
  assert_no_residue "$SLDC_HUB_CLUSTER"
  if [ "$DELETE_OSRAMP" = 1 ]; then
    delete_cluster "$SLDC_OSRAMP_CLUSTER"
    assert_no_residue "$SLDC_OSRAMP_CLUSTER"
  elif sldc_cluster_exists "$SLDC_OSRAMP_CLUSTER"; then
    unwire_cluster kosr
    detach_node "$(sldc_node "$SLDC_OSRAMP_CLUSTER")"
  fi
  if "$DOCKER_BIN" network inspect "$SLDC_BRIDGE_NAME" >/dev/null 2>&1; then
    local attached
    attached="$("$DOCKER_BIN" network inspect "$SLDC_BRIDGE_NAME" --format '{{range .Containers}}{{.Name}} {{end}}')"
    case " $attached " in
      *" $(sldc_node "$SLDC_HUB_CLUSTER") "*) sldc_die "residue: deleted hub node still attached to $SLDC_BRIDGE_NAME" ;;
    esac
    if [ "$REMOVE_BRIDGE" = 1 ]; then
      [ -z "${attached// /}" ] || sldc_die "bridge: refusing to remove $SLDC_BRIDGE_NAME, still attached: $attached"
      "$DOCKER_BIN" network rm "$SLDC_BRIDGE_NAME" >/dev/null
      sldc_log "removed network $SLDC_BRIDGE_NAME"
    fi
  fi
  sldc_log "dual-cluster teardown complete (no residue)"
}

main "$@"
