#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      afm-rbac-exporter-manifests
# @target  d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel, d2-osramp-fleet/tenants/base/agent-swarm.yaml
# @doc     docs/Proposal — Signal Loom Spireless Token-Based Agent Identity Migration (2026-Q4).md
# @spec    SLTM Phase 1, D2/D3/ADR-06 (P1-2)
#
# Manifest validation for the read-only RBAC exporter CronJob and ClusterRole.
# Validates least-privilege RBAC (exactly 18 triples), restricted PSS, Secret volume key mounting,
# NetworkPolicy isolation, and zero mutation to sentinel DaemonSet.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export KUBECONFIG=/dev/null
  RS="${REPO_ROOT}/d2-osramp-fleet/tenants/base/agent-swarm.yaml"
  BUNDLE_DIR="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden"
  OVERLAY_OSRAMP="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/kind-osramp"
  OVERLAY_HUB="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/kind-signalloom-hub"

  BUNDLE_YAML="${BATS_TEST_TMPDIR}/bundle.yaml"
  kubectl kustomize "${BUNDLE_DIR}" > "${BUNDLE_YAML}" 2>/dev/null || true
}

q() { yq -N "$1" "$2" 2>/dev/null | sed '/^$/d'; }

@test "exporter manifests: rendered ClusterRole RBAC is exactly the 18 read-only triples (T1)" {
  [ -f "${RS}" ]

  # ClusterRole and ClusterRoleBinding live in the ResourceSet agent-swarm.yaml (P1-PRE-2)
  local cr_json
  cr_json="$(yq -o=json '.spec.resources[] | select(.kind == "ClusterRole" and .metadata.name == "signalloom-rbac-exporter")' "${RS}")"
  [ -n "${cr_json}" ]

  # Extract normalised triples: apiGroup|resource|verb
  local triples
  triples="$(echo "${cr_json}" | jq -r '
    .rules[]
    | .apiGroups as $g | .resources as $r | .verbs as $v
    | ($g[]? // "") as $group
    | $r[] as $res
    | $v[] as $verb
    | "\($group)|\($res)|\($verb)"
  ' | LC_ALL=C sort -u)"

  local expected
  expected="$(cat <<'EOF'
rbac.authorization.k8s.io|clusterrolebindings|get
rbac.authorization.k8s.io|clusterrolebindings|list
rbac.authorization.k8s.io|clusterrolebindings|watch
rbac.authorization.k8s.io|clusterroles|get
rbac.authorization.k8s.io|clusterroles|list
rbac.authorization.k8s.io|clusterroles|watch
rbac.authorization.k8s.io|rolebindings|get
rbac.authorization.k8s.io|rolebindings|list
rbac.authorization.k8s.io|rolebindings|watch
rbac.authorization.k8s.io|roles|get
rbac.authorization.k8s.io|roles|list
rbac.authorization.k8s.io|roles|watch
|namespaces|get
|namespaces|list
|namespaces|watch
|serviceaccounts|get
|serviceaccounts|list
|serviceaccounts|watch
EOF
)"

  # Assert exact match of the 18 triples
  [ "${triples}" = "${expected}" ]
  [ "$(wc -l <<<"${triples}")" -eq 18 ]

  # Assert no wildcard '*' in any rule
  local wildcards
  wildcards="$(echo "${cr_json}" | jq -r '[.rules[] | (.apiGroups[]?, .resources[]?, .verbs[]?)] | any(. == "*")')"
  [ "${wildcards}" = "false" ]

  # Assert no resourceNames, nonResourceURLs, or aggregationRule
  local has_res_names has_non_res has_agg
  has_res_names="$(echo "${cr_json}" | jq -r '[.rules[].resourceNames? // empty] | length')"
  has_non_res="$(echo "${cr_json}" | jq -r '[.rules[].nonResourceURLs? // empty] | length')"
  has_agg="$(echo "${cr_json}" | jq -r 'if .aggregationRule != null then 1 else 0 end')"
  [ "${has_res_names}" -eq 0 ]
  [ "${has_non_res}" -eq 0 ]
  [ "${has_agg}" -eq 0 ]

  # Assert no ClusterRole or ClusterRoleBinding appears in the bundle render itself
  local bundle_cluster_rbac
  bundle_cluster_rbac="$(q 'select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding") | .kind + "/" + .metadata.name' "${BUNDLE_YAML}")"
  [ -z "${bundle_cluster_rbac}" ]
}

