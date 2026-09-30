#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/dual-cluster-up.sh : bring up the SLDC dual Kind topology
#
# @doc    docs/eap/SLDC-P2-DUAL-CLUSTER.md
# @tests  test/dual-cluster-networking.bats
# @lib    scripts/lib/dual-cluster.sh, scripts/registry-cache.sh
#
#   kind-osramp          (workload)  172.19.0.10 on signalloom-bridge
#   kind-signalloom-hub  (hub)       172.19.0.20 on signalloom-bridge
#
# Steps, all idempotent:
#   1. bridge   ensure docker network signalloom-bridge = 172.19.0.0/16
#   2. clusters create whichever cluster is missing (existing ones are
#               ATTACHED, never recreated; see infra/kind/cluster-osramp.yaml)
#   3. attach   give each node a second interface on the bridge at its fixed IP
#   4. ready    wait for both control-plane nodes to be Ready
#   5. dns      apply d2-infra/components/coredns/cross-cluster-stubs.yaml to
#               both clusters: sldc-bridge-dns (hostNetwork, authoritative for
#               the cluster's own zone on its bridge IP:53), and splice the
#               stub zones (forward each zone to its owner) into
#               kube-system/coredns
#   6. probe    deploy infra/kind/probe.yaml to both clusters
#   7. verify   poll in-pod DNS until signal-ingest.signalloom.hub -> 172.19.0.20
#
# Usage: scripts/dual-cluster-up.sh [--reclaim-subnet] [--skip-verify]
#   --reclaim-subnet  if another docker network already holds 172.19.0.0/16
#                     AND has zero containers attached, remove it and create
#                     signalloom-bridge in the same step. Without the flag
#                     the script refuses and names the holder. A network with
#                     containers attached is never removed.
#   --skip-verify     skip step 7
#
# Exit: 0 topology up and verified, 1 failure, 2 usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=scripts/lib/dual-cluster.sh
source "$SCRIPT_DIR/lib/dual-cluster.sh"

OSRAMP_MANIFEST="${OSRAMP_MANIFEST:-$REPO_ROOT/infra/kind/cluster-osramp.yaml}"
HUB_MANIFEST="${HUB_MANIFEST:-$REPO_ROOT/infra/kind/cluster-signalloom-hub.yaml}"
STUBS_MANIFEST="${STUBS_MANIFEST:-$REPO_ROOT/d2-infra/components/coredns/cross-cluster-stubs.yaml}"
PROBE_MANIFEST="${PROBE_MANIFEST:-$REPO_ROOT/infra/kind/probe.yaml}"
SLDC_CREATE_RETRIES="${SLDC_CREATE_RETRIES:-3}"
SLDC_DNS_TIMEOUT="${SLDC_DNS_TIMEOUT:-60}"
SLDC_REGISTRY_CACHE="${SLDC_REGISTRY_CACHE:-1}"
SLDC_SLEEP="${SLDC_SLEEP:-sleep}"

RECLAIM=0
VERIFY=1

usage() { sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --reclaim-subnet) RECLAIM=1 ;;
    --skip-verify) VERIFY=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

# --- 1. bridge ---------------------------------------------------------------

# Name of the docker network currently holding $SLDC_BRIDGE_CIDR (empty if none).
subnet_holder() {
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if "$DOCKER_BIN" network inspect "$n" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null \
      | tr ' ' '\n' | grep -qx -- "$SLDC_BRIDGE_CIDR"; then
      printf '%s\n' "$n"
      return 0
    fi
  done < <("$DOCKER_BIN" network ls --format '{{.Name}}')
}

ensure_bridge() {
  local holder count
  holder="$(subnet_holder)"
  if [ "$holder" = "$SLDC_BRIDGE_NAME" ]; then
    sldc_log "bridge: $SLDC_BRIDGE_NAME already holds $SLDC_BRIDGE_CIDR"
    return 0
  fi
  if "$DOCKER_BIN" network inspect "$SLDC_BRIDGE_NAME" >/dev/null 2>&1; then
    sldc_die "bridge: network $SLDC_BRIDGE_NAME exists but not on $SLDC_BRIDGE_CIDR; remove it or set SLDC_BRIDGE_CIDR"
  fi
  if [ -n "$holder" ]; then
    count="$("$DOCKER_BIN" network inspect "$holder" --format '{{len .Containers}}')"
    if [ "$RECLAIM" -ne 1 ]; then
      sldc_die "bridge: $SLDC_BRIDGE_CIDR is held by docker network '$holder' ($count containers). Re-run with --reclaim-subnet to remove it (only if empty), or set SLDC_BRIDGE_CIDR."
    fi
    if [ "$count" != "0" ]; then
      sldc_die "bridge: refusing to reclaim '$holder': $count container(s) attached"
    fi
    sldc_log "bridge: reclaiming $SLDC_BRIDGE_CIDR from empty network '$holder'"
    # rm and create back to back: Docker's allocator hands the lowest free /16
    # to the next network created, so any gap lets something else take it.
    "$DOCKER_BIN" network rm "$holder" >/dev/null
  fi
  "$DOCKER_BIN" network create --driver bridge \
    --subnet "$SLDC_BRIDGE_CIDR" --gateway "$SLDC_BRIDGE_GATEWAY" \
    --label app.kubernetes.io/part-of=sldc-dual-cluster \
    "$SLDC_BRIDGE_NAME" >/dev/null
  sldc_log "bridge: created $SLDC_BRIDGE_NAME $SLDC_BRIDGE_CIDR"
}

