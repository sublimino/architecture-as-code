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

# BPF arrived with the in-sentinel eBPF loader (SLDC-P1-1): it loads the
# tracepoint programs and the tc drop program.
@test "stun-sentinel adds exactly BPF, SYS_ADMIN, NET_ADMIN, SYS_PTRACE" {
  run yq -r "$sel | .capabilities.add | sort | join(\",\")" "$ds"
  [ "$status" -eq 0 ]
  [ "$output" = "BPF,NET_ADMIN,SYS_ADMIN,SYS_PTRACE" ]
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

# ── SPIRE identity: selectors must name SAs that exist and are used ──────────
#
# spire-agent-swarm-entries.yaml registers one entry per name in its AGENTS
# array, as `-selector k8s:sa:${sa}` in fe-signalloom-agents. It named
# signalloom-stun-sentinel, an SA no pod runs as, so the sentinel pod
# (SA stun-sentinel) never matched its SPIFFE identity.

spire_entries() {
  echo "$repo_root/d2-signalloom/infra/inf-bao/controllers/base/spire-agent-swarm-entries.yaml"
}

# SAs a SPIRE entry selects in fe-signalloom-agents: the AGENTS array (the
# script interpolates it into k8s:sa:) plus any literal k8s:sa: selector that
# sits beside k8s:ns:fe-signalloom-agents anywhere under inf-bao.
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

@test "the sentinel's SPIRE entry selects the SA the DaemonSet runs as" {
  sa="$(yq -r '.spec.template.spec.serviceAccountName' "$ds")"
  run bash -c "$(declare -f spire_entries spire_agent_sas); repo_root='$repo_root'; spire_agent_sas | rg -x -- '$sa'"
  [ "$status" -eq 0 ]
}

@test "no ServiceAccount named signalloom-stun-sentinel is declared (orphan)" {
  run bash -c "$(declare -f swarm_yaml declared_swarm_sas); repo_root='$repo_root'; declared_swarm_sas | rg -x signalloom-stun-sentinel"
  [ "$status" -eq 1 ]
}

# The sentinel skips its own pods by SA and by app.kubernetes.io/name
# (main.go isSentinelPod). Those constants must track this DaemonSet.
@test "sentinel self-exclusion constants match the DaemonSet" {
  main="$repo_root/d2-signalloom/apps/signalloom-stun-sentinel/main.go"
  sa="$(yq -r '.spec.template.spec.serviceAccountName' "$ds")"
  app="$(yq -r '.spec.template.metadata.labels."app.kubernetes.io/name"' "$ds")"
  run rg -q "sentinelServiceAccount = \"${sa}\"" "$main"
  [ "$status" -eq 0 ]
  run rg -q "sentinelAppName +?= \"${app}\"" "$main"
  [ "$status" -eq 0 ]
}
