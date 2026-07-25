#!/usr/bin/env bash
# Create the local Kind cluster with a durable host-backed Zot cache.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
KIND_BIN="${KIND_BIN:-kind}"
ZOT_CACHE_DIR="${ZOT_CACHE_DIR:-.cache/zot}"

mkdir -p "$ZOT_CACHE_DIR"
ZOT_CACHE_DIR="$(cd "$ZOT_CACHE_DIR" && pwd -P)"
# This cache is deliberately local-only.  Make the hostPath writable by Zot's
# fixed non-root UID; the pod has no privileged init container to chown it.
chmod 0777 "$ZOT_CACHE_DIR"

if "$KIND_BIN" get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
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
