#!/usr/bin/env bats

setup() {
  repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  fleet="$repo_root/d2-osramp-fleet/tenants/local/signalloom.yaml"
}

@test "Netassert runtime target is fail-closed and delegates to one runner" {
  run make -C "$repo_root/d2-signalloom" -n test-netassert
  [ "$status" -eq 0 ]
  [[ "$output" == *"test/run-netassert.sh"* ]]
  [[ "$output" != *"not installed"* ]]
  [[ "$output" != *"skipping"* ]]

  run grep -F '$(MAKE) -C d2-signalloom test-netassert' "$repo_root/Makefile"
  [ "$status" -eq 0 ]
  run grep -F 'skipping NetworkPolicy tests' "$repo_root/Makefile"
  [ "$status" -eq 1 ]
}

@test "standard bring-up preloads the Never-pull Netassert runner image" {
  runner_line="$(grep -n '^\s*$(MAKE) netassert-runner-image' "$repo_root/Makefile" | cut -d: -f1)"
  deploy_line="$(grep -n 'signalloom-local.sh up' "$repo_root/Makefile" | cut -d: -f1)"
  [ -n "$runner_line" ]
  [ -n "$deploy_line" ]
  [ "$runner_line" -lt "$deploy_line" ]
}

@test "Netassert controller and runner resources render in signed slice artifacts" {
  run kubectl kustomize "$repo_root/d2-signalloom/infra/inf-signalloom/configs/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: netassert-controller"* ]]
  [[ "$output" == *"name: netassert-scan-manager"* ]]
  [[ "$output" == *"name: allow-netassert-controller"* ]]

  run kubectl kustomize "$repo_root/d2-signalloom/apps/fe-signalloom/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: netassert-runner"* ]]
  [[ "$output" == *"name: netassert-signalloom-config"* ]]

  run grep -F 'provider: cosign' "$repo_root/d2-osramp-fleet/tenants/local/kustomization.yaml"
  [ "$status" -eq 0 ]
}

@test "ephemeral-container patch is namespaced to four required namespaces" {
  run bash -c "yq e -r '
    select(.kind == \"ResourceSet\")
    | .metadata.name as \$rs
    | .spec.resources[]
    | select(.kind == \"Role\")
    | .metadata.namespace as \$ns
    | .rules[]
    | select(.resources[] == \"pods/ephemeralcontainers\")
    | [\$rs, \$ns, (.verbs | join(\",\"))] | @tsv
  ' '$fleet' | grep -vE '^$|^---$'"
  [ "$status" -eq 0 ]
  [ "$output" = $'signalloom-infra\tfe-signalloom-agents\tpatch\nsignalloom-infra\t<< inputs.tenant >>\tpatch\nsignalloom-apps\t<< inputs.tenant >>\tpatch' ]
  run yq e -r '
    select(.kind == "ResourceSet")
    | .spec.resources[]
    | select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding")
    | select(.metadata.name | test("netassert"))
    | .metadata.name
  ' "$fleet"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "both CI pipelines execute the mandatory Netassert runtime stage" {
  for pipeline in scripts/ci/vm-pipeline.sh scripts/gcp-tf/demo-pipeline.sh; do
    run grep -F 'Live NetworkPolicy enforcement (netassert)' "$repo_root/$pipeline"
    [ "$status" -eq 0 ]
    run grep -F 'make -C d2-signalloom test-netassert' "$repo_root/$pipeline"
    [ "$status" -eq 0 ]
  done
}

@test "runtime runner fails clearly when Kubernetes is unreachable" {
  fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/kubectl" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" != "cluster-info" ]]
SH
  chmod +x "$fake_bin/kubectl"

  run env PATH="$fake_bin:$PATH" "$repo_root/d2-signalloom/test/run-netassert.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"netassert runtime prerequisite failed: Kubernetes cluster is unreachable"* ]]
  [[ "$output" != *"skip"* ]]
}

@test "deployed fallback and optional SuperCred preconditions remain explicit" {
  runner="$repo_root/d2-signalloom/test/run-netassert.sh"
  run grep -F 'deployment/netassert-controller is unavailable' "$runner"
  [ "$status" -eq 0 ]
  run grep -F 'http://127.0.0.1:18082/scan' "$runner"
  [ "$status" -eq 0 ]
  run grep -F 'SuperCred cases require deployment/cardvault' "$runner"
  [ "$status" -eq 0 ]
  run grep -F 'SuperCred cases require pod/agent-cardvault' "$runner"
  [ "$status" -eq 0 ]
}
