#!/usr/bin/env bats

@test "Kind cluster configuration mounts the durable Zot cache" {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  fake_kind="$BATS_TEST_TMPDIR/kind"
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

  run env KIND_BIN="$fake_kind" KIND_LOG="$log" KIND_CONFIG_CAPTURE="$BATS_TEST_TMPDIR/kind.yaml" \
    CLUSTER_NAME="zot-cache-test" ZOT_CACHE_DIR="$cache_dir" \
    "$repo_root/scripts/create-kind-cluster.sh"

  [ "$status" -eq 0 ]
  [ -d "$cache_dir" ]
  grep -Fq "hostPath: $cache_dir" "$BATS_TEST_TMPDIR/kind.yaml"
  grep -Fq "containerPath: /var/local/osramp-zot-cache" "$BATS_TEST_TMPDIR/kind.yaml"
  grep -Fq "create cluster --name zot-cache-test" "$log"
}

@test "Zot mounts the Kind-provided host cache with non-root ownership preparation" {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  manifest="$repo_root/d2-osramp-fleet/local/zot.yaml"

  grep -Fq "name: prepare-data" "$manifest"
  grep -Fq "chown 65532:65532 /var/lib/zot" "$manifest"
  grep -Fq "path: /var/local/osramp-zot-cache" "$manifest"
  grep -Fq "type: DirectoryOrCreate" "$manifest"
  grep -Fq "mountPath: /var/lib/zot" "$manifest"
}
