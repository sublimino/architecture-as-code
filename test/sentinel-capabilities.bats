#!/usr/bin/env bats
# test/sentinel-capabilities.bats
#
# SLDC-P1-3: stun-sentinel DaemonSet capability, host-namespace and mount
# contract, asserted on the manifest AS kubectl RENDERS IT (kustomize) and, when
# a cluster is reachable, as the API server ADMITS it (server-side dry run —
# nothing is persisted). Plus the Go suites that enforce netlink veth
# resolution and self-pod / infrastructure-namespace exclusion.
#
# Static tests never skip. Only the server-dry-run test needs a cluster, and it
# says so by name when it skips.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  APP_DIR="${REPO_ROOT}/d2-signalloom/apps/stun-sentinel"
  BASE_DIR="${APP_DIR}/base"
  export GOCACHE="${GOCACHE:-/tmp/gocache}"
  export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
  export CGO_ENABLED="${CGO_ENABLED:-0}"
  command -v kubectl >/dev/null || { echo "kubectl is required" >&2; return 1; }
  command -v yq >/dev/null || { echo "yq is required" >&2; return 1; }
}

render() {
  kubectl kustomize "$BASE_DIR"
}

ds_query() {
  render | yq -r "select(.kind == \"DaemonSet\") | $1"
}

container_query() {
  ds_query ".spec.template.spec.containers[] | select(.name == \"stun-sentinel\") | $1"
}

@test "sentinel-capabilities: kustomize renders exactly one DaemonSet named stun-sentinel" {
  run ds_query '.metadata.name'
  [ "$status" -eq 0 ]
  [ "$output" = "stun-sentinel" ]
}

@test "sentinel-capabilities: card audit command counts all 4 capabilities" {
  run bash -c "kubectl kustomize '$BASE_DIR' | grep -A 8 capabilities | grep -E '(SYS_PTRACE|SYS_ADMIN|BPF|NET_ADMIN)' | sort -u | wc -l"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | tr -d ' ')" = "4" ]
}

@test "sentinel-capabilities: capabilities.add is exactly SYS_PTRACE BPF NET_ADMIN SYS_ADMIN" {
  run container_query '.securityContext.capabilities.add | sort | join(",")'
  [ "$status" -eq 0 ]
  [ "$output" = "BPF,NET_ADMIN,SYS_ADMIN,SYS_PTRACE" ]
}

@test "sentinel-capabilities: privileged, hostPID and hostNetwork are all true" {
  run container_query '.securityContext.privileged'
  [ "$output" = "true" ]
  run ds_query '.spec.template.spec.hostPID'
  [ "$output" = "true" ]
  run ds_query '.spec.template.spec.hostNetwork'
  [ "$output" = "true" ]
  run ds_query '.spec.template.spec.dnsPolicy'
  [ "$output" = "ClusterFirstWithHostNet" ]
}

@test "sentinel-capabilities: host mounts carry the required paths and access modes" {
  # mountPath=hostPath:readOnly for each required mount.
  run bash -c "kubectl kustomize '$BASE_DIR' | yq -r '
    select(.kind == \"DaemonSet\") | .spec.template.spec as \$s
    | \$s.containers[0].volumeMounts[]
    | . as \$m
    | (\$s.volumes[] | select(.name == \$m.name) | .hostPath.path) as \$hp
    | \$m.mountPath + \"=\" + \$hp + \":\" + ((\$m.readOnly // false) | tostring)' | sort"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/sys/fs/cgroup=/sys/fs/cgroup:false"* ]]
  [[ "$output" == *"/lib/modules=/lib/modules:true"* ]]
  [[ "$output" == *"/sys/kernel/btf=/sys/kernel/btf:true"* ]]
  [[ "$output" == *"/host/proc=/proc:true"* ]]
}

@test "sentinel-capabilities: downward API identity feeds self-pod exclusion" {
  run container_query '.env[] | select(.valueFrom.fieldRef) | .name + "=" + .valueFrom.fieldRef.fieldPath'
  [ "$status" -eq 0 ]
  [[ "$output" == *"POD_NAME=metadata.name"* ]]
  [[ "$output" == *"POD_NAMESPACE=metadata.namespace"* ]]
  [[ "$output" == *"POD_UID=metadata.uid"* ]]
  [[ "$output" == *"POD_IP=status.podIP"* ]]
}

@test "sentinel-capabilities: HTTP listener binds the pod IP, not 0.0.0.0" {
  run container_query '.args[] | select(test("^--listen-addr="))'
  [ "$output" = '--listen-addr=$(POD_IP):8080' ]
}

@test "sentinel-capabilities: every sentinel manifest declares SYS_PTRACE (PF-6 name stun-sentinel)" {
  local m
  for m in \
    "${APP_DIR}/deploy/daemonset.yaml" \
    "${REPO_ROOT}/d2-signalloom/deploy/stun-sentinel-daemonset.yaml" \
    "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml"; do
    run yq -r 'select(.kind == "DaemonSet") | .metadata.name + ":" + (.spec.template.spec.containers[0].securityContext.capabilities.add | join(","))' "$m"
    [ "$status" -eq 0 ]
    [[ "$output" == stun-sentinel:* ]] || { echo "bad name in $m: $output"; return 1; }
    [[ "$output" == *SYS_PTRACE* ]] || { echo "SYS_PTRACE missing in $m"; return 1; }
    [[ "$output" == *NET_ADMIN* ]] || { echo "NET_ADMIN missing in $m"; return 1; }
  done
}

@test "sentinel-capabilities: Go contract suites pass (manifest, netlink veth, exclusion)" {
  run bash -c "cd '$APP_DIR' && go test -count=1 -run 'TestSecurityContextCapabilities|TestHardenedDaemonSetContract|TestDeployMatchesBase|TestNetlinkVethResolution|TestSelfPodExclusion|TestInfrastructureNamespaceExclusion|TestPhaseGate' ./deploy ./pkg/netlink ./pkg/filter ./cmd/stun-sentinel"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]]
}

@test "sentinel-capabilities: API server admits the DaemonSet (server-side dry run)" {
  kubectl get --raw /readyz >/dev/null 2>&1 || skip "no reachable cluster for server-side dry run"
  run kubectl apply --dry-run=server -k "$BASE_DIR"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"daemonset.apps/stun-sentinel"*"(server dry run)"* ]]
  [[ "$output" != *"violates PodSecurity"* ]]
}
