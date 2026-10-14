#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# test/kind-data-backup.bats : Verify kind-data-backup.sh backup, restore, refusals, and round-trips

setup() {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  script="$repo_root/scripts/kind-data-backup.sh"
}

@test "BACKUP: refusals on unknown subcommand, missing cluster, or missing directory" {
  fake_docker="$BATS_TEST_TMPDIR/docker-refuse"
  fake_kubectl="$BATS_TEST_TMPDIR/kubectl-refuse"
  log="$BATS_TEST_TMPDIR/refuse.log"

  cat >"$fake_docker" <<SCRIPT
#!/usr/bin/env bash
echo "docker \$*" >> "$log"
SCRIPT
  chmod +x "$fake_docker"

  cat >"$fake_kubectl" <<SCRIPT
#!/usr/bin/env bash
echo "kubectl \$*" >> "$log"
SCRIPT
  chmod +x "$fake_kubectl"

  # 1. Unknown subcommand
  run env DOCKER_BIN="$fake_docker" KUBECTL_BIN="$fake_kubectl" \
    bash "$script" unknown-command "test-cluster" "$BATS_TEST_TMPDIR/backup-dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown subcommand"* ]]

  # 2. Missing cluster on backup
  run env DOCKER_BIN="$fake_docker" KUBECTL_BIN="$fake_kubectl" \
    bash "$script" backup
  [ "$status" -ne 0 ]
  [[ "$output" == *"cluster name is required"* ]]

  # 3. Missing directory on backup
  run env DOCKER_BIN="$fake_docker" KUBECTL_BIN="$fake_kubectl" \
    bash "$script" backup "test-cluster"
  [ "$status" -ne 0 ]
  [[ "$output" == *"directory is required"* ]]

  # 4. Non-existent directory on restore
  run env DOCKER_BIN="$fake_docker" KUBECTL_BIN="$fake_kubectl" \
    bash "$script" restore "test-cluster" "$BATS_TEST_TMPDIR/nonexistent-backup-dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"backup directory does not exist"* ]]

  # Assert no docker cp was called during any refusal
  if [ -f "$log" ]; then
    ! grep -Fq "docker cp" "$log"
  fi
}

@test "BACKUP: restore refuses when writers are active unless --force is given" {
  fake_docker="$BATS_TEST_TMPDIR/docker-active"
  fake_kubectl="$BATS_TEST_TMPDIR/kubectl-active"
  docker_log="$BATS_TEST_TMPDIR/docker-active.log"
  kubectl_log="$BATS_TEST_TMPDIR/kubectl-active.log"

  cat >"$fake_docker" <<SCRIPT
#!/usr/bin/env bash
echo "docker \$*" >> "$docker_log"
SCRIPT
  chmod +x "$fake_docker"

  cat >"$fake_kubectl" <<SCRIPT
#!/usr/bin/env bash
echo "kubectl \$*" >> "$kubectl_log"
case "\$*" in
  *"get deployment"*)
    echo "1"
    exit 0
    ;;
esac
exit 0
SCRIPT
  chmod +x "$fake_kubectl"

  backup_dir="$BATS_TEST_TMPDIR/existing-backup"
  mkdir -p "$backup_dir/data"

  # Restore without --force must refuse
  run env DOCKER_BIN="$fake_docker" KUBECTL_BIN="$fake_kubectl" \
    bash "$script" restore "osramp" "$backup_dir"

  [ "$status" -ne 0 ]
  [[ "$output" == *"writers are active"* ]]
  if [ -f "$docker_log" ]; then
    ! grep -Fq "docker cp" "$docker_log"
  fi

  # Restore with --force must proceed
  run env DOCKER_BIN="$fake_docker" KUBECTL_BIN="$fake_kubectl" \
    bash "$script" restore "osramp" "$backup_dir" --force

  [ "$status" -eq 0 ]
  [[ "$output" == *"Restore completed"* ]]
}

