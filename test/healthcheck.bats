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

# A `get ... -o json` must return a plausible object list, not silence.
#
# This stub used to print nothing and exit 0 for every query. healthcheck.sh
# calls check-flux-substitution.sh, which now distinguishes "verified clean"
# from "could not verify" and exits 2 when it scans ZERO objects -- so the
# silent stub made healthcheck fail, correctly, on the grounds that nothing had
# been examined. The stub was the thing at fault: a real cluster answers this
# query with objects, and a mock that answers with silence is not modelling the
# system, it is modelling an outage.
#
# One object, with no ${VAR} tokens in its spec, so the substitution guard has
# something real to find nothing wrong with.
if [[ "$*" == *"-o json"* ]]; then
  printf '%s\n' '{"items":[{"kind":"OCIRepository","metadata":{"name":"stub","namespace":"flux-system"},"spec":{"ref":{"tag":"v1.0.0"},"url":"oci://registry/stub"}}]}'
  exit 0
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
