#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/kind-data-backup.sh : Backup and restore Kind node persistent data and identity Secrets
#
# @id     kind-data-backup
# @tests  test/kind-data-backup.bats
# @doc    docs/eap/SLDC-P2-DUAL-CLUSTER.md
#
# Usage:
#   scripts/kind-data-backup.sh backup <cluster> <dir>
#   scripts/kind-data-backup.sh restore <cluster> <dir> [--force]
#
# Backs up the three persistent host/node mount paths from <cluster>-control-plane:
#   - /var/local/signalloom-postgres-data (uid 70:70, mode 0700)
#   - /var/local/osramp-zot-cache (uid 65532:65532, mode 0750)
#   - /var/local-path-provisioner (mode 0777)
# And exports the cluster's identity Secrets stripped of dynamic metadata:
#   - fe-signalloom/signal-ingest-segment-pseudonym
#   - fe-signalloom/fleet-manager-caller-keys
#   - fe-signalloom-agents/stun-sentinel-fleet-key
#   - fe-signalloom-agents/signalloom-warden-fleet-key
#   - inf-signalloom/dex-local-auth
#   - inf-signalloom/dex-connectors
#
# Quiesces writers (scales signal-ingest and postgresql to 0) during backup to
# avoid WAL/storage tearing, and refuses restore when writers are active unless
# --force is supplied.

set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

