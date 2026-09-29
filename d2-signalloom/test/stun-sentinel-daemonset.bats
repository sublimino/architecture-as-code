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

@test "stun-sentinel Roles grant get on the owner chain and nothing wider" {
  for role in \
    "$repo_root/d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/rbac.yaml" \
    "$repo_root/d2-signalloom/infra/agent-swarm/ebpf-sentinel-rbac.yaml"; do
    run yq -r 'select(.kind == "Role") | .rules[] | select(.apiGroups[] == "apps") | (.resources | sort | join(",")) + ":" + (.verbs | join(","))' "$role"
    [ "$status" -eq 0 ]
    [ "$output" = "deployments,replicasets:get" ]
  done
}
