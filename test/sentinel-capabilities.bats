#!/usr/bin/env bats
# test/sentinel-capabilities.bats
#
# SLDC-P1-3: the stun-sentinel capability, host-namespace, mount and ingest
# contract, asserted on the manifest AS kubectl RENDERS IT (kustomize) and,
# when a cluster is reachable, as the API server ADMITS it (server-side dry
# run — nothing is persisted).
#
# There is now exactly ONE sentinel manifest,
# d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel, and this suite
# renders it three ways: the canonical base, the legacy
# apps/stun-sentinel/base entrypoint (which must be a pure passthrough), and
# each per-cluster overlay. The raw manifest is held to the least-privilege
# contract by apps/stun-sentinel/deploy/least_privilege_test.go.
#
# Static tests never skip. Only the server-dry-run test needs a cluster, and it
# says so by name when it skips.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  BASE_DIR="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel"
  LEGACY_DIR="${REPO_ROOT}/d2-signalloom/apps/stun-sentinel/base"
  OVERLAY_OSRAMP="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel-overlays/kind-osramp"
  OVERLAY_HUB="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel-overlays/kind-signalloom-hub"
  command -v kubectl >/dev/null || { echo "kubectl is required" >&2; return 1; }
  command -v yq >/dev/null || { echo "yq is required" >&2; return 1; }
}

render() {
  kubectl kustomize "${1:-$BASE_DIR}"
}

ds_query() {
  render | yq -r "select(.kind == \"DaemonSet\") | $1"
}

container_query() {
  ds_query ".spec.template.spec.containers[] | select(.name == \"sentinel\") | $1"
}