usage() {
  cat <<'EOF'
Usage:
  scripts/kind-data-backup.sh backup <cluster> <dir>
  scripts/kind-data-backup.sh restore <cluster> <dir> [--force]
EOF
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

IDENTITY_SECRETS=(
  "fe-signalloom/signal-ingest-segment-pseudonym"
  "fe-signalloom/fleet-manager-caller-keys"
  "fe-signalloom-agents/stun-sentinel-fleet-key"
  "fe-signalloom-agents/signalloom-warden-fleet-key"
  "inf-signalloom/dex-local-auth"
  "inf-signalloom/dex-connectors"
)

WRITER_DEPLOYMENTS=(
  "fe-signalloom/signal-ingest"
  "inf-signalloom/postgresql"
)

DATA_MOUNTS=(
  "signalloom-postgres-data:/var/local/signalloom-postgres-data"
  "osramp-zot-cache:/var/local/osramp-zot-cache"
  "local-path-provisioner:/var/local-path-provisioner"
)

strip_secret_metadata() {
  awk '
    BEGIN { in_meta = 0; skip = 0 }
    /^metadata:/ { in_meta = 1; skip = 0 }
    in_meta && /^[^ ]/ && !/^metadata:/ { in_meta = 0; skip = 0 }
    in_meta && /^(  (uid|resourceVersion|creationTimestamp|generation|selfLink):|  managedFields:)/ { skip = 1; next }
    skip && in_meta && /^    / { next }
    skip && in_meta && /^  [^ ]/ { skip = 0 }
    !skip { print }
  '
}

backup_cluster() {
  local cluster="$1" dir="$2"
  local node="${cluster}-control-plane"
  local ctx="kind-${cluster}"
  local quiesced=()

  mkdir -p "$dir"
  chmod 0700 "$dir"

  restore_quiesced() {
    local dep_info ns name replicas
    for dep_info in "${quiesced[@]}"; do
      ns="${dep_info%%/*}"
      name="${dep_info#*/}"
      replicas="${name#*:}"
      name="${name%%:*}"
      "$KUBECTL_BIN" --context "$ctx" scale deployment "$name" -n "$ns" --replicas="$replicas" >/dev/null 2>&1 || true
    done
  }
  trap restore_quiesced EXIT

  # 1. Quiesce writers
  if command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
    for item in "${WRITER_DEPLOYMENTS[@]}"; do
      local ns="${item%%/*}"
      local dep="${item#*/}"
      local rep
      rep="$("$KUBECTL_BIN" --context "$ctx" get deployment "$dep" -n "$ns" -o 'jsonpath={.spec.replicas}' 2>/dev/null || true)"
      if [[ -n "$rep" && "$rep" -gt 0 ]]; then
        quiesced+=("$ns/$dep:$rep")
        "$KUBECTL_BIN" --context "$ctx" scale deployment "$dep" -n "$ns" --replicas=0 >/dev/null 2>&1 || true
        "$KUBECTL_BIN" --context "$ctx" wait --for=delete pod -l app.kubernetes.io/name="$dep" -n "$ns" --timeout=30s >/dev/null 2>&1 || true
      fi
    done
  fi

  # 2. Copy persistent data paths
  mkdir -p "$dir/data"
  for pair in "${DATA_MOUNTS[@]}"; do
    local mount_name="${pair%%:*}"
    local container_path="${pair#*:}"
    mkdir -p "$dir/data/$mount_name"
    # Try directory contents first with trailing slash / dot, fallback to direct path
    "$DOCKER_BIN" cp -a "$node:$container_path/." "$dir/data/$mount_name/" 2>/dev/null || \
      "$DOCKER_BIN" cp -a "$node:$container_path" "$dir/data/$mount_name" 2>/dev/null || true
  done

  # 3. Export identity Secrets
  mkdir -p "$dir/secrets"
  chmod 0700 "$dir/secrets"
  if command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
    for sec in "${IDENTITY_SECRETS[@]}"; do
      local ns="${sec%%/*}"
      local name="${sec#*/}"
      local raw_yaml
      raw_yaml="$("$KUBECTL_BIN" --context "$ctx" -n "$ns" get secret "$name" -o yaml 2>/dev/null || true)"
      if [ -n "$raw_yaml" ]; then
        local sec_file="$dir/secrets/${ns}__${name}.yaml"
        printf '%s\n' "$raw_yaml" | strip_secret_metadata > "$sec_file"
        chmod 0600 "$sec_file"
      fi
    done
  fi

  # 4. Generate sha256 and stat manifests
  (
    cd "$dir"
    if [ -d data ] && [ -n "$(find data -type f 2>/dev/null)" ]; then
      find data -type f -exec sha256sum {} + | sort -k2 > manifest.sha256
      find data -exec stat -c '%a %u %g %n' {} + | sort -k4 > manifest.stat
    else
      touch manifest.sha256 manifest.stat
    fi
  )

  restore_quiesced
  trap - EXIT
  echo "Backup completed for cluster $cluster to $dir"
}

restore_cluster() {
  local cluster="$1" dir="$2" force="${3:-0}"
  local node="${cluster}-control-plane"
  local ctx="kind-${cluster}"

  if [ ! -d "$dir" ]; then
    die "backup directory does not exist: $dir" 1
  fi

  # 1. Guard against active writers unless --force is given
  if [ "$force" -ne 1 ] && command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
    local active=0
    for item in "${WRITER_DEPLOYMENTS[@]}"; do
      local ns="${item%%/*}"
      local dep="${item#*/}"
      local rep
      rep="$("$KUBECTL_BIN" --context "$ctx" get deployment "$dep" -n "$ns" -o 'jsonpath={.spec.replicas}' 2>/dev/null || true)"
      if [[ -n "$rep" && "$rep" -gt 0 ]]; then
        active=1
        break
      fi
    done
    if [ "$active" -eq 1 ]; then
      die "writers are active on cluster $cluster; scale down workloads before restoring, or pass --force" 1
    fi
  fi

  # 2. Restore data paths
  for pair in "${DATA_MOUNTS[@]}"; do
    local mount_name="${pair%%:*}"
    local container_path="${pair#*:}"
    if [ -d "$dir/data/$mount_name" ]; then
      "$DOCKER_BIN" cp -a "$dir/data/$mount_name/." "$node:$container_path/" 2>/dev/null || \
        "$DOCKER_BIN" cp -a "$dir/data/$mount_name" "$node:$container_path" 2>/dev/null || true
    fi
  done

  # 3. Fix ownership in node
  "$DOCKER_BIN" exec "$node" chown -R 65532:65532 /var/local/osramp-zot-cache 2>/dev/null || true
  "$DOCKER_BIN" exec "$node" chmod 0750 /var/local/osramp-zot-cache 2>/dev/null || true
  "$DOCKER_BIN" exec "$node" chown -R 70:70 /var/local/signalloom-postgres-data 2>/dev/null || true
  "$DOCKER_BIN" exec "$node" chmod 0700 /var/local/signalloom-postgres-data 2>/dev/null || true
  "$DOCKER_BIN" exec "$node" chmod -R 0777 /var/local-path-provisioner 2>/dev/null || true

  # 4. Restore identity Secrets
  if [ -d "$dir/secrets" ] && command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
    for sec_file in "$dir/secrets"/*.yaml; do
      if [ -f "$sec_file" ]; then
        "$KUBECTL_BIN" --context "$ctx" apply -f "$sec_file" >/dev/null 2>&1 || true
      fi
    done
  fi

  echo "Restore completed for cluster $cluster from $dir"
}

main() {
  if [ $# -lt 1 ]; then
    usage >&2
    die "subcommand required (backup | restore)" 2
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    backup)
      local cluster="${1:-}" dir="${2:-}"
      [ -n "$cluster" ] || { usage >&2; die "cluster name is required" 2; }
      [ -n "$dir" ] || { usage >&2; die "backup directory is required" 2; }
      backup_cluster "$cluster" "$dir"
      ;;
    restore)
      local cluster="${1:-}" dir="${2:-}" force=0
      [ -n "$cluster" ] || { usage >&2; die "cluster name is required" 2; }
      [ -n "$dir" ] || { usage >&2; die "backup directory is required" 2; }
      shift 2 || true
      while [ $# -gt 0 ]; do
        case "$1" in
          --force) force=1 ;;
          *) usage >&2; die "unknown restore option: $1" 2 ;;
        esac
        shift
      done
      restore_cluster "$cluster" "$dir" "$force"
      ;;
    help|-h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown subcommand: $cmd" 2
      ;;
  esac
}

main "$@"
