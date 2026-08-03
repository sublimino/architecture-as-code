#!/usr/bin/env bash
# Create the local Kind cluster with a durable host-backed Zot cache.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
KIND_BIN="${KIND_BIN:-kind}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
ZOT_CACHE_DIR="${ZOT_CACHE_DIR:-.cache/zot}"

# Pull-through registry caches for upstream base images. Started before the
# cluster so the shared docker network exists and the kind nodes' containerd can
# reach them. See registry-cache.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/registry-cache.sh
source "$SCRIPT_DIR/registry-cache.sh"

mkdir -p "$ZOT_CACHE_DIR"
# Resolve to an absolute path via the PARENT dir, not by cd-ing into the cache
# itself: after the first run prepare_zot_cache chowns the bind-mounted cache to
# 65532:65532 mode 0750, which leaves the host
# dir un-enterable by the invoking user. cd-ing into it here would fail on every
# re-run. The parent is owned by the invoking user, so resolving via it is safe.
ZOT_CACHE_DIR="$(cd "$(dirname "$ZOT_CACHE_DIR")" && pwd -P)/$(basename "$ZOT_CACHE_DIR")"
# This cache is deliberately local-only. Kind makes it available inside the
# control-plane container; prepare ownership there before Zot is deployed.
# The pod itself remains non-root and has no privileged init container.
prepare_zot_cache() {
  # Correct existing cache content too: it may have been created by an earlier
  # image UID or a previously interrupted local run.
  "$DOCKER_BIN" exec "${CLUSTER_NAME}-control-plane" \
    chown -R 65532:65532 /var/local/osramp-zot-cache
  "$DOCKER_BIN" exec "${CLUSTER_NAME}-control-plane" \
    chmod 0750 /var/local/osramp-zot-cache
}

# Ensure the pull-through caches (and the shared kind network) exist first.
registry_cache_up

if "$KIND_BIN" get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  prepare_zot_cache
  registry_cache_configure_node "${CLUSTER_NAME}-control-plane"
  echo "Kind cluster $CLUSTER_NAME already exists; preserving Zot cache at $ZOT_CACHE_DIR"
  exit 0
fi

# This is deliberately a local-development path. Reject YAML control characters
# rather than emitting an ambiguous Kind configuration.
case "$ZOT_CACHE_DIR" in
  *$'\n'*|*:*|*'#'*|*'['*|*']'*|*'{'*|*'}'*|*'&'*|*'*'*|*'!'*|*'|'*|*'>'*|*'"'*|*"'"*)
    echo "ZOT_CACHE_DIR contains YAML control characters: $ZOT_CACHE_DIR" >&2
    exit 1
    ;;
esac

kind_config="$(mktemp)"
trap 'rm -f "$kind_config"' EXIT

cat >"$kind_config" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $CLUSTER_NAME
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
kubeadmConfigPatches:
  - |-
    kind: KubeletConfiguration
    apiVersion: kubelet.config.k8s.io/v1beta1
    # Report EVERY image the node holds, not the fifty largest.
    #
    # --node-status-max-images defaults to 50 and the kubelet reports the
    # LARGEST fifty, so on a node holding more than that the small images are
    # simply absent from node.status.images. Anything reading that object to
    # answer "is this image on the node?" then gets a confident wrong answer.
    #
    # This demo does exactly that: the in-cluster runner has no crictl and no
    # docker socket, so its shim derives the image list from the node object.
    # On 2026-08-03 the node held all four SuperCred images -- `crictl images`
    # on the node listed them -- while node.status.images held 50 entries and
    # omitted cardvault:local (8.9MB) and policy-engine:local (14.9MB) purely
    # for being too small to rank. The preflight blocked the entire demo on a
    # completely healthy cluster.
    #
    # 0 means unlimited. The cost is a larger Node object; on a single-node
    # kind cluster that is irrelevant, and it makes the shim's data source
    # actually answer the question being asked of it. The shim still warns
    # when it sees a capped list, because a cluster created before this
    # change, or by a different tool, will still be truncated.
    nodeStatusMaxImages: 0
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: $ZOT_CACHE_DIR
        containerPath: /var/local/osramp-zot-cache
EOF

echo "Creating Kind cluster $CLUSTER_NAME with Zot cache $ZOT_CACHE_DIR"
"$KIND_BIN" create cluster --name "$CLUSTER_NAME" --config "$kind_config"
prepare_zot_cache
# Point the node's containerd at the pull-through caches (hosts.toml is read
# dynamically per pull; no containerd restart needed).
registry_cache_configure_node "${CLUSTER_NAME}-control-plane"
