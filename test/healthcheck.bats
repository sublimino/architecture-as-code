#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  bin="$BATS_TEST_TMPDIR/bin"
  log="$BATS_TEST_TMPDIR/kubectl.log"
  mkdir -p "$bin"

  cat >"$bin/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_LOG"

if [[ "${KUBECTL_STATE:-healthy}" == unreachable && "$*" == "get nodes" ]]; then
  exit 1
fi

if [[ "${KUBECTL_STATE:-healthy}" == not-ready && "$*" == *"wait --for=condition=Ready nodes --all"* ]]; then
  exit 1
fi

exit 0
SCRIPT
  chmod +x "$bin/kubectl"
}

@test "healthcheck verifies the API, nodes, and shared Flux foundation" {
  run env PATH="$bin:$PATH" KUBECTL_LOG="$log" "$root/scripts/healthcheck.sh"

  [ "$status" -eq 0 ]
  grep -Fq 'get nodes' "$log"
  grep -Fq 'wait --for=condition=Ready nodes --all' "$log"
  grep -Fq 'wait Kustomization/flux-system --for=condition=ready' "$log"
  grep -Fq 'wait ResourceSet/policies --for=condition=ready' "$log"
  grep -Fq 'wait ResourceSet/infra --for=condition=ready' "$log"
  [[ "$output" == *"no demos are running"* ]]
}

@test "healthcheck fails when the Kubernetes API is unreachable" {
  run env PATH="$bin:$PATH" KUBECTL_LOG="$log" KUBECTL_STATE=unreachable "$root/scripts/healthcheck.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"API server is unreachable"* ]]
}

@test "healthcheck fails when a cluster node is not Ready" {
  run env PATH="$bin:$PATH" KUBECTL_LOG="$log" KUBECTL_STATE=not-ready "$root/scripts/healthcheck.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"nodes are not Ready"* ]]
}
