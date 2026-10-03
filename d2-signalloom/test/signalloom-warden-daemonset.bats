#!/usr/bin/env bats
#
# Declarative assertions over the signalloom-warden DaemonSet and its RBAC.
#
#   KUBECONFIG=/dev/null bats d2-signalloom/test/signalloom-warden-daemonset.bats
#
# @target d2-signalloom/infra/agent-swarm/signalloom-warden/daemonset.yaml

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  ds="$repo_root/d2-signalloom/infra/agent-swarm/signalloom-warden/daemonset.yaml"
  sel='.spec.template.spec.containers[] | select(.name == "sentinel") | .securityContext'
}

# BPF arrived with the in-sentinel eBPF loader (SLDC-P1-1): it loads the
# tracepoint programs and the tc drop program.
@test "signalloom-warden adds exactly BPF, SYS_ADMIN, NET_ADMIN, SYS_PTRACE" {
  run yq -r "$sel | .capabilities.add | sort | join(\",\")" "$ds"
  [ "$status" -eq 0 ]
  [ "$output" = "BPF,NET_ADMIN,SYS_ADMIN,SYS_PTRACE" ]
}

@test "signalloom-warden drops ALL and is not privileged" {
  run yq -r "$sel | .capabilities.drop | join(\",\")" "$ds"
  [ "$status" -eq 0 ]
  [ "$output" = "ALL" ]

  run yq -r "$sel | .privileged" "$ds"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "signalloom-warden Role grants get on the owner chain and nothing wider" {
  role="$repo_root/d2-signalloom/infra/agent-swarm/ebpf-sentinel-rbac.yaml"
  run yq -r 'select(.kind == "Role") | .rules[] | select(.apiGroups[] == "apps") | (.resources | sort | join(",")) + ":" + (.verbs | join(","))' "$role"
  [ "$status" -eq 0 ]
  [ "$output" = "deployments,replicasets:get" ]
}

# ── RBAC subjects: one owner per object, every subject a declared SA ─────────

swarm_yaml() {
  fd -e yaml -e yml . "$repo_root/d2-signalloom/infra/agent-swarm" | rg -v '/kustomization\.ya?ml$'
}

@test "no RBAC object is declared by more than one agent-swarm manifest" {
  run bash -c '
    while read -r f; do
      yq -r "select(.kind == \"Role\" or .kind == \"RoleBinding\" or .kind == \"ClusterRole\" or .kind == \"ClusterRoleBinding\") | .kind + \" \" + (.metadata.namespace // \"-\") + \" \" + .metadata.name" "$f" | rg -v "^---"
    done | sort | uniq -d' <<<"$(swarm_yaml)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "every agent-swarm RoleBinding/ClusterRoleBinding SA subject is declared in agent-swarm" {
  declared="$(while read -r f; do yq -r 'select(.kind == "ServiceAccount") | .metadata.name' "$f"; done <<<"$(swarm_yaml)" | rg -v '^---' | sort -u)"
  subjects="$(while read -r f; do yq -r 'select(.kind == "RoleBinding" or .kind == "ClusterRoleBinding") | .subjects[]? | select(.kind == "ServiceAccount") | .name' "$f"; done <<<"$(swarm_yaml)" | rg -v '^---' | sort -u)"
  [ -n "$subjects" ]
  run comm -23 <(printf '%s\n' "$subjects") <(printf '%s\n' "$declared")
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "every signalloom-warden binding, cluster-scoped included, names the SA the DaemonSet runs as" {
  sa="$(yq -r '.spec.template.spec.serviceAccountName' "$ds")"
  ns="$(yq -r '.metadata.namespace' "$ds")"
  [ "$sa" = "signalloom-warden" ]
  [ "$ns" = "fe-signalloom-agents" ]
  subjects="$(while read -r f; do yq -r '
    select(.kind == "RoleBinding" or .kind == "ClusterRoleBinding")
    | select(
        (.metadata.labels."app.kubernetes.io/name" // "") == "signalloom-warden"
        or ((.roleRef.name // "") | test("signalloom-warden"))
        or ([.subjects[]? | .name | test("signalloom-warden")] | any))
    | .subjects[] | .kind + ":" + (.namespace // "-") + "/" + .name' "$f"; done <<<"$(swarm_yaml)" | rg -v '^---' | sort -u)"
  [ "$subjects" = "ServiceAccount:${ns}/${sa}" ] || { echo "sentinel binding subjects: $subjects"; return 1; }
}

# ── SPIRE identity: selectors must name SAs that exist and are used ──────────

spire_entries() {
  echo "$repo_root/d2-signalloom/infra/inf-bao/controllers/base/spire-agent-swarm-entries.yaml"
}

spire_agent_sas() {
  yq -r '.data."register-entries.sh" // ""' "$(spire_entries)" |
    awk '/^[[:space:]]*AGENTS=\(/{on=1; next} on && /^[[:space:]]*\)/{exit} on && /^[[:space:]]*#/{next} on && NF {print $1}'
  rg --no-filename -o 'k8s:ns:fe-signalloom-agents[^\n]*' "$repo_root/d2-signalloom/infra/inf-bao" |
    rg -o 'k8s:sa:[a-z0-9-]+' | sed 's/^k8s:sa://'
}

declared_swarm_sas() {
  while read -r f; do yq -r 'select(.kind == "ServiceAccount") | .metadata.name' "$f"; done <<<"$(swarm_yaml)" | rg -v '^---' | sort -u
}

@test "every SPIRE k8s:sa: selector in fe-signalloom-agents names a declared SA" {
  sas="$(spire_agent_sas | sort -u)"
  [ "$(printf '%s\n' "$sas" | wc -l)" -ge 10 ]  # the parser found the array
  run comm -23 <(printf '%s\n' "$sas") <(declared_swarm_sas)
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the sentinel SPIRE entry selects the SA the DaemonSet runs as" {
  sa="$(yq -r '.spec.template.spec.serviceAccountName' "$ds")"
  run bash -c "$(declare -f spire_entries spire_agent_sas); repo_root='$repo_root'; spire_agent_sas | rg -x -- '$sa'"
  [ "$status" -eq 0 ]
}

@test "no orphan legacy ServiceAccount is declared" {
  run bash -c "$(declare -f swarm_yaml declared_swarm_sas); repo_root='$repo_root'; declared_swarm_sas | rg -x "signalloom-.*sentinel""
  [ "$status" -eq 1 ]
}

# The sentinel skips its own pods by SA and by app.kubernetes.io/name
@test "sentinel self-exclusion constants match the DaemonSet" {
  main="$(ls "$repo_root"/d2-signalloom/apps/signalloom-*/main.go 2>/dev/null | grep -E "(warden|sentinel)" | head -n 1)"
  sa="$(yq -r '.spec.template.spec.serviceAccountName' "$ds")"
  app="$(yq -r '.spec.template.metadata.labels."app.kubernetes.io/name"' "$ds")"
  run rg -q "(sentinel|warden)ServiceAccount\s*=\s*\"${sa}\"" "$main"
  [ "$status" -eq 0 ]
  run rg -q "(sentinel|warden)AppName\s*=\s*\"${app}\"" "$main"
  [ "$status" -eq 0 ]
}

@test "every rendered sentinel knows its own pod from the downward API" {
  local overlay rendered
  for overlay in "$repo_root"/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/*/; do
    rendered="$(KUBECONFIG=/dev/null kubectl kustomize "$overlay")"
    [ -n "$rendered" ]
    run yq -r 'select(.kind == "DaemonSet") | .spec.template.spec.containers[] | select(.name == "sentinel")
               | .env[] | select(.name == "POD_UID" or .name == "POD_NAME" or .name == "POD_NAMESPACE")
               | .name + "=" + (.valueFrom.fieldRef.fieldPath // "LITERAL")' <<<"$rendered"
    [ "$status" -eq 0 ]
    [ "$(sort <<<"$output" | tr '\n' ' ')" = "POD_NAME=metadata.name POD_NAMESPACE=metadata.namespace POD_UID=metadata.uid " ] || {
      echo "overlay ${overlay}: ${output}"
      return 1
    }
  done
}
