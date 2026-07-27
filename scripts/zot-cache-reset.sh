#!/usr/bin/env bash
# Reset the local host-backed Zot cache.
#
# The cache is bind-mounted into the Kind control-plane container and chowned to
# the Zot nonroot user (65532:65532, mode 0750) so the pod can write it. That
# leaves the host directory un-enterable and un-removable by the invoking user,
# so a plain `rm -rf` fails on every run after the first. This resets it as root
# from inside a container instead — preferring the running control-plane node,
# falling back to a throwaway container when no cluster is up.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
ZOT_CACHE_DIR="${ZOT_CACHE_DIR:-.cache/zot}"
CONTAINER="${CLUSTER_NAME}-control-plane"
MOUNT="/var/local/osramp-zot-cache"
FALLBACK_IMAGE="${ZOT_RESET_IMAGE:-busybox:stable}"

if [ ! -e "$ZOT_CACHE_DIR" ]; then
  echo "Zot cache '$ZOT_CACHE_DIR' does not exist; nothing to reset."
  exit 0
fi

# Fast path: if the invoking user still owns it, just remove it outright.
if rm -rf "$ZOT_CACHE_DIR" 2>/dev/null; then
  echo "Removed '$ZOT_CACHE_DIR'."
  exit 0
fi

# Slow path: the cache was chowned to the container's nonroot user and we cannot
# remove it directly. Clear its CONTENTS as root — emptying is enough for the
# next `make up`/`make cluster` to repopulate it.
ABS_CACHE="$(cd "$(dirname "$ZOT_CACHE_DIR")" && pwd -P)/$(basename "$ZOT_CACHE_DIR")"

# rm inside a POSIX sh: positional $1 is the mount path; globs that match nothing
# expand literally and are harmlessly swallowed by `rm -rf`.
clear_cmd='rm -rf "$1"/* "$1"/.[!.]* "$1"/..?*'

if "$DOCKER_BIN" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
  echo "Clearing Zot cache from inside running container '$CONTAINER':$MOUNT"
  "$DOCKER_BIN" exec "$CONTAINER" sh -c "$clear_cmd" _ "$MOUNT"
else
  echo "No running '$CONTAINER'; clearing '$ABS_CACHE' via throwaway '$FALLBACK_IMAGE' container."
  "$DOCKER_BIN" run --rm -v "$ABS_CACHE:/cache" "$FALLBACK_IMAGE" sh -c "$clear_cmd" _ /cache
fi

# The dir is now empty; the parent is user-owned, so rmdir is permitted. If the
# next step recreates it (create-kind-cluster.sh does `mkdir -p`), retaining it
# is equally fine — hence best-effort.
if rmdir "$ABS_CACHE" 2>/dev/null; then
  echo "Removed '$ABS_CACHE'."
else
  echo "Cleared contents of '$ABS_CACHE' (directory retained; repopulated on next 'make up')."
fi