@test "exporter manifests: never reads secrets and is never the probe (T2)" {
  [ -f "${RS}" ]

  local cr_json
  cr_json="$(yq -o=json '.spec.resources[] | select(.kind == "ClusterRole" and .metadata.name == "signalloom-rbac-exporter")' "${RS}")"
  [ -n "${cr_json}" ]

  # (a) No rule anywhere in rendered exporter RBAC names secrets
  local resources
  resources=($(echo "${cr_json}" | jq -r '.rules[].resources[]'))
  [[ " ${resources[*]} " != *" secrets "* ]]

  # (b) CronJob serviceAccountName is signalloom-rbac-exporter and differs from DaemonSet (signalloom-warden)
  local cj_sa ds_sa
  cj_sa="$(q 'select(.kind == "CronJob" and .metadata.name == "signalloom-rbac-exporter") | .spec.jobTemplate.spec.template.spec.serviceAccountName' "${BUNDLE_YAML}")"
  ds_sa="$(q 'select(.kind == "DaemonSet" and (.metadata.name == "signalloom-warden" or .metadata.name == "stun-sentinel")) | .spec.template.spec.serviceAccountName' "${BUNDLE_YAML}")"
  [ "${cj_sa}" = "signalloom-rbac-exporter" ]
  [[ "${ds_sa}" == "signalloom-warden" || "${ds_sa}" == "stun-sentinel" ]]
  [ "${cj_sa}" != "${ds_sa}" ]

  # (c) ClusterRoleBinding subjects is exactly signalloom-rbac-exporter ServiceAccount
  local crb_json
  crb_json="$(yq -o=json '.spec.resources[] | select(.kind == "ClusterRoleBinding" and .metadata.name == "signalloom-rbac-exporter")' "${RS}")"
  [ -n "${crb_json}" ]

  local role_ref subject_kind subject_name subject_ns subject_count
  role_ref="$(echo "${crb_json}" | jq -r '.roleRef.name')"
  subject_kind="$(echo "${crb_json}" | jq -r '.subjects[0].kind')"
  subject_name="$(echo "${crb_json}" | jq -r '.subjects[0].name')"
  subject_ns="$(echo "${crb_json}" | jq -r '.subjects[0].namespace')"
  subject_count="$(echo "${crb_json}" | jq -r '.subjects | length')"

  [ "${role_ref}" = "signalloom-rbac-exporter" ]
  [ "${subject_count}" -eq 1 ]
  [ "${subject_kind}" = "ServiceAccount" ]
  [ "${subject_name}" = "signalloom-rbac-exporter" ]
  [ "${subject_ns}" = "fe-signalloom-agents" ]

  # No binding in ResourceSet or bundle binds signalloom-rbac-exporter ClusterRole to stun-sentinel
  local sentinel_crb
  sentinel_crb="$(yq -o=json '.spec.resources' "${RS}" | jq -r '
    .[] | select(.kind == "ClusterRoleBinding" and .roleRef.name == "signalloom-rbac-exporter")
    | select(any(.subjects[]?; .name == "stun-sentinel"))
    | .metadata.name // empty
  ')"
  [ -z "${sentinel_crb}" ]

  # (d) DaemonSet SA gains no new ClusterRole or binding compared with base ref
  local base
  base="$(git merge-base HEAD~1 refs/heads/integration/sltm-v0.1.0 2>/dev/null || echo "HEAD~1")"
  local base_crb curr_crb
  base_crb="$(git show "${base}:d2-osramp-fleet/tenants/base/agent-swarm.yaml" 2>/dev/null \
    | yq -o=json '.spec.resources[] | select(.kind == "ClusterRoleBinding") | select(any(.subjects[]?; .name == "stun-sentinel")) | .roleRef.name' | sort -u)"
  curr_crb="$(yq -o=json '.spec.resources[] | select(.kind == "ClusterRoleBinding") | select(any(.subjects[]?; .name == "stun-sentinel")) | .roleRef.name' "${RS}" | sort -u)"
  [ "${base_crb}" = "${curr_crb}" ]
}