@test "BACKUP: full backup and restore round-trip preserves byte-for-byte fidelity, stat, and symlinks" {
  # Setup fake node filesystem
  node_fs="$BATS_TEST_TMPDIR/node-fs"
  export node_fs
  mkdir -p "$node_fs/var/local/signalloom-postgres-data/sub dir"
  mkdir -p "$node_fs/var/local/osramp-zot-cache"
  mkdir -p "$node_fs/var/local-path-provisioner/d2-signalloom/signal-store"

  # Populate test data
  echo "postgres secret data" > "$node_fs/var/local/signalloom-postgres-data/pg.dat"
  echo "file with space" > "$node_fs/var/local/signalloom-postgres-data/sub dir/spaced file.txt"
  touch "$node_fs/var/local/signalloom-postgres-data/empty.txt"
  ln -s "pg.dat" "$node_fs/var/local/signalloom-postgres-data/pg-symlink"
  chmod 0700 "$node_fs/var/local/signalloom-postgres-data"

  echo "zot blob data" > "$node_fs/var/local/osramp-zot-cache/blob1.tar.gz"
  echo "frostdb wal records" > "$node_fs/var/local-path-provisioner/d2-signalloom/signal-store/wal.dat"

  fake_docker="$BATS_TEST_TMPDIR/docker-roundtrip"
  fake_kubectl="$BATS_TEST_TMPDIR/kubectl-roundtrip"
  calls_log="$BATS_TEST_TMPDIR/calls.log"
  export calls_log

  cat >"$fake_docker" <<'SCRIPT'
#!/usr/bin/env bash
echo "docker $*" >> "$calls_log"
if [ "$1" = "cp" ]; then
  shift
  has_a=0
  if [ "$1" = "-a" ]; then
    has_a=1
    shift
  fi
  src="$1"
  dst="$2"

  # Strip container prefix
  if [[ "$src" == *"osramp-control-plane:"* ]]; then
    rel_path="${src#*osramp-control-plane:}"
    rel_path="${rel_path%/.}"; rel_path="${rel_path%/}"
    mkdir -p "$dst"
    if [ "$has_a" -eq 1 ]; then
      cp -a "$node_fs$rel_path/." "$dst/" 2>/dev/null || cp -a "$node_fs$rel_path" "$dst"
    else
      # plain cp -r: dereference symlinks or fail to preserve symlinks
      cp -r --dereference "$node_fs$rel_path/." "$dst/" 2>/dev/null || cp -r --dereference "$node_fs$rel_path" "$dst"
    fi
  elif [[ "$dst" == *"osramp-control-plane:"* ]]; then
    rel_path="${dst#*osramp-control-plane:}"
    rel_path="${rel_path%/.}"; rel_path="${rel_path%/}"
    src_clean="${src%/.}"; src_clean="${src_clean%/}"
    mkdir -p "$node_fs$rel_path"
    if [ "$has_a" -eq 1 ]; then
      cp -a "$src_clean/." "$node_fs$rel_path/" 2>/dev/null || cp -a "$src_clean" "$node_fs$rel_path"
    else
      cp -r --dereference "$src_clean/." "$node_fs$rel_path/" 2>/dev/null || cp -r --dereference "$src_clean" "$node_fs$rel_path"
    fi
  fi
  exit 0
fi
exit 0
SCRIPT
  chmod +x "$fake_docker"

  cat >"$fake_kubectl" <<SCRIPT
#!/usr/bin/env bash
echo "kubectl \$*" >> "$calls_log"
case "\$*" in
  *"get deployment"*)
    echo "1"
    exit 0
    ;;
esac
exit 0
SCRIPT
  chmod +x "$fake_kubectl"

  backup_dir="$BATS_TEST_TMPDIR/backup-target"

  # 1. Run backup
  run env DOCKER_BIN="$fake_docker" KUBECTL_BIN="$fake_kubectl" \
    bash "$script" backup "osramp" "$backup_dir"

  [ "$status" -eq 0 ]
  [ -d "$backup_dir" ]
  [ -f "$backup_dir/manifest.sha256" ]
  [ -f "$backup_dir/manifest.stat" ]

  # Check that writers were quiesced and restored
  grep -Fq "scale deployment signal-ingest -n fe-signalloom --replicas=0" "$calls_log"
  grep -Fq "scale deployment postgresql -n inf-signalloom --replicas=0" "$calls_log"
  grep -Fq "scale deployment signal-ingest -n fe-signalloom --replicas=1" "$calls_log"
  grep -Fq "scale deployment postgresql -n inf-signalloom --replicas=1" "$calls_log"

  # 2. Capture source manifest before mutation
  source_manifest="$BATS_TEST_TMPDIR/source.sha256"
  (
    cd "$backup_dir"
    find data -type f -exec sha256sum {} + | sort -k2 > "$source_manifest"
  )

  # 3. Simulate wiping/recreating node filesystem
  rm -rf "$node_fs/var/local/signalloom-postgres-data"
  rm -rf "$node_fs/var/local/osramp-zot-cache"
  rm -rf "$node_fs/var/local-path-provisioner"

  # 4. Run restore
  run env DOCKER_BIN="$fake_docker" KUBECTL_BIN="$fake_kubectl" \
    bash "$script" restore "osramp" "$backup_dir" --force

  [ "$status" -eq 0 ]

  # 5. Verify restored data matches byte-for-byte
  [ -f "$node_fs/var/local/signalloom-postgres-data/pg.dat" ]
  [ -f "$node_fs/var/local/signalloom-postgres-data/sub dir/spaced file.txt" ]
  [ -L "$node_fs/var/local/signalloom-postgres-data/pg-symlink" ]
  [ -f "$node_fs/var/local/osramp-zot-cache/blob1.tar.gz" ]
  [ -f "$node_fs/var/local-path-provisioner/d2-signalloom/signal-store/wal.dat" ]

  [ "$(cat "$node_fs/var/local/signalloom-postgres-data/pg.dat")" = "postgres secret data" ]
  [ "$(cat "$node_fs/var/local/signalloom-postgres-data/sub dir/spaced file.txt")" = "file with space" ]
  [ "$(cat "$node_fs/var/local/osramp-zot-cache/blob1.tar.gz")" = "zot blob data" ]
  [ "$(cat "$node_fs/var/local-path-provisioner/d2-signalloom/signal-store/wal.dat")" = "frostdb wal records" ]

  # Verify ownership fix commands ran in node
  grep -Fq "exec osramp-control-plane chown -R 70:70 /var/local/signalloom-postgres-data" "$calls_log"
  grep -Fq "exec osramp-control-plane chmod 0700 /var/local/signalloom-postgres-data" "$calls_log"
  grep -Fq "exec osramp-control-plane chown -R 65532:65532 /var/local/osramp-zot-cache" "$calls_log"
  grep -Fq "exec osramp-control-plane chmod 0750 /var/local/osramp-zot-cache" "$calls_log"
}

