#!/usr/bin/env bash
# Create the local Kind cluster with a durable host-backed Zot cache.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
KIND_BIN="${KIND_BIN:-kind}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
ZOT_CACHE_DIR="${ZOT_CACHE_DIR:-.cache/zot}"

mkdir -p "$ZOT_CACHE_DIR"
# Resolve to an absolute path via the PARENT dir, not by cd-ing into the cache
# itself: after the first run prepare_zot_cache chowns the bind-mounted cache to
# 65532:65532 mode 0750 (so Zot's nonroot user can write), which leaves the host
# dir un-enterable by the invoking user. cd-ing into it here would fail on every
# re-run. The parent is owned by the invoking user, so resolving via it is safe.
ZOT_CACHE_DIR="$(cd "$(dirname "$ZOT_CACHE_DIR")" && pwd -P)/$(basename "$ZOT_CACHE_DIR")"
# This cache is deliberately local-only. Kind makes it available inside the
# control-plane container; prepare ownership there before Zot is deployed.
# The pod itself remains non-root and has no privileged init container.
prepare_zot_cache() {
  "$DOCKER_BIN" exec "${CLUSTER_NAME}-control-plane" \
    chown 65532:65532 /var/local/osramp-zot-cache
  "$DOCKER_BIN" exec "${CLUSTER_NAME}-control-plane" \
    chmod 0750 /var/local/osramp-zot-cache
}

if "$KIND_BIN" get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  prepare_zot_cache
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
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: $ZOT_CACHE_DIR
        containerPath: /var/local/osramp-zot-cache
EOF

echo "Creating Kind cluster $CLUSTER_NAME with Zot cache $ZOT_CACHE_DIR"
"$KIND_BIN" create cluster --name "$CLUSTER_NAME" --config "$kind_config"
prepare_zot_cache
