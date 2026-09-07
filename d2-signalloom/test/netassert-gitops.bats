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

  run grep -F 'command -v netassert' "$repo_root/d2-signalloom/test/run-netassert.sh"
  [ "$status" -eq 1 ]
  run grep -F 'netassert run -f' "$repo_root/d2-signalloom/test/run-netassert.sh"
  [ "$status" -eq 1 ]

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

@test "fleet owns hardened sustained Netassert fixtures in agents namespace" {
  run yq ea -e '
    select(.kind == "ResourceSet" and .metadata.name == "signalloom-netassert-fixtures")
    | ((.spec.dependsOn[0].name == "apps") and
      (([.spec.resources[] | select(.kind == "Deployment")] | length) == 2) and
      ([.spec.resources[] | select(.kind == "Deployment") | .metadata.namespace] | all_c(. == "fe-signalloom-agents")) and
      ([.spec.resources[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].image] | all_c(. == "netassert-runner:local")) and
      ([.spec.resources[] | select(.kind == "Deployment") | .spec.template.spec.automountServiceAccountToken] | all_c(. == false)) and
      ([.spec.resources[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation] | all_c(. == false)))
  ' "$fleet"
  [ "$status" -eq 0 ]
}

@test "fixture labels model policy identities without kagent ownership" {
  run yq ea -e '
    select(.kind == "ResourceSet" and .metadata.name == "signalloom-netassert-fixtures")
    | ([.spec.resources[] | select(.metadata.name == "netassert-generic-agent-fixture")
        | .spec.template.metadata.labels] | .[0]) as $generic
    | ([.spec.resources[] | select(.metadata.name == "netassert-cardvault-agent-fixture")
        | .spec.template] | .[0]) as $cardvault
    | (($generic."signalloom.ai/agent" == "true") and
      ($generic."signalloom.ai/framework" == "custom") and
      ($generic."netassert.signalloom.ai/fixture" == "generic-agent") and
      ($generic."app.kubernetes.io/managed-by" == null) and
      ($generic.app == null) and
      ($cardvault.spec.serviceAccountName == "cardvault-agent") and
      ($cardvault.metadata.labels."app.kubernetes.io/name" == "cardvault-agent") and
      ($cardvault.metadata.labels."signalloom.ai/supercred" == "true") and
      ($cardvault.metadata.labels."bao.controlplane.io/consumer" == "cardvault-agent") and
      ($cardvault.metadata.labels."netassert.signalloom.ai/fixture" == "cardvault-agent"))
  ' "$fleet"
  [ "$status" -eq 0 ]
}

@test "ephemeral-container patch is namespaced to six required namespaces" {
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
  [ "$output" = $'signalloom-infra\tfe-signalloom-agents\tpatch\nsignalloom-infra\t<< inputs.tenant >>\tpatch\nsignalloom-infra\tingress\tpatch\nsignalloom-infra\tkube-system\tpatch\nsignalloom-apps\t<< inputs.tenant >>\tpatch' ]
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
  run grep -F 'preflight_suite_resources' "$runner"
  [ "$status" -eq 0 ]
  run grep -F 'configured ${side} resource is absent' "$runner"
  [ "$status" -eq 0 ]
}

@test "suite preflight validates labeled sources and destination deployments" {
  config="$BATS_TEST_TMPDIR/resources.yaml"
  calls="$BATS_TEST_TMPDIR/kubectl.calls"
  fake_bin="$BATS_TEST_TMPDIR/preflight-bin"
  mkdir -p "$fake_bin"
  cat >"$config" <<'YAML'
- name: agent-to-cardvault
  src:
    k8sResource: {kind: pod, name: agent-patsy, namespace: fe-signalloom-agents}
  dst:
    k8sResource: {kind: deployment, name: cardvault, namespace: inf-signalloom}
YAML
  cat >"$fake_bin/kubectl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_CALLS"
if [[ "$*" == *"get pods"*"netassert.signalloom.ai/fixture=generic-agent"* ]]; then
  printf '{"items":[{"metadata":{"name":"agent-fixture"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}\n'
fi
exit 0
SH
  chmod +x "$fake_bin/kubectl"

  run env KUBECTL_CALLS="$calls" NETASSERT_CONFIG="$config" PATH="$fake_bin:$PATH" \
    "$repo_root/d2-signalloom/test/run-netassert.sh" --preflight-only
  [ "$status" -eq 0 ]
  run grep -F 'get pods -n fe-signalloom-agents -l signalloom.ai/agent=true,signalloom.ai/framework=custom,netassert.signalloom.ai/fixture=generic-agent -o json' "$calls"
  [ "$status" -eq 0 ]
  run grep -F 'get deployment/cardvault -n inf-signalloom' "$calls"
  [ "$status" -eq 0 ]
}

@test "suite preflight fails closed on absent SuperCred prerequisites" {
  config="$BATS_TEST_TMPDIR/supercred.yaml"
  fake_bin="$BATS_TEST_TMPDIR/missing-bin"
  mkdir -p "$fake_bin"
  cat >"$config" <<'YAML'
- name: dashboard-to-cardvault
  src:
    k8sResource: {kind: deployment, name: dashboard-signalloom, namespace: fe-signalloom}
  dst:
    k8sResource: {kind: deployment, name: cardvault, namespace: inf-signalloom}
YAML
  cat >"$fake_bin/kubectl" <<'SH'
#!/usr/bin/env bash
[[ "$*" != *"get deployment/cardvault -n inf-signalloom"* ]]
SH
  chmod +x "$fake_bin/kubectl"

  run env NETASSERT_CONFIG="$config" PATH="$fake_bin:$PATH" \
    "$repo_root/d2-signalloom/test/run-netassert.sh" --preflight-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"configured destination resource is absent: deployment/cardvault in inf-signalloom"* ]]

  calls="$BATS_TEST_TMPDIR/sustained.calls"
  cat >"$config" <<'YAML'