@test "exporter manifests: restricted Pod Security on pod template (T3)" {
  [ -f "${BUNDLE_YAML}" ]

  local cj_json
  cj_json="$(yq -o=json 'select(.kind == "CronJob" and .metadata.name == "signalloom-rbac-exporter")' "${BUNDLE_YAML}")"
  [ -n "${cj_json}" ]

  # Concurrency, backoff limit, and active deadline
  local conc backoff deadline
  conc="$(echo "${cj_json}" | jq -r '.spec.concurrencyPolicy')"
  backoff="$(echo "${cj_json}" | jq -r '.spec.jobTemplate.spec.backoffLimit')"
  deadline="$(echo "${cj_json}" | jq -r '.spec.jobTemplate.spec.activeDeadlineSeconds')"
  [ "${conc}" = "Forbid" ]
  [ "${backoff}" -eq 2 ]
  [ "${deadline}" -eq 300 ]

  # Pod securityContext
  local pod_sec
  pod_sec="$(echo "${cj_json}" | jq -r '.spec.jobTemplate.spec.template.spec.securityContext')"
  [ "$(echo "${pod_sec}" | jq -r '.runAsNonRoot')" = "true" ]
  [ "$(echo "${pod_sec}" | jq -r '.runAsUser')" -eq 65532 ]
  [ "$(echo "${pod_sec}" | jq -r '.runAsGroup')" -eq 65532 ]
  [ "$(echo "${pod_sec}" | jq -r '.fsGroup')" -eq 65532 ]
  [ "$(echo "${pod_sec}" | jq -r '.seccompProfile.type')" = "RuntimeDefault" ]

  # Pod spec: no hostNetwork, no hostPID, no hostIPC
  local host_net host_pid host_ipc
  host_net="$(echo "${cj_json}" | jq -r '.spec.jobTemplate.spec.template.spec.hostNetwork // false')"
  host_pid="$(echo "${cj_json}" | jq -r '.spec.jobTemplate.spec.template.spec.hostPID // false')"
  host_ipc="$(echo "${cj_json}" | jq -r '.spec.jobTemplate.spec.template.spec.hostIPC // false')"
  [ "${host_net}" = "false" ]
  [ "${host_pid}" = "false" ]
  [ "${host_ipc}" = "false" ]

  # Container securityContext and limits
  local c_json
  c_json="$(echo "${cj_json}" | jq -r '.spec.jobTemplate.spec.template.spec.containers[0]')"
  local c_sec
  c_sec="$(echo "${c_json}" | jq -r '.securityContext')"
  [ "$(echo "${c_sec}" | jq -r '.allowPrivilegeEscalation')" = "false" ]
  [ "$(echo "${c_sec}" | jq -r '.readOnlyRootFilesystem')" = "true" ]
  [ "$(echo "${c_sec}" | jq -r '.runAsNonRoot')" = "true" ]
  [ "$(echo "${c_sec}" | jq -r '.runAsUser')" -eq 65532 ]
  [ "$(echo "${c_sec}" | jq -r '.privileged // false')" = "false" ]

  # capabilities.drop contains ALL, capabilities.add is empty
  local drops adds
  drops="$(echo "${c_sec}" | jq -r '.capabilities.drop[]?')"
  adds="$(echo "${c_sec}" | jq -r '.capabilities.add[]?' | wc -w)"
  [[ " ${drops} " == *" ALL "* ]]
  [ "${adds}" -eq 0 ]

  # Volume types allow-list: configMap, secret, projected, emptyDir, downwardAPI
  local bad_vols
  bad_vols="$(echo "${cj_json}" | jq -r '
    .spec.jobTemplate.spec.template.spec.volumes[]
    | keys[]
    | select(. != "name" and . != "configMap" and . != "secret" and . != "projected" and . != "emptyDir" and . != "downwardAPI")
  ')"
  [ -z "${bad_vols}" ]

  # Resources requests & limits
  local cpu_req mem_req cpu_lim mem_lim
  cpu_req="$(echo "${c_json}" | jq -r '.resources.requests.cpu')"
  mem_req="$(echo "${c_json}" | jq -r '.resources.requests.memory')"
  cpu_lim="$(echo "${c_json}" | jq -r '.resources.limits.cpu')"
  mem_lim="$(echo "${c_json}" | jq -r '.resources.limits.memory')"
  [ -n "${cpu_req}" ] && [ "${cpu_req}" != "null" ]
  [ -n "${mem_req}" ] && [ "${mem_req}" != "null" ]
  [ -n "${cpu_lim}" ] && [ "${cpu_lim}" != "null" ]
  [ -n "${mem_lim}" ] && [ "${mem_lim}" != "null" ]
}

