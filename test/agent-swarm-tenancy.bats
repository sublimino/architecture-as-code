#!/usr/bin/env bats
#
# @id      agent-swarm-tenancy
# @target  d2-signalloom/infra/agent-swarm
#
# Every swarm agent's tenant is declared once, by GitOps, as the
# signalloom.ai/tenant label. Two consumers read it:
#
#   * fe-signalloom claims (claim_tenancy): discovery reports the label from the
#     POD (or the kagent Agent CR), and a workload with no label cannot be
#     claimed at all (403 workload_tenant_undeclared).
#   * the stun sentinel attributes each observation from SENTINEL_TENANT_MAP,
#     keyed on namespace/serviceAccount, never from a pod label (review M5).
#
# So a new agent with no tenant label is not a style nit. Discovery cannot
# claim it, and if the map disagrees with the label, the sentinel attributes
# its activity to another tenant. This suite fails CI for either, rather than
# a claim failing at runtime.
#
# Derived, not listed: every directory under agent-swarm with a
# kustomization.yaml is rendered, and every workload labelled
# signalloom.ai/agent=true is checked. Offline: kubectl kustomize, yq, jq.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SWARM="${REPO_ROOT}/d2-signalloom/infra/agent-swarm"
  CM="${SWARM}/signalloom-stun-sentinel/configmap.yaml"
}

# workloads — one JSON object per agent workload:
#   {dir, kind, name, ns, sa, tenant, pod_tenant, role}
# pod_tenant is the pod template's label (null for a kagent Agent CR, which
# discovery reads from the CR itself).
workloads() {
  local d
  for d in "${SWARM}"/*/; do
    [ -f "${d}kustomization.yaml" ] || continue
    kubectl kustomize "$d" | yq -o=json -I0 '.' | jq -c --arg dir "$(basename "$d")" '
      select(type == "object")
      | select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "Job"
               or .kind == "DaemonSet" or .kind == "Agent"
               or (.kind == "Service" and (.apiVersion | startswith("serving.knative"))))
      | select((.metadata.labels // {})["signalloom.ai/agent"] == "true")
      | . as $o
      | { dir: $dir, kind: .kind, name: .metadata.name,
          ns: (.metadata.namespace // "-"),
          sa: (if .kind == "Agent" then .metadata.name
               else (.spec.template.spec.serviceAccountName // "default") end),
          tenant: ((.metadata.labels // {})["signalloom.ai/tenant"]),
          pod_tenant: (if .kind == "Agent" then null
                       else ((.spec.template.metadata.labels // {})["signalloom.ai/tenant"]) end),
          role: ((.metadata.labels // {})["signalloom.ai/role"]) }'
  done
}

@test "agent-swarm tenancy: every agent workload renders and there are enough to mean something" {
  run workloads
  [ "$status" -eq 0 ]
  [ "$(grep -c . <<<"$output")" -ge 15 ]
}

@test "agent-swarm tenancy: every agent workload declares signalloom.ai/tenant, on its pod template too" {
  local bad
  bad="$(workloads | jq -r '
    select((.tenant // "") == "" or (.kind != "Agent" and (.pod_tenant // "") != .tenant))
    | "\(.dir) \(.kind)/\(.name): tenant=\(.tenant) pod_tenant=\(.pod_tenant)"')"
  [ -z "$bad" ] || { echo "agent workloads with no (or a mismatched pod) tenant label:"; echo "$bad"; return 1; }
}

@test "agent-swarm tenancy: every declared tenant is a lowercase DNS label (no homoglyphs)" {
  local t bad=""
  while read -r t; do
    [ -n "$t" ] || continue
    [[ "$t" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || bad="${bad} ${t}"
  done < <(workloads | jq -r '.tenant // empty' | sort -u)
  [ -z "$bad" ] || { echo "tenant labels that are not plain labels:${bad}"; return 1; }
}

@test "agent-swarm tenancy: the sentinel's tenant map attributes every agent's service account to its declared tenant" {
  local map entries missing
  map="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "stun-sentinel-config") | .data.SENTINEL_TENANT_MAP' "${CM}")"
  [ -n "$map" ] && [ "$map" != "null" ]
  # namespace/serviceAccount=tenant, comma- or newline-separated.
  entries="$(tr ',' '\n' <<<"$map" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort -u)"
  # The sentinel is self-excluded from attribution; every other agent must map.
  missing="$(workloads | jq -r 'select(.role != "sentinel") | "\(.ns)/\(.sa)=\(.tenant)"' | sort -u \
    | grep -vxF -f <(printf '%s\n' "$entries") || true)"
  [ -z "$missing" ] || { echo "SENTINEL_TENANT_MAP lacks (or disagrees with) these entries:"; echo "$missing"; return 1; }
}
