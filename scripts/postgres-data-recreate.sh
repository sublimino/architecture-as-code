#!/usr/bin/env bash
# Reset the local host-backed PostgreSQL data and recreate the runtime state.
#
# If a PostgreSQL deployment is running in the Kind cluster, this safely scales
# it down to release file locks, resets the host data directory, pre-creates
# the directory with correct UID 70:70 permissions, scales the deployment back
# up, and waits for the rollout so the database cleanly re-bootstraps from scratch.
# If no cluster/deployment is running, it resets the host directory and creates
# a clean, empty directory ready for the next startup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-.cache/postgres}"
POSTGRES_NAMESPACE="${POSTGRES_NAMESPACE:-inf-signalloom}"
POSTGRES_DEPLOYMENT="${POSTGRES_DEPLOYMENT:-postgresql}"
CONTAINER="${CLUSTER_NAME}-control-plane"

has_deployment=false
if command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
  if "$KUBECTL_BIN" get deployment "$POSTGRES_DEPLOYMENT" -n "$POSTGRES_NAMESPACE" >/dev/null 2>&1; then
    has_deployment=true
  fi
fi

if [ "$has_deployment" = true ]; then
  echo "Scaling down PostgreSQL deployment '$POSTGRES_DEPLOYMENT' in namespace '$POSTGRES_NAMESPACE'..."
  "$KUBECTL_BIN" scale deployment "$POSTGRES_DEPLOYMENT" -n "$POSTGRES_NAMESPACE" --replicas=0
  "$KUBECTL_BIN" wait --for=delete pod -l app.kubernetes.io/name="$POSTGRES_DEPLOYMENT" -n "$POSTGRES_NAMESPACE" --timeout=30s 2>/dev/null || true
fi

# Reset the data directory
CLUSTER_NAME="$CLUSTER_NAME" DOCKER_BIN="$DOCKER_BIN" POSTGRES_DATA_DIR="$POSTGRES_DATA_DIR" \
  "$SCRIPT_DIR/postgres-data-reset.sh"

# Ensure host directory is recreated
mkdir -p "$POSTGRES_DATA_DIR"

# If Kind control-plane container is running, prepare permissions
if "$DOCKER_BIN" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
  "$DOCKER_BIN" exec "$CONTAINER" mkdir -p /var/local/signalloom-postgres-data
  "$DOCKER_BIN" exec "$CONTAINER" chown -R 70:70 /var/local/signalloom-postgres-data
  "$DOCKER_BIN" exec "$CONTAINER" chmod 0700 /var/local/signalloom-postgres-data
fi

if [ "$has_deployment" = true ]; then
  echo "Scaling up PostgreSQL deployment '$POSTGRES_DEPLOYMENT' in namespace '$POSTGRES_NAMESPACE'..."
  "$KUBECTL_BIN" scale deployment "$POSTGRES_DEPLOYMENT" -n "$POSTGRES_NAMESPACE" --replicas=1
  "$KUBECTL_BIN" rollout status deployment "$POSTGRES_DEPLOYMENT" -n "$POSTGRES_NAMESPACE" --timeout=60s
  echo "PostgreSQL re-bootstrapped fresh and ready."
else
  echo "PostgreSQL data reset and recreated at '$POSTGRES_DATA_DIR'."
fi
