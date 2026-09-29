#!/usr/bin/env bats
#
# The stun sentinel's container privilege is pinned exactly: no more, no less.
#
#   SYS_ADMIN  - write cgroup.freeze on the host cgroup2 mount
#   NET_ADMIN  - attach/detach the tc matchall drop filters on the host veth
#   SYS_PTRACE - open /proc/<pid>/ns/net of an agent running as another uid.
#                That open is a PTRACE_MODE_READ check; without the cap it
#                fails "permission denied" (network.go findHostVeth), so the
#                sentinel can freeze but never isolate, and never thaw.
#
# privileged: false is the point of the whole list: a new need is a named
# capability reviewed here, never privileged: true.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  ds="$repo_root/d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml"
  sel='.spec.template.spec.containers[] | select(.name == "sentinel") | .securityContext'
}

@test "stun-sentinel adds exactly SYS_ADMIN, NET_ADMIN, SYS_PTRACE" {
  run yq -r "$sel | .capabilities.add | sort | join(\",\")" "$ds"
  [ "$status" -eq 0 ]
  [ "$output" = "NET_ADMIN,SYS_ADMIN,SYS_PTRACE" ]
}

@test "stun-sentinel drops ALL and is not privileged" {
  run yq -r "$sel | .capabilities.drop | join(\",\")" "$ds"
  [ "$status" -eq 0 ]
  [ "$output" = "ALL" ]

  run yq -r "$sel | .privileged" "$ds"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "stun-sentinel Role grants get on the owner chain and nothing wider" {
  role="$repo_root/d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/rbac.yaml"
  run yq -r 'select(.kind == "Role") | .rules[] | select(.apiGroups[] == "apps") | (.resources | sort | join(",")) + ":" + (.verbs | join(","))' "$role"
  [ "$status" -eq 0 ]
  [ "$output" = "deployments,replicasets:get" ]
}

# ── RBAC subjects: one owner per object, every subject a declared SA ─────────
#
# The defect this pins: ebpf-sentinel-rbac.yaml (Flux agent-swarm-base) and
# signalloom-stun-sentinel/rbac.yaml (Flux agent-signalloom-stun-sentinel)
# both declared Role and RoleBinding "stun-sentinel". Last writer won, so the
# binding flapped between SA stun-sentinel (the one the DaemonSet runs as)
# and SA signalloom-stun-sentinel (declared, but used by nothing). Checking
# "subject is a declared SA" alone would have passed that tree.

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

@test "every stun-sentinel binding names the SA the DaemonSet runs as" {
  sa="$(yq -r '.spec.template.spec.serviceAccountName' "$ds")"
  [ "$sa" = "stun-sentinel" ]
  names="$(while read -r f; do yq -r 'select((.kind == "RoleBinding" or .kind == "ClusterRoleBinding") and (.roleRef.name | test("^stun-sentinel"))) | .subjects[] | .name' "$f"; done <<<"$(swarm_yaml)" | rg -v '^---' | sort -u)"
  [ "$names" = "$sa" ]
}
