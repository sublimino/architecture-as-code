#!/usr/bin/env bats

@test "Kind cluster configuration mounts the durable Zot cache" {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  fake_kind="$BATS_TEST_TMPDIR/kind"
  fake_docker="$BATS_TEST_TMPDIR/docker"
  cache_dir="$BATS_TEST_TMPDIR/zot-cache"
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
    CLUSTER_NAME="zot-cache-test" ZOT_CACHE_DIR="$cache_dir" \
    "$repo_root/scripts/create-kind-cluster.sh"

  [ "$status" -eq 0 ]
  [ -d "$cache_dir" ]
  grep -Fq "hostPath: $cache_dir" "$BATS_TEST_TMPDIR/kind.yaml"
  grep -Fq "containerPath: /var/local/osramp-zot-cache" "$BATS_TEST_TMPDIR/kind.yaml"
  grep -Fq "create cluster --name zot-cache-test" "$log"
  grep -Fq "exec zot-cache-test-control-plane chown 65532:65532 /var/local/osramp-zot-cache" "$BATS_TEST_TMPDIR/docker.log"
}

@test "Zot mounts the Kind-provided host cache with non-root ownership preparation" {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  manifest="$repo_root/d2-osramp-fleet/local/zot.yaml"

  grep -Fq "name: prepare-data" "$manifest"
  grep -Fq "test -w /var/lib/zot" "$manifest"
  grep -Fq "runAsNonRoot: true" "$manifest"
  grep -Fq "runAsUser: 65532" "$manifest"
  ! grep -Fq "runAsUser: 0" "$manifest"
  grep -Fq "path: /var/local/osramp-zot-cache" "$manifest"
  grep -Fq "type: DirectoryOrCreate" "$manifest"
  grep -Fq "mountPath: /var/lib/zot" "$manifest"
}

@test "Kind cache preparation is applied even for an existing cluster" {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  fake_kind="$BATS_TEST_TMPDIR/kind"
  fake_docker="$BATS_TEST_TMPDIR/docker"
  cache_dir="$BATS_TEST_TMPDIR/zot-cache-existing"
  log="$BATS_TEST_TMPDIR/kind-existing.log"

  cat >"$fake_kind" <<'SCRIPT'
#!/usr/bin/env bash
if [ "$1" = get ]; then
  printf 'zot-cache-existing\n'
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
    CLUSTER_NAME="zot-cache-existing" ZOT_CACHE_DIR="$cache_dir" \
    "$repo_root/scripts/create-kind-cluster.sh"

  [ "$status" -eq 0 ]
  grep -Fq "exec zot-cache-existing-control-plane chown 65532:65532 /var/local/osramp-zot-cache" "$BATS_TEST_TMPDIR/docker.log"
  grep -Fq "exec zot-cache-existing-control-plane chmod 0750 /var/local/osramp-zot-cache" "$BATS_TEST_TMPDIR/docker.log"
}
