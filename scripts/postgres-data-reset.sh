#!/usr/bin/env bash
# Reset the local host-backed PostgreSQL data directory.
#
# The data directory is bind-mounted into the Kind control-plane container and
# owned by the Postgres container user (UID 70:70, mode 0700). That leaves
# files inside the host directory un-removable by an unprivileged host user, so a
# plain `rm -rf` fails once Postgres initializes. This resets it as root from
# inside a container instead - preferring the running control-plane node,
# falling back to a throwaway container when no cluster is up.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-.cache/postgres}"
CONTAINER="${CLUSTER_NAME}-control-plane"
MOUNT="/var/local/signalloom-postgres-data"
FALLBACK_IMAGE="${POSTGRES_RESET_IMAGE:-busybox:stable}"

if [ ! -e "$POSTGRES_DATA_DIR" ]; then
  echo "Postgres data directory '$POSTGRES_DATA_DIR' does not exist; nothing to reset."
  exit 0
fi

# Fast path: if the invoking user still owns it, just remove it outright.
if rm -rf "$POSTGRES_DATA_DIR" 2>/dev/null; then
  echo "Removed '$POSTGRES_DATA_DIR'."
  exit 0
fi

# Slow path: the data was written by container UID 70 and we cannot remove it directly.
# Clear its contents as root.
ABS_DATA="$(cd "$(dirname "$POSTGRES_DATA_DIR")" && pwd -P)/$(basename "$POSTGRES_DATA_DIR")"

# shellcheck disable=SC2016
clear_cmd='rm -rf "$1"/* "$1"/.[!.]* "$1"/..?*'

if "$DOCKER_BIN" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
  echo "Clearing Postgres data from inside running container '$CONTAINER':$MOUNT"
  "$DOCKER_BIN" exec "$CONTAINER" sh -c "$clear_cmd" _ "$MOUNT"
else
  echo "No running '$CONTAINER'; clearing '$ABS_DATA' via throwaway '$FALLBACK_IMAGE' container."
  "$DOCKER_BIN" run --rm -v "$ABS_DATA:/data" "$FALLBACK_IMAGE" sh -c "$clear_cmd" _ /data
fi

# If ABS_DATA on host still has residual files (e.g. host path differed or mount was detached),
# fall back to throwaway container directly against host path.
if [ -e "$ABS_DATA" ] && [ -n "$(ls -A "$ABS_DATA" 2>/dev/null || true)" ]; then
  echo "Clearing remaining '$ABS_DATA' via throwaway '$FALLBACK_IMAGE' container."
  "$DOCKER_BIN" run --rm -v "$ABS_DATA:/data" "$FALLBACK_IMAGE" sh -c "$clear_cmd" _ /data
fi

if rmdir "$ABS_DATA" 2>/dev/null; then
  echo "Removed '$ABS_DATA'."
else
  echo "Cleared contents of '$ABS_DATA' (directory retained; repopulated on next start)."
fi
