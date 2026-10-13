#!/usr/bin/env bats
#
# @id      agent-swarm-flux-rbac
# @target  d2-osramp-fleet/tenants/base/agent-swarm.yaml
#
# The agent-swarm ResourceSet runs every agent-swarm Kustomization as the Flux
# identity fe-signalloom-agents/agent-swarm-flux. Creating a ClusterRole or a
# ClusterRoleBinding is privilege-escalation-capable: whoever holds it can bind
# itself cluster-admin's rules. That grant must exist exactly when something
# agent-swarm-flux applies needs it, and in neither direction otherwise.
#
# Both sides are derived, not listed here: the Kustomization paths come from
# the ResourceSet, each is rendered with kustomize from
# d2-signalloom/infra/agent-swarm (the OCI artifact root), and the grant is read
# from the ResourceSet's own RBAC objects.
#
# Offline: kubectl kustomize and yq.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  RS="${REPO_ROOT}/d2-osramp-fleet/tenants/base/agent-swarm.yaml"
  ROOT="${REPO_ROOT}/d2-signalloom/infra/agent-swarm"
  PATHS="$(yq -r '.spec.resources[]? | select(.kind == "Kustomization" and .spec.serviceAccountName == "agent-swarm-flux") | .spec.path' "${RS}")"
}

# rendered_cluster_rbac — Kind/name of every ClusterRole or ClusterRoleBinding
# any agent-swarm-flux Kustomization would apply.
rendered_cluster_rbac() {
  local p
  while read -r p; do
    [ -n "$p" ] || continue
    kubectl kustomize "${ROOT}/${p}" | yq -r 'select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding") | .kind + "/" + .metadata.name'
  done <<<"${PATHS}" | grep -v '^---$' | sort -u
}

# flux_can_write_cluster_rbac — names of ClusterRoles bound cluster-wide to
# agent-swarm-flux that allow create on clusterroles or clusterrolebindings.
flux_can_write_cluster_rbac() {
  yq -o=json '.spec.resources' "${RS}" | jq -r '
    [ .[] | select(.kind == "ClusterRoleBinding")
          | select(any(.subjects[]?; .kind == "ServiceAccount" and .name == "agent-swarm-flux" and .namespace == "fe-signalloom-agents"))
          | .roleRef.name ] as $bound
    | .[] | select(.kind == "ClusterRole") | select(.metadata.name as $n | $bound | index($n))
    | select(any(.rules[]?;
        any(.apiGroups[]?; . == "rbac.authorization.k8s.io" or . == "*")
        and any(.resources[]?; . == "clusterroles" or . == "clusterrolebindings" or . == "*")
        and any(.verbs[]?; . == "create" or . == "*")))
    | .metadata.name'
}

@test "agent-swarm-flux rbac: every Kustomization path it runs renders" {
  # The mechanism check: an empty path list would make both tests below vacuous.
  [ "$(grep -c . <<<"${PATHS}")" -ge 10 ]
  local p
  while read -r p; do
    kubectl kustomize "${ROOT}/${p}" >/dev/null || { echo "render failed: ${p}"; return 1; }
  done <<<"${PATHS}"
}

@test "agent-swarm-flux rbac: nothing it applies is cluster-scoped RBAC unless it holds the grant" {
  local need grant
  need="$(rendered_cluster_rbac)"
  grant="$(flux_can_write_cluster_rbac)"
  [ -z "$need" ] || [ -n "$grant" ] || {
    echo "agent-swarm-flux would apply cluster-scoped RBAC it cannot create:"; echo "$need"; return 1; }
}

@test "agent-swarm-flux rbac: it holds no ClusterRole/ClusterRoleBinding create grant that nothing uses" {
  local need grant
  need="$(rendered_cluster_rbac)"
  grant="$(flux_can_write_cluster_rbac)"
  [ -n "$need" ] || [ -z "$grant" ] || {
    echo "escalation-capable grant with no consumer: ${grant}"; return 1; }
}