- name: cardvault-probe-to-openbao
  src:
    k8sResource: {kind: pod, name: netassert-cardvault-probe-pod, namespace: fe-signalloom-agents}
  dst:
    k8sResource: {kind: deployment, name: openbao, namespace: inf-bao}
YAML
  cat >"$fake_bin/kubectl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_CALLS"
[[ "$*" != *"get pod/netassert-cardvault-probe-pod -n fe-signalloom-agents"* ]]
SH
  chmod +x "$fake_bin/kubectl"

  run env KUBECTL_CALLS="$calls" NETASSERT_CONFIG="$config" PATH="$fake_bin:$PATH" \
    "$repo_root/d2-signalloom/test/run-netassert.sh" --preflight-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"configured source fixture is not uniquely Running and Ready: cardvault-agent in fe-signalloom-agents"* ]]
  run grep -E '(^| )(apply|create|replace|patch)( |$)' "$calls"
  [ "$status" -ne 0 ]
}

@test "TAP validator accepts one complete numbered passing plan" {
  tap="$BATS_TEST_TMPDIR/valid.tap"
  printf 'TAP version 13\nok 1 - first\nok 2 - second\n1..2\n' >"$tap"
  run "$repo_root/d2-signalloom/test/run-netassert.sh" --validate-tap "$tap"
  [ "$status" -eq 0 ]
}

@test "TAP validator rejects incomplete or malformed result sets" {
  cases=(
    '1..2'
    $'ok 1 - first\n1..2'
    $'ok 1 - first\nok 1 - duplicate\n1..2'
    $'ok 1 - first\nok 3 - outside\n1..2'
    $'ok 1 - first\nnot ok 2 - failed\n1..2'
    $'Bail out! scanner crashed\n1..1'
    $'ok 1 - first\nok 2 - second'
  )
  for content in "${cases[@]}"; do
    tap="$BATS_TEST_TMPDIR/invalid-${RANDOM}.tap"
    printf '%s\n' "$content" >"$tap"
    run "$repo_root/d2-signalloom/test/run-netassert.sh" --validate-tap "$tap"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid Netassert TAP"* ]]
  done
}

@test "Netassert Roles expose no secret or workload mutation" {
  run yq e -r '
    select(.kind == "ResourceSet")
    | .spec.resources[]
    | select(.kind == "Role" and (.metadata.name | test("netassert")))
    | .rules[]
    | select((.resources[] == "secrets") or ((.resources[] | test("deployments|daemonsets|statefulsets|replicasets")) and (.verbs[] | test("create|update|patch|delete|deletecollection"))))
  ' "$fleet"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ingress and CoreDNS discovery grants contain only required reads" {
  for namespace in ingress kube-system; do
    run yq ea -r "
      select(.metadata.name == \"signalloom-infra\")
      | .spec.resources[]
      | select(.kind == \"Role\" and .metadata.name == \"netassert-runner\" and .metadata.namespace == \"$namespace\")
      | .rules[]
      | [(.resources | join(\",\")), (.verbs | join(\",\"))] | @tsv
    " "$fleet"
    [ "$status" -eq 0 ]
    [ "$output" = $'pods\tget,list,watch\ndeployments\tget\nreplicasets\tlist\npods/ephemeralcontainers\tpatch' ]
  done
}