# mountPath=hostPath:readOnly, one per line, sorted — for the directory given.
mount_triples() {
  kubectl kustomize "${1:-$BASE_DIR}" | yq -r '
    select(.kind == "DaemonSet") | .spec.template.spec as $s
    | $s.containers[0].volumeMounts[]
    | . as $m
    | ($s.volumes[] | select(.name == $m.name) | .hostPath.path) as $hp
    | $m.mountPath + "=" + $hp + ":" + (($m.readOnly // false) | tostring)' | sort
}

@test "sentinel-capabilities: kustomize renders exactly one DaemonSet named stun-sentinel" {
  run ds_query '.metadata.name'
  [ "$status" -eq 0 ]
  [ "$output" = "stun-sentinel" ]
}

@test "sentinel-capabilities: capabilities.add is exactly SYS_PTRACE BPF NET_ADMIN SYS_ADMIN" {
  run container_query '.securityContext.capabilities.add | sort | join(",")'
  [ "$status" -eq 0 ]
  [ "$output" = "BPF,NET_ADMIN,SYS_ADMIN,SYS_PTRACE" ]
}

@test "sentinel-capabilities: capabilities.drop is ALL" {
  run container_query '.securityContext.capabilities.drop | join(",")'
  [ "$output" = "ALL" ]
}

# The hardened profile measured on kind-osramp 2026-10-01: the four
# capabilities above are sufficient, so privileged buys nothing and is refused.
@test "sentinel-capabilities: the sentinel is NOT privileged and its root filesystem is read-only" {
  run container_query '.securityContext.privileged'
  [ "$output" = "false" ]
  run container_query '.securityContext.readOnlyRootFilesystem'
  [ "$output" = "true" ]
}

@test "sentinel-capabilities: hostPID and hostNetwork are true with ClusterFirstWithHostNet DNS" {
  run ds_query '.spec.template.spec.hostPID'
  [ "$output" = "true" ]
  run ds_query '.spec.template.spec.hostNetwork'
  [ "$output" = "true" ]
  # Without this, Kubernetes downgrades ClusterFirst to Default for a
  # hostNetwork pod and the ingest Service name does not resolve at all.
  run ds_query '.spec.template.spec.dnsPolicy'
  [ "$output" = "ClusterFirstWithHostNet" ]
}

@test "sentinel-capabilities: debugfs is mounted read-only, cgroup read-write, and nothing else" {
  run mount_triples
  [ "$status" -eq 0 ]
  [ "$output" = "/host-cgroup=/sys/fs/cgroup:false
/sys/kernel/debug=/sys/kernel/debug:true" ]
}

# debugfs is the one mount that decides whether the probe loads: link.Tracepoint
# reads /sys/kernel/debug/tracing/events/<grp>/<name>/id. bpffs and the BTF
# mount are NOT needed — nothing is pinned and the probe is bpf2go-embedded —
# so they are named here to stop a speculative re-add passing unnoticed.
@test "sentinel-capabilities: bpffs, host BTF and /lib/modules are not mounted" {
  run mount_triples
  [[ "$output" != *"/sys/fs/bpf"* ]]
  [[ "$output" != *"/sys/kernel/btf"* ]]
  [[ "$output" != *"/lib/modules"* ]]
}

# main.go:351 reads SIGNAL_INGEST_URL; an empty value falls back to
# http://signal-ingest:8082, which cannot resolve from fe-signalloom-agents.
@test "sentinel-capabilities: SIGNAL_INGEST_URL comes from a non-optional ConfigMap key" {
  run container_query '.env[] | select(.name == "SIGNAL_INGEST_URL") | .valueFrom.configMapKeyRef | .name + "/" + .key + ":optional=" + ((.optional // false) | tostring)'
  [ "$status" -eq 0 ]
  [ "$output" = "stun-sentinel-config/SIGNAL_INGEST_URL:optional=false" ]
}

@test "sentinel-capabilities: the base ingest URL is a fully-qualified Service name, not a ClusterIP" {
  run bash -c "kubectl kustomize '$BASE_DIR' | yq -r 'select(.kind == \"ConfigMap\" and .metadata.name == \"stun-sentinel-config\") | .data.SIGNAL_INGEST_URL'"
  [ "$status" -eq 0 ]
  [ "$output" = "http://signal-ingest.fe-signalloom.svc.cluster.local:8082" ]
}

# A remote cluster must be able to pull; imagePullPolicy: Never made that
# impossible, and :latest makes a rollout depend on when a node last pulled.
@test "sentinel-capabilities: the base image is registry-qualified, tagged and pullable" {
  run container_query '.image'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/"* ]]
  [[ "$output" != *":latest" ]]
  [[ "$output" == *":"* ]]
  run container_query '.imagePullPolicy'
  [ "$output" != "Never" ]
}

# The legacy entrypoint is a tombstone that forwards to the canonical base.
# If it ever renders something different, it is a second source of truth again.
@test "sentinel-capabilities: apps/stun-sentinel/base renders the canonical base verbatim" {
  run bash -c "diff <(kubectl kustomize '$BASE_DIR') <(kubectl kustomize '$LEGACY_DIR')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sentinel-capabilities: each per-cluster overlay renders and retags the image locally" {
  for overlay in "$OVERLAY_OSRAMP" "$OVERLAY_HUB"; do
    run bash -c "kubectl kustomize '$overlay' | yq -r 'select(.kind == \"DaemonSet\") | .spec.template.spec.containers[0].image'"
    [ "$status" -eq 0 ]
    # kind side-loads the image, so the overlay must drop the registry prefix.
    [[ "$output" == stun-sentinel:* ]]
    [[ "$output" != *":latest" ]]
  done
}

@test "sentinel-capabilities: each per-cluster overlay carries its own resolvable ingest URL" {
  for overlay in "$OVERLAY_OSRAMP" "$OVERLAY_HUB"; do
    run bash -c "kubectl kustomize '$overlay' | yq -r 'select(.kind == \"ConfigMap\" and .metadata.name == \"stun-sentinel-config\") | .data.SIGNAL_INGEST_URL'"
    [ "$status" -eq 0 ]
    # A FQDN, never a ClusterIP: ClusterIPs are reassigned on cluster rebuild.
    [[ "$output" == http://*.svc.cluster.local:8082 || "$output" == http://*.signalloom.hub:8082 ]]
  done
}

@test "sentinel-capabilities: each overlay keeps the hardened securityContext" {
  for overlay in "$OVERLAY_OSRAMP" "$OVERLAY_HUB"; do
    run bash -c "kubectl kustomize '$overlay' | yq -r 'select(.kind == \"DaemonSet\") | .spec.template.spec.containers[0].securityContext | (.privileged | tostring) + \",\" + (.readOnlyRootFilesystem | tostring) + \",\" + (.capabilities.add | sort | join(\"|\"))'"
    [ "$status" -eq 0 ]
    [ "$output" = "false,true,BPF|NET_ADMIN|SYS_ADMIN|SYS_PTRACE" ]
  done
}

@test "sentinel-capabilities: API server admits the DaemonSet (server-side dry run)" {
  kubectl get --raw /readyz >/dev/null 2>&1 || skip "no reachable cluster for server-side dry run"
  run kubectl apply --dry-run=server -k "$BASE_DIR"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"daemonset.apps/stun-sentinel"*"(server dry run)"* ]]
  [[ "$output" != *"violates PodSecurity"* ]]
}

# The sentinel's RBAC was owned TWICE. agent-swarm/ebpf-sentinel-rbac.yaml (in
# the agent-swarm-base Kustomization) and signalloom-stun-sentinel/rbac.yaml
# (in agent-signalloom-stun-sentinel) both declared RoleBinding
# fe-signalloom-agents/stun-sentinel, with DIFFERENT subjects: the first bound
# the pre-rename SA signalloom-stun-sentinel. Two Flux Kustomizations then
# fought over one object and whichever reconciled last won, so the running
# sentinel's `auth can-i list pods` flipped between yes and no (live,
# 2026-10-01) and its pod index stayed empty. These two tests pin both halves.
@test "sentinel-capabilities: no namespaced object is declared by both agent-swarm-base and the sentinel Kustomization" {
  local root="${REPO_ROOT}/d2-signalloom/infra/agent-swarm"
  run bash -c "comm -12 \
    <(kubectl kustomize '${root}' | yq -N '[.kind, .metadata.namespace // \"-\", .metadata.name] | join(\"/\")' | sort -u) \
    <(kubectl kustomize '${BASE_DIR}' | yq -N '[.kind, .metadata.namespace // \"-\", .metadata.name] | join(\"/\")' | sort -u)"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "owned by two Kustomizations: $output"; return 1; }
}

@test "sentinel-capabilities: the binding to the sentinel's Role binds the SA the DaemonSet runs as" {
  local root="${REPO_ROOT}/d2-signalloom/infra/agent-swarm"
  local sa
  sa="$(kubectl kustomize "${BASE_DIR}" | yq -N 'select(.kind == "DaemonSet") | .spec.template.spec.serviceAccountName')"
  [ "$sa" = "stun-sentinel" ]
  run bash -c "{ kubectl kustomize '${root}'; echo '---'; kubectl kustomize '${BASE_DIR}'; } \
    | yq -N 'select(.kind == \"RoleBinding\" or .kind == \"ClusterRoleBinding\") | select(.roleRef.kind == \"Role\" and .roleRef.name == \"stun-sentinel\") | .subjects[].name' | sort -u"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" = "$sa" ] || { echo "sentinel bindings name: $output (DaemonSet runs as $sa)"; return 1; }
}
