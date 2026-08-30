#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  bin="$BATS_TEST_TMPDIR/bin"
  log="$BATS_TEST_TMPDIR/commands.log"
  manifests="$BATS_TEST_TMPDIR/kagent"
  mkdir -p "$bin" "$manifests"
  : >"$manifests/kustomization.yaml"
  cat >"$bin/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$COMMAND_LOG"
SCRIPT
  chmod +x "$bin/kubectl"
}

run_lifecycle() {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" WAIT_QUIET=1 \
    KAGENT_INFRA_MANIFEST_DIR="$manifests" "$root/scripts/kagent-infra.sh" "$@"
}

@test "up applies manifests then waits for each Kagent control-plane object" {
  run_lifecycle up
  [ "$status" -eq 0 ]
  grep -Fq "apply -k $manifests" "$log"
  grep -Fq 'get namespace kagent' "$log"
  for deployment in kagent-controller kagent-postgres kagent-tool-server kagent-ui; do
    grep -Fq "rollout status deploy/$deployment" "$log"
  done
  for service in kagent-postgres kagent-tool-server kagent-ui; do
    grep -Fq "get service $service" "$log"
  done
}

@test "down deletes only the configured Kagent manifest directory" {
  run_lifecycle down
  [ "$status" -eq 0 ]
  grep -Fxq "kubectl delete -k $manifests --ignore-not-found" "$log"
}

@test "status is read-only and checks every deployment" {
  run_lifecycle status
  [ "$status" -eq 0 ]
  for deployment in kagent-controller kagent-postgres kagent-tool-server kagent-ui; do
    grep -Fq "rollout status deployment/$deployment --timeout=15s" "$log"
  done
  run grep -E 'kubectl (apply|delete|create|patch|annotate) ' "$log"
  [ "$status" -ne 0 ]
}

@test "unknown lifecycle command fails with usage" {
  run_lifecycle invalid
  [ "$status" -eq 2 ]
  [[ "$output" == *'Usage: kagent-infra.sh'* ]]
}
