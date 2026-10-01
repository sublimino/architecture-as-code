#!/usr/bin/env bats

@test "Kind cluster configuration mounts the durable Postgres data directory" {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  fake_kind="$BATS_TEST_TMPDIR/kind"
  fake_docker="$BATS_TEST_TMPDIR/docker"
  zot_dir="$BATS_TEST_TMPDIR/zot-cache"
  pg_dir="$BATS_TEST_TMPDIR/postgres-data"
  log="$BATS_TEST_TMPDIR/kind.log"

  cat >"$fake_kind" <<'SCRIPT'
#!/usr/bin/env bash
if [ "$1" = get ]; then
  exit 0
fi
printf '%s ' "$@" >"$KIND_LOG"
printf '\n' >>"$KIND_LOG"
config="${@: -1}"
cp "$config" "$KIND_CONFIG_CAPTURE"
SCRIPT
  chmod +x "$fake_kind"

  cat >"$fake_docker" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s ' "$@" >>"$DOCKER_LOG"
printf '\n' >>"$DOCKER_LOG"
SCRIPT
  chmod +x "$fake_docker"

  run env KIND_BIN="$fake_kind" DOCKER_BIN="$fake_docker" DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log" KIND_LOG="$log" KIND_CONFIG_CAPTURE="$BATS_TEST_TMPDIR/kind.yaml" \
    CLUSTER_NAME="postgres-cache-test" ZOT_CACHE_DIR="$zot_dir" POSTGRES_DATA_DIR="$pg_dir" \
    "$repo_root/scripts/create-kind-cluster.sh"

  [ "$status" -eq 0 ]
  [ -d "$pg_dir" ]
  grep -Fq "hostPath: $pg_dir" "$BATS_TEST_TMPDIR/kind.yaml"
  grep -Fq "containerPath: /var/local/signalloom-postgres-data" "$BATS_TEST_TMPDIR/kind.yaml"
  grep -Fq "create cluster --name postgres-cache-test" "$log"
  grep -Fq "exec postgres-cache-test-control-plane mkdir -p /var/local/signalloom-postgres-data" "$BATS_TEST_TMPDIR/docker.log"
  grep -Fq "exec postgres-cache-test-control-plane chown -R 70:70 /var/local/signalloom-postgres-data" "$BATS_TEST_TMPDIR/docker.log"
  grep -Fq "exec postgres-cache-test-control-plane chmod 0700 /var/local/signalloom-postgres-data" "$BATS_TEST_TMPDIR/docker.log"
}

@test "Kind Postgres cache preparation is applied even for an existing cluster" {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  fake_kind="$BATS_TEST_TMPDIR/kind"
  fake_docker="$BATS_TEST_TMPDIR/docker"
  zot_dir="$BATS_TEST_TMPDIR/zot-cache-existing"
  pg_dir="$BATS_TEST_TMPDIR/postgres-data-existing"
  log="$BATS_TEST_TMPDIR/kind-existing.log"

  cat >"$fake_kind" <<'SCRIPT'
#!/usr/bin/env bash
if [ "$1" = get ]; then
  printf 'postgres-cache-existing\n'
  exit 0
fi
SCRIPT
  chmod +x "$fake_kind"

  cat >"$fake_docker" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s ' "$@" >>"$DOCKER_LOG"
printf '\n' >>"$DOCKER_LOG"
SCRIPT
  chmod +x "$fake_docker"

  run env KIND_BIN="$fake_kind" DOCKER_BIN="$fake_docker" DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log" KIND_LOG="$log" \
    CLUSTER_NAME="postgres-cache-existing" ZOT_CACHE_DIR="$zot_dir" POSTGRES_DATA_DIR="$pg_dir" \
    "$repo_root/scripts/create-kind-cluster.sh"

  [ "$status" -eq 0 ]
  grep -Fq "exec postgres-cache-existing-control-plane chown -R 70:70 /var/local/signalloom-postgres-data" "$BATS_TEST_TMPDIR/docker.log"
  grep -Fq "exec postgres-cache-existing-control-plane chmod 0700 /var/local/signalloom-postgres-data" "$BATS_TEST_TMPDIR/docker.log"
}

@test "PostgreSQL manifest mounts the hostPath data directory and sets PGDATA" {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  manifest="$repo_root/d2-signalloom/infra/inf-signalloom/controllers/base/dependencies.yaml"

  grep -Fq "path: /var/local/signalloom-postgres-data" "$manifest"
  grep -Fq "type: DirectoryOrCreate" "$manifest"
  grep -Fq "mountPath: /var/lib/postgresql/data" "$manifest"
  grep -Fq "name: PGDATA" "$manifest"
  grep -Fq "value: /var/lib/postgresql/data/pgdata" "$manifest"
}

@test "PostgreSQL data reset removes unprivileged user-owned data directory" {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  test_dir="$BATS_TEST_TMPDIR/pg-fast-reset"
  mkdir -p "$test_dir/pgdata"
  echo "dummy" > "$test_dir/pgdata/test.txt"

  run env POSTGRES_DATA_DIR="$test_dir" \
    "$repo_root/scripts/postgres-data-reset.sh"

  [ "$status" -eq 0 ]
  [ ! -e "$test_dir" ]
}

