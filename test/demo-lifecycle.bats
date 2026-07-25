#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  bin="$BATS_TEST_TMPDIR/bin"
  log="$BATS_TEST_TMPDIR/kubectl.log"
  mkdir -p "$bin"
  cat >"$bin/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_LOG"
if [[ "$*" == *get* ]]; then
  case "${KUBECTL_STATE:-empty}" in
    empty) printf '{"items":[]}' ;;
    consumer) printf '{"items":[{"kind":"Kustomization","metadata":{"namespace":"fe-signalloom","name":"apps","labels":{"bao.controlplane.io/consumer":"fe-signalloom"}}}]}' ;;
    unknown) printf 'api unavailable' >&2; exit 1 ;;
  esac
fi
SCRIPT
  chmod +x "$bin/kubectl"
}

@test "compatibility aliases and every canonical lifecycle target are real Make targets" {
  run make -n cluster-up cluster-down flux-bootstrap flux-test demo-bao-up demo-bao-test-config demo-bao-test demo-bao-down demo-signalloom-up demo-signalloom-test-config demo-signalloom-test demo-signalloom-down demo-osramp-up demo-osramp-test-config demo-osramp-test demo-osramp-down demo-olly-up demo-olly-test-config demo-olly-test demo-olly-down demo-signalloom-stack-up demo-signalloom-stack-down demo-signalloom-stack-purge
  [ "$status" -eq 0 ]
  [[ "$output" == *"demo-lifecycle.sh bao-up"* ]]
  [[ "$output" == *"create-kind-cluster.sh"* ]]
}

@test "stack purge fails closed while a labelled Bao consumer remains" {
  run env PATH="$bin:$PATH" KUBECTL_LOG="$log" KUBECTL_STATE=consumer "$root/scripts/demo-lifecycle.sh" stack-purge
  [ "$status" -ne 0 ]
  [[ "$output" == *"Bao consumers remain"* ]]
  ! grep -Fq 'delete namespace fe-signalloom' "$log"
  ! grep -Fq 'delete namespace inf-bao' "$log"
}

@test "stack purge fails closed when the authoritative consumer query is unavailable" {
  run env PATH="$bin:$PATH" KUBECTL_LOG="$log" KUBECTL_STATE=unknown "$root/scripts/demo-lifecycle.sh" stack-purge
  [ "$status" -ne 0 ]
  [[ "$output" == *"consumer state is unavailable or unknown"* ]]
  ! grep -Fq 'delete namespace fe-signalloom' "$log"
  ! grep -Fq 'delete namespace inf-bao' "$log"
}

@test "explicit force is the only purge override" {
  run env PATH="$bin:$PATH" KUBECTL_LOG="$log" KUBECTL_STATE=consumer DEMO_BAO_FORCE=1 "$root/scripts/demo-lifecycle.sh" stack-purge
  [ "$status" -eq 0 ]
  grep -Fq 'delete namespace inf-bao' "$log"
}
