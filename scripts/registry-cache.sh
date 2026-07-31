#!/usr/bin/env bash
# registry-cache.sh — host-side pull-through registry proxies.
#
# Caches upstream base images (docker.io, registry.k8s.io, ghcr.io, quay.io,
# mirror.gcr.io) in durable local volumes so they survive `make down`/`make up`.
# On a cold cluster every foundation image is otherwise pulled fresh from
# upstream — the dominant cold-start latency. With these proxies wired into the
# kind nodes' containerd (see create-kind-cluster.sh), the first cluster warms
# the cache and every subsequent spin-up serves images locally.
#
# Idempotent and safe to re-run. Sourcing this file exposes the functions
# without starting anything (only executes when run directly).
set -euo pipefail

KIND_NETWORK="${KIND_NETWORK:-kind}"
REGISTRY_CACHE_IMAGE="${REGISTRY_CACHE_IMAGE:-registry:2}"

# name | upstream remote URL | containerd certs.d host directory | server URL
REGISTRY_CACHE_MAPPINGS=(
  "dockerio|https://registry-1.docker.io|docker.io|https://docker.io"
  "k8s|https://registry.k8s.io|registry.k8s.io|https://registry.k8s.io"
  "ghcr|https://ghcr.io|ghcr.io|https://ghcr.io"
  "quay|https://quay.io|quay.io|https://quay.io"
  "gcrmirror|https://mirror.gcr.io|mirror.gcr.io|https://mirror.gcr.io"
)

registry_cache_ensure_network() {
  docker network inspect "$KIND_NETWORK" >/dev/null 2>&1 \
    || docker network create "$KIND_NETWORK" >/dev/null
}

registry_cache_up() {
  registry_cache_ensure_network
  echo "==> Ensuring pull-through registry caches on docker network '$KIND_NETWORK'"
  local m name upstream _hostdir _server cname
  for m in "${REGISTRY_CACHE_MAPPINGS[@]}"; do
    IFS='|' read -r name upstream _hostdir _server <<<"$m"
    cname="registry-cache-${name}"
    if [ "$(docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null || true)" = "true" ]; then
      # Ensure it is attached to the kind network (a fresh network after
      # `make down` re-creates it with a new id).
      docker network connect "$KIND_NETWORK" "$cname" >/dev/null 2>&1 || true
      echo "  ${cname} already running"
      continue
    fi
    docker rm -f "$cname" >/dev/null 2>&1 || true
    docker run -d --restart=always --name "$cname" \
      --net "$KIND_NETWORK" \
      -v "registry-cache-${name}:/var/lib/registry" \
      -e "REGISTRY_PROXY_REMOTEURL=${upstream}" \
      "$REGISTRY_CACHE_IMAGE" >/dev/null
    echo "  started ${cname} -> ${upstream}"
  done
}

# Write containerd hosts.toml files inside a kind node so its containerd uses the
# pull-through proxies (with fallback to the real upstream via `server`).
registry_cache_configure_node() {
  local node="$1"
  local m name _upstream hostdir server cname
  for m in "${REGISTRY_CACHE_MAPPINGS[@]}"; do
    IFS='|' read -r name _upstream hostdir server <<<"$m"
    cname="registry-cache-${name}"
    docker exec "$node" mkdir -p "/etc/containerd/certs.d/${hostdir}"
    docker exec -i "$node" bash -c "cat >/etc/containerd/certs.d/${hostdir}/hosts.toml" <<EOF
server = "${server}"

[host."http://${cname}:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
  done
}

registry_cache_down() {
  local m name cname
  for m in "${REGISTRY_CACHE_MAPPINGS[@]}"; do
    IFS='|' read -r name _ _ _ <<<"$m"
    cname="registry-cache-${name}"
    docker rm -f "$cname" >/dev/null 2>&1 || true
  done
  echo "==> Removed pull-through registry caches (volumes preserved)"
}

# Execute only when run directly, not when sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-up}" in
    up)   registry_cache_up ;;
    down) registry_cache_down ;;
    *)    echo "usage: $0 [up|down]" >&2; exit 1 ;;
  esac
fi