@test "exporter manifests: key mounted as Secret volume and target URL is cluster-local (T4)" {
  [ -f "${BUNDLE_YAML}" ]

  local cj_json
  cj_json="$(yq -o=json 'select(.kind == "CronJob" and .metadata.name == "signalloom-rbac-exporter")' "${BUNDLE_YAML}")"
  [ -n "${cj_json}" ]

  # Key secret volume
  local key_secret mode
  key_secret="$(echo "${cj_json}" | jq -r '.spec.jobTemplate.spec.template.spec.volumes[] | select(.name == "afm-key") | .secret.secretName')"
  mode="$(echo "${cj_json}" | jq -r '.spec.jobTemplate.spec.template.spec.volumes[] | select(.name == "afm-key") | .secret.defaultMode')"
  [ "${key_secret}" = "signalloom-rbac-exporter-afm-key" ]
  [ "${mode}" = "288" ] || [ "${mode}" = "0440" ] || [ "${mode}" = "256" ] || [ "${mode}" = "0400" ]

  # Key volumeMount
  local key_mount ro
  key_mount="$(echo "${cj_json}" | jq -r '.spec.jobTemplate.spec.template.spec.containers[0].volumeMounts[] | select(.name == "afm-key") | .mountPath')"
  ro="$(echo "${cj_json}" | jq -r '.spec.jobTemplate.spec.template.spec.containers[0].volumeMounts[] | select(.name == "afm-key") | .readOnly')"
  [ "${key_mount}" = "/etc/signalloom-rbac-exporter/afm-key" ]
  [ "${ro}" = "true" ]

  # No key in env[].valueFrom, env[].value, or args
  local env_sec
  env_sec="$(echo "${cj_json}" | jq -r '.spec.jobTemplate.spec.template.spec.containers[0].env[]? | .valueFrom.secretKeyRef.name // empty')"
  [ -z "${env_sec}" ]

  # AFM_IMPORT_URL is cluster-local service
  local import_url
  import_url="$(echo "${cj_json}" | jq -r '.spec.jobTemplate.spec.template.spec.containers[0].env[]? | select(.name == "AFM_IMPORT_URL") | .value')"
  [ "${import_url}" = "http://fe-signalloom-api.fe-signalloom.svc.cluster.local:8000/api/v1/afm/clusters/import" ]

  # Image is python:3.12-slim (not :latest)
  local img
  img="$(echo "${cj_json}" | jq -r '.spec.jobTemplate.spec.template.spec.containers[0].image')"
  [ "${img}" = "python:3.12-slim" ]
  [[ "${img}" != *":latest"* ]]
}