@test "PostgreSQL data reset invokes container clear when files cannot be removed directly" {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  test_dir="$BATS_TEST_TMPDIR/pg-slow-reset"
  mkdir -p "$test_dir"
  touch "$test_dir/file.txt"

  fake_docker="$BATS_TEST_TMPDIR/docker"
  cat >"$fake_docker" <<'SCRIPT'
#!/usr/bin/env bash
if [ "$1" = "ps" ]; then
  printf 'pg-test-control-plane\n'
  exit 0
fi
printf '%s ' "$@" >>"$DOCKER_LOG"
printf '\n' >>"$DOCKER_LOG"
# Simulate removing the files in the directory
rm -f "$HOST_DIR"/* "$HOST_DIR"/.[!.]* "$HOST_DIR"/..?* 2>/dev/null || true
SCRIPT
  chmod +x "$fake_docker"

  # Override rm so the fast-path fails, forcing the slow container path
  fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/rm" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$*" == *"pg-slow-reset"* ]]; then
  echo "rm: cannot remove: Permission denied" >&2
  exit 1
fi
exec /bin/rm "$@"
SCRIPT
  chmod +x "$fake_bin/rm"

  run env PATH="$fake_bin:$PATH" DOCKER_BIN="$fake_docker" DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log" \
    HOST_DIR="$test_dir" CLUSTER_NAME="pg-test" POSTGRES_DATA_DIR="$test_dir" \
    "$repo_root/scripts/postgres-data-reset.sh"

  [ "$status" -eq 0 ]
  grep -Fq "exec pg-test-control-plane sh -c" "$BATS_TEST_TMPDIR/docker.log"
}

@test "PostgreSQL data recreate resets data and safely scales deployment when present" {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  test_dir="$BATS_TEST_TMPDIR/pg-recreate-active"
  mkdir -p "$test_dir"
  touch "$test_dir/file.txt"

  fake_kubectl="$BATS_TEST_TMPDIR/kubectl"
  cat >"$fake_kubectl" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s ' "$@" >>"$KUBECTL_LOG"
printf '\n' >>"$KUBECTL_LOG"
exit 0
SCRIPT
  chmod +x "$fake_kubectl"

  fake_docker="$BATS_TEST_TMPDIR/docker"
  cat >"$fake_docker" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s ' "$@" >>"$DOCKER_LOG"
printf '\n' >>"$DOCKER_LOG"
if [ "$1" = "ps" ]; then
  printf 'pg-recreate-control-plane\n'
fi
exit 0
SCRIPT
  chmod +x "$fake_docker"

  run env KUBECTL_BIN="$fake_kubectl" KUBECTL_LOG="$BATS_TEST_TMPDIR/kubectl.log" \
    DOCKER_BIN="$fake_docker" DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log" \
    CLUSTER_NAME="pg-recreate" POSTGRES_DATA_DIR="$test_dir" \
    "$repo_root/scripts/postgres-data-recreate.sh"

  [ "$status" -eq 0 ]
  [ -d "$test_dir" ]
  grep -Fq "scale deployment postgresql -n inf-signalloom --replicas=0" "$BATS_TEST_TMPDIR/kubectl.log"
  grep -Fq "scale deployment postgresql -n inf-signalloom --replicas=1" "$BATS_TEST_TMPDIR/kubectl.log"
  grep -Fq "rollout status deployment postgresql -n inf-signalloom" "$BATS_TEST_TMPDIR/kubectl.log"
  grep -Fq "exec pg-recreate-control-plane mkdir -p /var/local/signalloom-postgres-data" "$BATS_TEST_TMPDIR/docker.log"
  grep -Fq "exec pg-recreate-control-plane chown -R 70:70 /var/local/signalloom-postgres-data" "$BATS_TEST_TMPDIR/docker.log"
  grep -Fq "exec pg-recreate-control-plane chmod 0700 /var/local/signalloom-postgres-data" "$BATS_TEST_TMPDIR/docker.log"
}

@test "PostgreSQL data recreate functions cleanly when no deployment is present" {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  test_dir="$BATS_TEST_TMPDIR/pg-recreate-inactive"
  mkdir -p "$test_dir"

  fake_kubectl="$BATS_TEST_TMPDIR/kubectl"
  cat >"$fake_kubectl" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
  chmod +x "$fake_kubectl"

  fake_docker="$BATS_TEST_TMPDIR/docker"
  cat >"$fake_docker" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
  chmod +x "$fake_docker"

  run env KUBECTL_BIN="$fake_kubectl" DOCKER_BIN="$fake_docker" \
    CLUSTER_NAME="pg-recreate" POSTGRES_DATA_DIR="$test_dir" \
    "$repo_root/scripts/postgres-data-recreate.sh"

  [ "$status" -eq 0 ]
  [ -d "$test_dir" ]
}
