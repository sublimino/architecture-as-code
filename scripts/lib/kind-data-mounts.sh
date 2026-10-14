#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/lib/kind-data-mounts.sh : shared Kind node data mounts and config renderer
#
# Sourced by scripts/create-kind-cluster.sh, scripts/dual-cluster-up.sh and tests.
# Manages host-backed persistent mounts for Kind control-plane nodes:
#   - /var/local/osramp-zot-cache (uid 65532:65532, mode 0750)
#   - /var/local/signalloom-postgres-data (uid 70:70, mode 0700)
#   - /var/local-path-provisioner (mode 0777)
#   - /lib/modules (ro)
#   - /sys/kernel/btf (ro)

DOCKER_BIN="${DOCKER_BIN:-docker}"
KIND_BIN="${KIND_BIN:-kind}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
ZOT_CACHE_DIR="${ZOT_CACHE_DIR:-.cache/zot}"
POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-.cache/postgres}"
LOCAL_PATH_DATA_DIR="${LOCAL_PATH_DATA_DIR:-.cache/local-path}"

# Resolve directory to an absolute path via its parent directory to avoid
# failures when unreadable container-owned permissions (e.g. 0700/0750) are set.
kind_data_abs_dir() {
  local target="$1"
  mkdir -p "$target" 2>/dev/null || true
  if [ -d "$(dirname "$target")" ]; then
    printf '%s/%s\n' "$(cd "$(dirname "$target")" && pwd -P)" "$(basename "$target")"
  elif [[ "$target" = /* ]]; then
    printf '%s\n' "$target"
  else
    printf '%s/%s\n' "$PWD" "$target"
  fi
}

# Resolve per-cluster host directories. osramp uses the base variables; other
# clusters (such as signalloom-hub) use cluster-keyed subdirectories to ensure
# disjoint host paths and prevent PGDATA corruption.
kind_data_resolve_paths() {
  local cluster="${1:-osramp}"
  local zot_raw pg_raw lp_raw

  if [ "$cluster" = "osramp" ]; then
    zot_raw="${ZOT_CACHE_DIR:-.cache/zot}"
    pg_raw="${POSTGRES_DATA_DIR:-.cache/postgres}"
    lp_raw="${LOCAL_PATH_DATA_DIR:-.cache/local-path}"
  else
    if [ -z "${ZOT_CACHE_DIR:-}" ] || [ "${ZOT_CACHE_DIR}" = ".cache/zot" ]; then
      zot_raw=".cache/${cluster}/zot"
    else
      zot_raw="${ZOT_CACHE_DIR}/${cluster}/zot"
    fi
    if [ -z "${POSTGRES_DATA_DIR:-}" ] || [ "${POSTGRES_DATA_DIR}" = ".cache/postgres" ]; then
      pg_raw=".cache/${cluster}/postgres"
    else
      pg_raw="${POSTGRES_DATA_DIR}/${cluster}/postgres"
    fi
    if [ -z "${LOCAL_PATH_DATA_DIR:-}" ] || [ "${LOCAL_PATH_DATA_DIR}" = ".cache/local-path" ]; then
      lp_raw=".cache/${cluster}/local-path"
    else
      lp_raw="${LOCAL_PATH_DATA_DIR}/${cluster}/local-path"
    fi
  fi

  for val in "$zot_raw" "$pg_raw" "$lp_raw"; do
    case "$val" in
      *$'\n'*|*:*|*'#'*|*'['*|*']'*|*'{'*|*'}'*|*'&'*|*'*'*|*'!'*|*'|'*|*'>'*|*'"'*|*"'"*)
        echo "ERROR: Data directory contains YAML control characters: $val" >&2
        return 1
        ;;
    esac
  done

  KIND_DATA_ZOT_DIR="$(kind_data_abs_dir "$zot_raw")"
  KIND_DATA_POSTGRES_DIR="$(kind_data_abs_dir "$pg_raw")"
  KIND_DATA_LOCAL_PATH_DIR="$(kind_data_abs_dir "$lp_raw")"

  # Notice if directories are inside a git worktree
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$repo_root" ] && [[ "$KIND_DATA_POSTGRES_DIR" == "$repo_root"* ]]; then
      echo "Notice: Cluster data directories are inside git worktree ($repo_root/.cache/*); set POSTGRES_DATA_DIR, ZOT_CACHE_DIR, LOCAL_PATH_DATA_DIR out-of-tree for persistent retention." >&2
    fi
  fi
}

# In-node directory preparation and ownership fix
prepare_node_data_mounts() {
  local cluster="${1:-osramp}"
  local node="${cluster}-control-plane"

  "$DOCKER_BIN" exec "$node" mkdir -p /var/local/osramp-zot-cache
  "$DOCKER_BIN" exec "$node" chown -R 65532:65532 /var/local/osramp-zot-cache
  "$DOCKER_BIN" exec "$node" chmod 0750 /var/local/osramp-zot-cache

  "$DOCKER_BIN" exec "$node" mkdir -p /var/local/signalloom-postgres-data
  "$DOCKER_BIN" exec "$node" chown -R 70:70 /var/local/signalloom-postgres-data
  "$DOCKER_BIN" exec "$node" chmod 0700 /var/local/signalloom-postgres-data

  "$DOCKER_BIN" exec "$node" mkdir -p /var/local-path-provisioner
  "$DOCKER_BIN" exec "$node" chmod 0777 /var/local-path-provisioner
}

# Configure rancher.io/local-path provisioner with pathPattern and install minimal Kind CRDs
configure_local_path_provisioner() {
  local cluster="${1:-osramp}"
  local ctx="kind-${cluster}"
  local manifest_dir
  manifest_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../infra/kind" && pwd 2>/dev/null || true)"
  local config_file="$manifest_dir/local-path-config.yaml"
  local cilium_crds="$manifest_dir/cilium-crds.yaml"

  if command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
    if [ -f "$config_file" ]; then
      "$KUBECTL_BIN" --context "$ctx" apply -f "$config_file" >/dev/null 2>&1 || true
    fi
    if [ -f "$cilium_crds" ]; then
      "$KUBECTL_BIN" --context "$ctx" apply -f "$cilium_crds" >/dev/null 2>&1 || true
    fi
  fi
}

# Render a Kind configuration file with all required mounts and cluster settings
kind_data_render_config() {
  local cluster="$1"
  local base_manifest="${2:-}"
  local output_file="$3"

  kind_data_resolve_paths "$cluster"

  if [ -n "$base_manifest" ] && [ -f "$base_manifest" ]; then
    # Strip any existing extraMounts block from the base manifest
    awk '
      BEGIN { in_mounts = 0 }
      /^    extraMounts:/ { in_mounts = 1; next }
      in_mounts && /^      - / { next }
      in_mounts && /^        / { next }
      in_mounts && !/^ / { in_mounts = 0 }
      in_mounts && /^    [^ ]/ && !/^    extraMounts:/ { in_mounts = 0 }
      !in_mounts {
        if (/^name:/) {
          print "name: " cluster
        } else {
          print $0
        }
      }
    ' cluster="$cluster" "$base_manifest" > "$output_file"

    # Append the 5 standard extraMounts
    cat >> "$output_file" <<EOF
    extraMounts:
      - hostPath: /lib/modules
        containerPath: /lib/modules
        readOnly: true
      - hostPath: /sys/kernel/btf
        containerPath: /sys/kernel/btf
        readOnly: true
      - hostPath: $KIND_DATA_ZOT_DIR
        containerPath: /var/local/osramp-zot-cache
      - hostPath: $KIND_DATA_POSTGRES_DIR
        containerPath: /var/local/signalloom-postgres-data
      - hostPath: $KIND_DATA_LOCAL_PATH_DIR
        containerPath: /var/local-path-provisioner
EOF
  else
    # Generate standalone Kind config for single cluster
    cat > "$output_file" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $cluster
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
kubeadmConfigPatches:
  - |-
    kind: KubeletConfiguration
    apiVersion: kubelet.config.k8s.io/v1beta1
    nodeStatusMaxImages: -1
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /lib/modules
        containerPath: /lib/modules
        readOnly: true
      - hostPath: /sys/kernel/btf
        containerPath: /sys/kernel/btf
        readOnly: true
      - hostPath: $KIND_DATA_ZOT_DIR
        containerPath: /var/local/osramp-zot-cache
      - hostPath: $KIND_DATA_POSTGRES_DIR
        containerPath: /var/local/signalloom-postgres-data
      - hostPath: $KIND_DATA_LOCAL_PATH_DIR
        containerPath: /var/local-path-provisioner
EOF
  fi
}