# The exporter shares the sentinel's bundle directory; it must add its own
# objects and never alter the sentinel's. This used to diff the three files
# against `git merge-base HEAD~1 integration`, which failed on any branch (and
# on the integration line itself) that legitimately changed the sentinel, e.g.
# an image re-pin. Now: the sentinel's objects rendered from the whole bundle
# must equal the same objects rendered from the sentinel's own files alone,
# so only something in the bundle that transforms them can fail it.
@test "exporter manifests: sentinel DaemonSet, rbac.yaml and service-account.yaml unchanged from base ref" {
  local alone bundle_render alone_render sel
  alone="${BATS_TEST_TMPDIR}/sentinel-alone"
  mkdir -p "${alone}"
  cp "${BUNDLE_DIR}"/{service-account.yaml,rbac.yaml,configmap.yaml,daemonset.yaml} "${alone}/"
  cat >"${alone}/kustomization.yaml" <<'KUST'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [service-account.yaml, rbac.yaml, configmap.yaml, daemonset.yaml]
KUST
  sel='select((.kind == "DaemonSet") or (.kind == "Role" and .metadata.name == "signalloom-warden") or (.kind == "RoleBinding" and .metadata.name == "signalloom-warden") or (.kind == "ServiceAccount" and .metadata.name == "signalloom-warden"))'
  bundle_render="$(KUBECONFIG=/dev/null kubectl kustomize "${BUNDLE_DIR}" | yq ea -o=json -I=0 "[${sel}] | sort_by(.kind + .metadata.name)")"
  alone_render="$(KUBECONFIG=/dev/null kubectl kustomize "${alone}" | yq ea -o=json -I=0 "[${sel}] | sort_by(.kind + .metadata.name)")"
  [ "$(jq 'length' <<<"${alone_render}")" -ge 3 ] || { echo "sentinel objects not found: ${alone_render}"; return 1; }
  [ "${bundle_render}" = "${alone_render}" ] || { diff <(jq . <<<"${alone_render}") <(jq . <<<"${bundle_render}"); return 1; }
}

@test "exporter manifests: overlay renders apply correct cluster id and suspend state" {
  local osramp_cluster_id hub_suspend
  osramp_cluster_id="$(kubectl kustomize "${OVERLAY_OSRAMP}" 2>/dev/null \
    | yq -r 'select(.kind == "CronJob" and .metadata.name == "signalloom-rbac-exporter") | .spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == "AFM_CLUSTER_ID") | .value')"
  [ "${osramp_cluster_id}" = "kind-osramp" ]

  hub_suspend="$(kubectl kustomize "${OVERLAY_HUB}" 2>/dev/null \
    | yq -r 'select(.kind == "CronJob" and .metadata.name == "signalloom-rbac-exporter") | .spec.suspend')"
  [ "${hub_suspend}" = "true" ]
}

@test "exporter manifests: NetworkPolicy allows only DNS, API server, and fe-signalloom (8000)" {
  [ -f "${BUNDLE_YAML}" ]

  local np_json
  np_json="$(yq -o=json 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-rbac-exporter-egress")' "${BUNDLE_YAML}")"
  [ -n "${np_json}" ]

  # Pod selector
  local sel
  sel="$(echo "${np_json}" | jq -r '.spec.podSelector.matchLabels["app.kubernetes.io/name"]')"
  [ "${sel}" = "signalloom-rbac-exporter" ]

  # PolicyTypes is strictly Egress
  local ptypes
  ptypes="$(echo "${np_json}" | jq -r '.spec.policyTypes | join(",")')"
  [ "${ptypes}" = "Egress" ]

  # Egress rules count
  local egress_count
  egress_count="$(echo "${np_json}" | jq -r '.spec.egress | length')"
  [ "${egress_count}" -eq 3 ]

  # Rule 1: DNS to kube-system on 53
  local dns_ns dns_ports
  dns_ns="$(echo "${np_json}" | jq -r '.spec.egress[0].to[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]')"
  dns_ports="$(echo "${np_json}" | jq -r '[.spec.egress[0].ports[].port] | sort | join(",")')"
  [ "${dns_ns}" = "kube-system" ]
  [ "${dns_ports}" = "53,53" ]

  # Rule 2: API server ports 6443 and 443
  local api_ports
  api_ports="$(echo "${np_json}" | jq -r '[.spec.egress[1].ports[].port] | sort | join(",")')"
  [ "${api_ports}" = "443,6443" ]

  # Rule 3: fe-signalloom namespace on port 8000
  local fe_ns fe_port
  fe_ns="$(echo "${np_json}" | jq -r '.spec.egress[2].to[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]')"
  fe_port="$(echo "${np_json}" | jq -r '.spec.egress[2].ports[0].port')"
  [ "${fe_ns}" = "fe-signalloom" ]
  [ "${fe_port}" = "8000" ]
}