@test "BACKUP: identity Secrets round-trip exports with stripped metadata and restores successfully" {
  fake_docker="$BATS_TEST_TMPDIR/docker-sec"
  fake_kubectl="$BATS_TEST_TMPDIR/kubectl-sec"
  sec_log="$BATS_TEST_TMPDIR/secrets.log"

  cat >"$fake_docker" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
  chmod +x "$fake_docker"

  cat >"$fake_kubectl" <<'SCRIPT'
#!/usr/bin/env bash
echo "kubectl $*" >> "$sec_log"
case "$*" in
  *"get secret"*)
    sec_name="${@: -3:1}"
    if [ "$sec_name" = "-o" ]; then
      sec_name="${@: -4:1}"
    fi
    cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: $sec_name
  namespace: fe-signalloom
  uid: "12345-dynamic-uid"
  resourceVersion: "99999"
  creationTimestamp: "2026-10-06T12:00:00Z"
  generation: 1
  managedFields:
    - manager: kubectl
      operation: Update
data:
  token: "dGVzdC10b2tlbi12YWx1ZQ=="
YAML
    exit 0
    ;;
  *"apply -f"*)
    cat "${@: -1}" >> "$BATS_TEST_TMPDIR/restored-secrets.yaml"
    exit 0
    ;;
esac
exit 0
SCRIPT
  chmod +x "$fake_kubectl"

  backup_dir="$BATS_TEST_TMPDIR/backup-sec"

  # 1. Run backup
  run env DOCKER_BIN="$fake_docker" KUBECTL_BIN="$fake_kubectl" \
    bash "$script" backup "osramp" "$backup_dir"

  [ "$status" -eq 0 ]
  [ -d "$backup_dir/secrets" ]

  # Verify dynamic metadata was stripped
  local sec_file="$backup_dir/secrets/fe-signalloom__signal-ingest-segment-pseudonym.yaml"
  [ -f "$sec_file" ]

  ! grep -Fq "uid:" "$sec_file"
  ! grep -Fq "resourceVersion:" "$sec_file"
  ! grep -Fq "creationTimestamp:" "$sec_file"
  ! grep -Fq "managedFields:" "$sec_file"
  grep -Fq "token: \"dGVzdC10b2tlbi12YWx1ZQ==\"" "$sec_file"
  grep -Fq "name: signal-ingest-segment-pseudonym" "$sec_file"
  grep -Fq "namespace: fe-signalloom" "$sec_file"

  # 2. Run restore
  run env DOCKER_BIN="$fake_docker" KUBECTL_BIN="$fake_kubectl" \
    bash "$script" restore "osramp" "$backup_dir" --force

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/restored-secrets.yaml" ]
  grep -Fq "name: signal-ingest-segment-pseudonym" "$BATS_TEST_TMPDIR/restored-secrets.yaml"
  grep -Fq "name: fleet-manager-caller-keys" "$BATS_TEST_TMPDIR/restored-secrets.yaml"
}