# --- 2. clusters -------------------------------------------------------------

create_cluster() {
  local name="$1" manifest="$2" attempt=1 prev_ctx
  # kind create switches the kubeconfig current-context to the new cluster.
  # Restore it: other sessions on this workstation rely on it.
  prev_ctx="$("$KUBECTL_BIN" config current-context 2>/dev/null || true)"
  [ -f "$manifest" ] || sldc_die "cluster $name: manifest $manifest not found"
  while :; do
    sldc_log "cluster $name: kind create (attempt $attempt/$SLDC_CREATE_RETRIES)"
    if "$KIND_BIN" create cluster --name "$name" --config "$manifest" --wait 0s; then
      [ -z "$prev_ctx" ] || "$KUBECTL_BIN" config use-context "$prev_ctx" >/dev/null
      return 0
    fi
    "$KIND_BIN" delete cluster --name "$name" >/dev/null 2>&1 || true
    if [ "$attempt" -ge "$SLDC_CREATE_RETRIES" ]; then
      sldc_die "cluster $name: kind create failed $attempt times (kubeadm/containerd); see the kind output above"
    fi
    attempt=$((attempt + 1))
    "$SLDC_SLEEP" 5
  done
}

ensure_clusters() {
  local created_osramp=0
  if sldc_cluster_exists "$SLDC_OSRAMP_CLUSTER"; then
    sldc_log "cluster $SLDC_OSRAMP_CLUSTER: exists, attaching (not recreating)"
  else
    create_cluster "$SLDC_OSRAMP_CLUSTER" "$OSRAMP_MANIFEST"
    created_osramp=1
  fi
  if sldc_cluster_exists "$SLDC_HUB_CLUSTER"; then
    sldc_log "cluster $SLDC_HUB_CLUSTER: exists"
  else
    create_cluster "$SLDC_HUB_CLUSTER" "$HUB_MANIFEST"
  fi
  if [ "$SLDC_REGISTRY_CACHE" = 1 ] && [ -f "$SCRIPT_DIR/registry-cache.sh" ]; then
    # hosts.toml is read per pull, so pointing an existing node at the
    # pull-through caches is safe and needs no containerd restart.
    # shellcheck source=scripts/registry-cache.sh
    source "$SCRIPT_DIR/registry-cache.sh"
    registry_cache_configure_node "$(sldc_node "$SLDC_HUB_CLUSTER")" || true
    [ "$created_osramp" = 1 ] && { registry_cache_configure_node "$(sldc_node "$SLDC_OSRAMP_CLUSTER")" || true; }
  fi
  if [ "$created_osramp" = 1 ]; then
    # cluster-osramp.yaml disables the default CNI; the workload runs Cilium.
    sldc_log "cluster $SLDC_OSRAMP_CLUSTER: installing Cilium $SLDC_CILIUM_VERSION"
    "$CILIUM_BIN" install --context "$SLDC_OSRAMP_CTX" --version "$SLDC_CILIUM_VERSION" \
      || sldc_die "cluster $SLDC_OSRAMP_CLUSTER: Cilium install failed"
  fi
}

# --- 3. attach ---------------------------------------------------------------

attach_node() {
  local node="$1" want="$2" have
  "$DOCKER_BIN" inspect "$node" >/dev/null 2>&1 || sldc_die "attach: node container $node not found"
  have="$(sldc_container_ip "$node" "$SLDC_BRIDGE_NAME")"
  if [ "$have" = "$want" ]; then
    sldc_log "attach: $node already $want on $SLDC_BRIDGE_NAME"
    return 0
  fi
  if [ -n "$have" ]; then
    sldc_log "attach: $node is $have on $SLDC_BRIDGE_NAME, expected $want; reattaching"
    "$DOCKER_BIN" network disconnect "$SLDC_BRIDGE_NAME" "$node" >/dev/null
  fi
  "$DOCKER_BIN" network connect --ip "$want" "$SLDC_BRIDGE_NAME" "$node" >/dev/null
  have="$(sldc_container_ip "$node" "$SLDC_BRIDGE_NAME")"
  [ "$have" = "$want" ] || sldc_die "attach: $node got '$have' on $SLDC_BRIDGE_NAME, expected $want"
  sldc_log "attach: $node -> $want"
}

# --- 4. ready ----------------------------------------------------------------

wait_ready() {
  kosr wait --for=condition=Ready node --all --timeout=300s >/dev/null \
    || sldc_die "ready: $SLDC_OSRAMP_CTX nodes not Ready"
  khub wait --for=condition=Ready node --all --timeout=300s >/dev/null \
    || sldc_die "ready: $SLDC_HUB_CTX nodes not Ready"
  sldc_log "ready: both control planes Ready"
}

# --- 5. dns ------------------------------------------------------------------