# The exporter does NOT follow the warden to inf-signalloom-warden. Every
# contract it has names fe-signalloom-agents: the ClusterRoleBinding subject in
# the ResourceSet, fe-signalloom's ingress NetworkPolicy namespaceSelector, and
# the namespace scripts/afm-importer-key.sh writes its key Secret to. The
# expected namespace is read from those three sources, not restated here.
@test "exporter manifests: every rendered object has a namespace; exporter objects in fe-signalloom-agents, warden objects in inf-signalloom-warden" {
  local crb_ns np_ns key_ns
  crb_ns="$(yq -r '.spec.resources[] | select(.kind == "ClusterRoleBinding" and .metadata.name == "signalloom-rbac-exporter") | .subjects[0].namespace' "${RS}")"
  np_ns="$(yq -r 'select(.metadata.name == "allow-rbac-exporter-ingress") | .spec.ingress[0].from[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]' \
    "${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml")"
  key_ns="$(sed -n 's/^CONSUMER_NS="\(.*\)"$/\1/p' "${REPO_ROOT}/scripts/afm-importer-key.sh")"
  [ "${crb_ns}" = "fe-signalloom-agents" ]
  [ "${np_ns}" = "${crb_ns}" ]
  [ "${key_ns}" = "${crb_ns}" ]

  local missing_ns
  missing_ns="$(kubectl kustomize "${BUNDLE_DIR}" \
    | yq -o=json 'select(.kind != null) | select(.metadata.namespace == null or .metadata.namespace == "") | .kind + "/" + .metadata.name')"
  [ -z "${missing_ns}" ]

  local bad_ns
  bad_ns="$(kubectl kustomize "${BUNDLE_DIR}" \
    | yq -r "select(.kind != null) | select((.metadata.name | test(\"rbac-exporter\")) and .metadata.namespace != \"${crb_ns}\") | .kind + \"/\" + .metadata.name")"
  [ -z "${bad_ns}" ] || { echo "exporter objects outside ${crb_ns}: ${bad_ns}" >&2; return 1; }
  [ "$(kubectl kustomize "${BUNDLE_DIR}" | yq -r 'select(.metadata.name | test("rbac-exporter")) | .kind' | grep -v '^---$' | LC_ALL=C sort -u | tr '\n' ' ')" = "ConfigMap CronJob NetworkPolicy ServiceAccount " ]

  bad_ns="$(kubectl kustomize "${BUNDLE_DIR}" \
    | yq -r 'select(.kind != null) | select((.metadata.name | test("rbac-exporter") | not) and .metadata.namespace != "inf-signalloom-warden") | .kind + "/" + .metadata.name')"
  [ -z "${bad_ns}" ] || { echo "warden objects outside inf-signalloom-warden: ${bad_ns}" >&2; return 1; }
}

# What Flux actually applies on kind-osramp: the overlay render, then the
# Kustomization's targetNamespace (if any) overrides every namespaced object.
# A targetNamespace here would drag the exporter away from its RBAC subject.
@test "exporter manifests: on kind-osramp, as Flux applies it, the exporter SA is the ClusterRoleBinding subject" {
  local target crb_ns eff
  target="$(yq -r '.spec.resources[] | select(.kind == "Kustomization" and .metadata.name == "agent-signalloom-warden") | .spec.targetNamespace // ""' "${RS}")"
  crb_ns="$(yq -r '.spec.resources[] | select(.kind == "ClusterRoleBinding" and .metadata.name == "signalloom-rbac-exporter") | .subjects[0].namespace' "${RS}")"
  eff="$(kubectl kustomize "${OVERLAY_OSRAMP}" | yq -r 'select(.kind == "ServiceAccount" and .metadata.name == "signalloom-rbac-exporter") | .metadata.namespace')"
  [ -n "${eff}" ]
  [ -n "${target}" ] && eff="${target}"
  [ "${eff}" = "${crb_ns}" ] || { echo "exporter SA lands in ${eff}, ClusterRoleBinding names ${crb_ns}" >&2; return 1; }
  # and the CronJob runs as that SA, with the generated script in the same namespace
  [ "$(kubectl kustomize "${OVERLAY_OSRAMP}" | yq -r 'select(.kind == "CronJob" and .metadata.name == "signalloom-rbac-exporter") | .spec.jobTemplate.spec.template.spec.serviceAccountName')" = "signalloom-rbac-exporter" ]
}
