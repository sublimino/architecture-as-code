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

@test "rendered fixture resources own Cardvault service account in agents namespace" {
  rendered="$BATS_TEST_TMPDIR/fleet.yaml"
  kubectl kustomize --load-restrictor LoadRestrictionsNone \
    "$repo_root/d2-osramp-fleet/tenants/local" >"$rendered"

  run yq ea -e '
    select(.kind == "ResourceSet" and .metadata.name == "signalloom-netassert-fixtures")
    | ((([.spec.resources[] | select(.kind == "ServiceAccount" and .metadata.name == "cardvault-agent" and .metadata.namespace == "fe-signalloom-agents" and .automountServiceAccountToken == false)] | length) == 1) and
      (([.spec.resources[] | select(.kind == "Secret")] | length) == 0) and
      (([.spec.resources[] | select(.kind == "Role" or .kind == "RoleBinding" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding") | select(.subjects[]?.name == "cardvault-agent")] | length) == 0) and
      (([.spec.resources[] | select(.kind == "Deployment" and .metadata.name == "netassert-cardvault-agent-fixture" and .metadata.namespace == "fe-signalloom-agents" and .spec.template.spec.serviceAccountName == "cardvault-agent")] | length) == 1))
  ' "$rendered"
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

@test "suite preflight resolves Envoy placeholder through canonical selector" {
  config="$BATS_TEST_TMPDIR/envoy.yaml"
  calls="$BATS_TEST_TMPDIR/envoy.calls"
  fake_bin="$BATS_TEST_TMPDIR/envoy-bin"
  mkdir -p "$fake_bin"
  cat >"$config" <<'YAML'
- name: envoy-to-dashboard
  src:
    k8sResource: {kind: pod, name: envoy-gateway-pod, namespace: ingress}
  dst:
    k8sResource: {kind: deployment, name: dashboard-signalloom, namespace: fe-signalloom}
YAML
  cat >"$fake_bin/kubectl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_CALLS"
if [[ "$*" == *"get pods"*"gateway.envoyproxy.io/owning-gateway-name=cluster"* ]]; then
  printf '{"items":[{"metadata":{"name":"envoy-fixture"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}\n'
fi
exit 0
SH
  chmod +x "$fake_bin/kubectl"

  run env KUBECTL_CALLS="$calls" NETASSERT_CONFIG="$config" PATH="$fake_bin:$PATH" \
    "$repo_root/d2-signalloom/test/run-netassert.sh" --preflight-only
  [ "$status" -eq 0 ]
  run grep -F 'get pods -n ingress -l gateway.envoyproxy.io/owning-gateway-name=cluster -o json' "$calls"
  [ "$status" -eq 0 ]
  run grep -F 'get pod/envoy-gateway-pod -n ingress' "$calls"
  [ "$status" -ne 0 ]
}

@test "suite preflight rejects ambiguous and unready placeholder candidates" {
  config="$BATS_TEST_TMPDIR/candidates.yaml"
  fake_bin="$BATS_TEST_TMPDIR/candidates-bin"
  mkdir -p "$fake_bin"
  cat >"$config" <<'YAML'
- name: agent-to-api
  src:
    k8sResource: {kind: pod, name: agent-patsy, namespace: fe-signalloom-agents}
  dst:
    k8sResource: {kind: deployment, name: fe-signalloom, namespace: fe-signalloom}
YAML
  cat >"$fake_bin/kubectl" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"get pods"* ]]; then cat "$POD_RESPONSE"; fi
exit 0
SH
  chmod +x "$fake_bin/kubectl"

  for state in ambiguous unready; do
    response="$BATS_TEST_TMPDIR/$state.json"
    if [ "$state" = ambiguous ]; then
      printf '%s\n' '{"items":[{"metadata":{"name":"one"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"two"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}' >"$response"
    else
      printf '%s\n' '{"items":[{"metadata":{"name":"one"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"False"}]}}]}' >"$response"
    fi
    run env POD_RESPONSE="$response" NETASSERT_CONFIG="$config" PATH="$fake_bin:$PATH" \
      "$repo_root/d2-signalloom/test/run-netassert.sh" --preflight-only
    [ "$status" -ne 0 ]
    [[ "$output" == *"not uniquely Running and Ready"* ]]
  done
}

@test "host collector marker matches controller emitter exactly" {
  runner="$repo_root/d2-signalloom/test/run-netassert.sh"
  controller="$repo_root/d2-signalloom/apps/netassert-controller/server.py"
  run bash -c '
    shell_marker=$(grep "^NETASSERT_TAP_MARKER=" "$1" | cut -d= -f2- | tr -d "\"")
    python_marker=$(grep "^NETASSERT_TAP_MARKER =" "$2" | cut -d= -f2- | tr -d " \"")
    test "$shell_marker" = "$python_marker"
  ' _ "$runner" "$controller"
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

@test "suite preflight requires the existing SuperCred egress policy read-only" {
  config="$BATS_TEST_TMPDIR/supercred-policy.yaml"
  calls="$BATS_TEST_TMPDIR/policy.calls"
  fake_bin="$BATS_TEST_TMPDIR/policy-bin"
  mkdir -p "$fake_bin"
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
if [[ "$*" == *"get pods"* ]]; then
  printf '{"items":[{"metadata":{"name":"cardvault-agent"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}\n'
fi
[[ "$*" != *"get networkpolicy/allow-supercred-cardvault-egress -n fe-signalloom-agents"* ]]
SH
  chmod +x "$fake_bin/kubectl"

  run env KUBECTL_CALLS="$calls" NETASSERT_CONFIG="$config" PATH="$fake_bin:$PATH" \
    "$repo_root/d2-signalloom/test/run-netassert.sh" --preflight-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"networkpolicy/allow-supercred-cardvault-egress is absent in fe-signalloom-agents"* ]]
  [[ "$output" == *"make demo-signalloom-supercred-1"* ]]
  run grep -E '(^| )(apply|create|replace|patch)( |$)' "$calls"
  [ "$status" -ne 0 ]
}

@test "TAP validator accepts one complete numbered passing plan" {
  tap="$BATS_TEST_TMPDIR/valid.tap"
  printf 'TAP version 13\nok 1 - first\nok 2 - second\n1..2\n' >"$tap"
  run "$repo_root/d2-signalloom/test/run-netassert.sh" --validate-tap "$tap"
  [ "$status" -eq 0 ]
}

@test "TAP validator accepts a complete twenty-six-result plan" {
  tap="$BATS_TEST_TMPDIR/valid-26.tap"
  {
    printf 'TAP version 13\n'
    for number in $(seq 1 26); do printf 'ok %s - check %s\n' "$number" "$number"; done
    printf '1..26\n'
  } >"$tap"
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

@test "failed Netassert Job emits logs promptly and remains a failure" {
  config="$BATS_TEST_TMPDIR/failed-job.yaml"
  fake_bin="$BATS_TEST_TMPDIR/failed-job-bin"
  mkdir -p "$fake_bin"
  cat >"$config" <<'YAML'
- name: dashboard-to-api
  src:
    k8sResource: {kind: deployment, name: dashboard-signalloom, namespace: fe-signalloom}
  dst:
    k8sResource: {kind: deployment, name: fe-signalloom, namespace: fe-signalloom}
YAML
  cat >"$fake_bin/kubectl" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"port-forward"* ]]; then
  while :; do sleep 1; done
elif [[ "$*" == *"get job/netassert-run"*"jsonpath={.spec.activeDeadlineSeconds}"* ]]; then
  printf '%s' "$JOB_DEADLINE"
elif [[ "$*" == *"get job/netassert-run"*"-o json"* ]]; then
  count=0
  [[ ! -f "$JOB_POLL_COUNT" ]] || read -r count <"$JOB_POLL_COUNT"
  count=$((count + 1))
  printf '%s\n' "$count" >"$JOB_POLL_COUNT"
  if (( count <= COMPLETE_AFTER_POLLS )); then
    printf '%s\n' '{"status":{"active":1}}'
  else
    printf '{"status":{"conditions":[{"type":"%s","status":"True"}]}}\n' "$JOB_CONDITION"
  fi
elif [[ "$*" == *"logs"*"job/netassert-run"* ]]; then
  printf '%s\n' 'runner failed before completing assertions'
  printf '%s\n' '----NETASSERT-TAP-RESULTS----'
  printf '%s\n' 'TAP version 14' '1..1' "$JOB_LOG_OUTCOME 1 - dashboard-to-api"
fi
exit 0
SH
  cat >"$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake_bin/kubectl" "$fake_bin/curl"

  poll_count="$BATS_TEST_TMPDIR/failed.polls"
  run env NETASSERT_CONFIG="$config" WAIT_SLEEP=0 WAIT_BACKOFF=1 WAIT_JITTER=0 \
    JOB_DEADLINE=300 JOB_POLL_COUNT="$poll_count" COMPLETE_AFTER_POLLS=0 \
    JOB_CONDITION=Failed JOB_LOG_OUTCOME='not ok' \
    PATH="$fake_bin:$PATH" "$repo_root/d2-signalloom/test/run-netassert.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not ok 1 - dashboard-to-api"* ]]
  [[ "$output" == *"job/netassert-run reached Failed condition; TAP evidence collected above"* ]]
  [[ "$output" != *"did not reach a terminal"* ]]

  rm -f "$poll_count"
  run env NETASSERT_CONFIG="$config" WAIT_SLEEP=0 WAIT_BACKOFF=1 WAIT_JITTER=0 \
    JOB_DEADLINE=300 JOB_POLL_COUNT="$poll_count" COMPLETE_AFTER_POLLS=121 \
    JOB_CONDITION=Complete JOB_LOG_OUTCOME=ok \
    PATH="$fake_bin:$PATH" "$repo_root/d2-signalloom/test/run-netassert.sh"
  [ "$status" -eq 0 ]
  [ "$(<"$poll_count")" -gt 120 ]
}

@test "Job deadline derives bounded grace and rejects invalid contracts" {
  source "$repo_root/d2-signalloom/test/run-netassert.sh"
  run derive_job_wait_budget 300
  [ "$status" -eq 0 ]
  [ "$output" = 330 ]
  for deadline in '' 0 invalid 571; do
    run derive_job_wait_budget "$deadline"
    [ "$status" -ne 0 ]
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