# wire_dns <kubectl-fn> <owned-zone> <bridge-ip>
# Deploy this cluster's sldc-bridge-dns (authoritative for <owned-zone> on
# <bridge-ip>:53) and splice the shared stub.server block into its CoreDNS.
wire_dns() {
  local k="$1" zone="$2" ip="$3" key=stub.server block current next patch
  "$k" -n kube-system create configmap sldc-bridge-identity \
    --from-literal=SLDC_ZONE="$zone" --from-literal=SLDC_BRIDGE_IP="$ip" \
    --dry-run=client -o yaml | "$k" apply -f - >/dev/null
  "$k" apply -f "$STUBS_MANIFEST" >/dev/null
  "$k" -n kube-system rollout restart deployment/sldc-bridge-dns >/dev/null
  "$k" -n kube-system rollout status deployment/sldc-bridge-dns --timeout=180s >/dev/null \
    || sldc_die "dns: sldc-bridge-dns not ready on $ip:53 ($k)"
  block="$("$k" -n kube-system get configmap sldc-cross-cluster-stubs -o json | jq -r --arg k "$key" '.data[$k] // empty')"
  [ -n "$block" ] || sldc_die "dns: key $key missing from sldc-cross-cluster-stubs"
  if ! sldc_lint_stub_block "$block" >&2; then
    sldc_die "dns: stub block $key fails the loop-safety lint"
  fi
  current="$("$k" -n kube-system get configmap coredns -o json | jq -r '.data.Corefile')"
  next="$(printf '%s\n' "$current" | sldc_splice_corefile "$block")"
  if [ "$next" = "$current" ]; then
    sldc_log "dns: $key already spliced; Corefile unchanged"
    return 0
  fi
  patch="$(jq -n --arg c "$next" '{data: {Corefile: $c}}')"
  printf '%s' "$patch" | "$k" -n kube-system patch configmap coredns --type merge --patch-file /dev/stdin >/dev/null
  "$k" -n kube-system rollout restart deployment/coredns >/dev/null
  "$k" -n kube-system rollout status deployment/coredns --timeout=180s >/dev/null \
    || sldc_die "dns: coredns rollout did not complete after patching $key"
  sldc_log "dns: spliced $key into kube-system/coredns and restarted CoreDNS"
}

check_coredns_logs() {
  local k="$1" logs
  logs="$("$k" -n kube-system logs -l k8s-app=kube-dns --tail=200 2>/dev/null || true)"
  if printf '%s\n' "$logs" | grep -Eqi 'Loop \(|plugin/loop|Error during parsing|Corefile:[0-9]+ -'; then
    printf '%s\n' "$logs" | grep -Ei 'loop|parsing|Corefile' >&2
    sldc_die "dns: CoreDNS logs report a loop or Corefile syntax error ($k)"
  fi
}

# --- 6. probe ----------------------------------------------------------------

deploy_probe() {
  local k="$1"
  "$k" apply -f "$PROBE_MANIFEST" >/dev/null
  "$k" -n default rollout status deployment/probe --timeout=180s >/dev/null \
    || sldc_die "probe: deploy/probe not available ($k)"
}

# --- 7. verify ---------------------------------------------------------------

verify_dns() {
  local name="signal-ingest.$SLDC_HUB_ZONE" deadline out
  deadline=$(( $(date +%s) + SLDC_DNS_TIMEOUT ))
  while :; do
    out="$(kosr -n default exec deploy/probe -- nslookup "$name" 2>&1 || true)"
    if printf '%s\n' "$out" | awk '/^Name:/{n=1} n && /^Address/{print $NF}' | grep -qx -- "$SLDC_HUB_IP"; then
      sldc_log "verify: $name -> $SLDC_HUB_IP from inside $SLDC_OSRAMP_CTX deploy/probe"
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || { printf '%s\n' "$out" >&2; sldc_die "verify: $name did not resolve to $SLDC_HUB_IP within ${SLDC_DNS_TIMEOUT}s"; }
    "$SLDC_SLEEP" 3
  done
}

main() {
  sldc_require_tools "$DOCKER_BIN" "$KIND_BIN" "$KUBECTL_BIN" jq
  ensure_bridge
  ensure_clusters
  attach_node "$(sldc_node "$SLDC_OSRAMP_CLUSTER")" "$SLDC_OSRAMP_IP"
  attach_node "$(sldc_node "$SLDC_HUB_CLUSTER")" "$SLDC_HUB_IP"
  wait_ready
  wire_dns kosr "$SLDC_OSRAMP_ZONE" "$SLDC_OSRAMP_IP"
  wire_dns khub "$SLDC_HUB_ZONE" "$SLDC_HUB_IP"
  check_coredns_logs kosr
  check_coredns_logs khub
  deploy_probe kosr
  deploy_probe khub
  [ "$VERIFY" = 1 ] && verify_dns
  sldc_log "dual-cluster topology up: $SLDC_OSRAMP_CTX=$SLDC_OSRAMP_IP $SLDC_HUB_CTX=$SLDC_HUB_IP on $SLDC_BRIDGE_NAME"
}

main "$@"
