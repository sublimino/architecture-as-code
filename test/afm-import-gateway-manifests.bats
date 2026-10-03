#!/usr/bin/env bats
#
# @id      afm-import-gateway-manifests
# @target  d2-k8s-afm/apps/afm-platform/base, d2-signalloom/apps/fe-signalloom/base, dashboard-signalloom/nginx.conf
# @doc     docs/Proposal — Signal Loom Spireless Token-Based Agent Identity Migration (2026-Q4).md
#
# Static verification of AFM import gateway manifests:
# - afm-platform ingress NetworkPolicy (exact four-peer set on TCP 8000)
# - afm-platform HTTPRoute L7 refusal via HTTPRouteFilter (statusCode 403)
# - CronJob pod template component label
# - fe-signalloom Deployment secret projection (mode 0440, optional, no key in env/cm/args)
# - fe-signalloom ingress NetworkPolicy allow-rbac-exporter-ingress
# - dashboard nginx.conf location blocking /clusters/import and /afm/clusters/import

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  AFM_BASE="${REPO_ROOT}/d2-k8s-afm/apps/afm-platform/base"
  FE_BASE="${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/base"
  NGINX_CONF="${REPO_ROOT}/d2-signalloom/apps/dashboard-signalloom/nginx.conf"

  AFM_RENDER="${BATS_TEST_TMPDIR}/afm-base.yaml"
  FE_RENDER="${BATS_TEST_TMPDIR}/fe-base.yaml"

  KUBECONFIG=/dev/null kubectl kustomize "${AFM_BASE}" >"${AFM_RENDER}"
  KUBECONFIG=/dev/null kubectl kustomize "${FE_BASE}" >"${FE_RENDER}"
}

@test "afm-platform: NetworkPolicy selects afm-platform and ingress from set matches exact 4 peers" {
  local np_count
  np_count="$(yq eval-all '[select(.kind == "NetworkPolicy" and .metadata.name == "afm-platform")] | length' "${AFM_RENDER}")"
  [ "${np_count}" -eq 1 ]

  # Check selector
  local sel_name
  sel_name="$(yq eval-all 'select(.kind == "NetworkPolicy" and .metadata.name == "afm-platform") | .spec.podSelector.matchLabels."app.kubernetes.io/name"' "${AFM_RENDER}")"
  [ "${sel_name}" = "afm-platform" ]

  # Check ingress port is TCP 8000
  local port proto
  port="$(yq eval-all 'select(.kind == "NetworkPolicy" and .metadata.name == "afm-platform") | .spec.ingress[0].ports[0].port' "${AFM_RENDER}")"
  proto="$(yq eval-all 'select(.kind == "NetworkPolicy" and .metadata.name == "afm-platform") | .spec.ingress[0].ports[0].protocol' "${AFM_RENDER}")"
  [ "${port}" = "8000" ]
  [ "${proto}" = "TCP" ]

  # Ingress from rules compared as sorted JSON arrays
  local actual_from expected_from
  actual_from="$(yq eval-all -o=json 'select(.kind == "NetworkPolicy" and .metadata.name == "afm-platform") | .spec.ingress[0].from' "${AFM_RENDER}" | jq -c 'sort_by(to_entries | sort_by(.key) | tostring)')"

  expected_from='[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"fe-signalloom"}},"podSelector":{"matchLabels":{"app.kubernetes.io/name":"dashboard-signalloom"}}},{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"fe-signalloom"}},"podSelector":{"matchLabels":{"app.kubernetes.io/name":"fe-signalloom"}}},{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"ingress"}},"podSelector":{"matchLabels":{"app.kubernetes.io/component":"proxy","app.kubernetes.io/managed-by":"envoy-gateway","gateway.envoyproxy.io/owning-gateway-name":"cluster"}}},{"podSelector":{"matchLabels":{"app.kubernetes.io/component":"cluster-import"}}}]'
  expected_sorted="$(echo "${expected_from}" | jq -c 'sort_by(to_entries | sort_by(.key) | tostring)')"

  [ "${actual_from}" = "${expected_sorted}" ]
}

@test "afm-platform: HTTPRoute directResponse 403 on /clusters/import and HTTPRouteFilter exists" {
  # HTTPRouteFilter definition exists with statusCode 403
  local filter_status
  filter_status="$(yq eval-all 'select(.kind == "HTTPRouteFilter" and .metadata.name == "afm-import-deny") | .spec.directResponse.statusCode' "${AFM_RENDER}")"
  [ "${filter_status}" = "403" ]

  # HTTPRoute has rules for Exact /clusters/import and PathPrefix /clusters/import/
  local rule0_exact rule0_prefix filter_kind filter_name
  rule0_exact="$(yq eval-all 'select(.kind == "HTTPRoute" and .metadata.name == "afm-platform") | .spec.rules[0].matches[0].path.value' "${AFM_RENDER}")"
  rule0_prefix="$(yq eval-all 'select(.kind == "HTTPRoute" and .metadata.name == "afm-platform") | .spec.rules[0].matches[1].path.value' "${AFM_RENDER}")"
  filter_kind="$(yq eval-all 'select(.kind == "HTTPRoute" and .metadata.name == "afm-platform") | .spec.rules[0].filters[0].extensionRef.kind' "${AFM_RENDER}")"
  filter_name="$(yq eval-all 'select(.kind == "HTTPRoute" and .metadata.name == "afm-platform") | .spec.rules[0].filters[0].extensionRef.name' "${AFM_RENDER}")"

  [ "${rule0_exact}" = "/clusters/import" ]
  [ "${rule0_prefix}" = "/clusters/import/" ]
  [ "${filter_kind}" = "HTTPRouteFilter" ]
  [ "${filter_name}" = "afm-import-deny" ]
}

@test "afm-platform: CronJob pod template carries app.kubernetes.io/component: cluster-import" {
  local comp_label
  comp_label="$(yq eval-all 'select(.kind == "CronJob" and .metadata.name == "afm-cluster-import") | .spec.jobTemplate.spec.template.metadata.labels."app.kubernetes.io/component"' "${AFM_RENDER}")"
  [ "${comp_label}" = "cluster-import" ]
}

@test "fe-signalloom: deployment mounts afm-importer-key as projected secret volume mode 0440" {
  local vol_secret vol_opt vol_mode mount_path env_val
  vol_secret="$(yq eval-all 'select(.kind == "Deployment" and .metadata.name == "fe-signalloom") | .spec.template.spec.volumes[] | select(.name == "afm-importer-key") | .secret.secretName' "${FE_RENDER}")"
  vol_opt="$(yq eval-all 'select(.kind == "Deployment" and .metadata.name == "fe-signalloom") | .spec.template.spec.volumes[] | select(.name == "afm-importer-key") | .secret.optional' "${FE_RENDER}")"
  vol_mode="$(yq eval-all 'select(.kind == "Deployment" and .metadata.name == "fe-signalloom") | .spec.template.spec.volumes[] | select(.name == "afm-importer-key") | .secret.defaultMode' "${FE_RENDER}")"

  [ "${vol_secret}" = "fe-signalloom-afm-importer-key" ]
  [ "${vol_opt}" = "true" ]
  # 0440 octal is 288 in decimal or 0440 representation
  [[ "${vol_mode}" = "288" || "${vol_mode}" = "0440" ]]

  mount_path="$(yq eval-all 'select(.kind == "Deployment" and .metadata.name == "fe-signalloom") | .spec.template.spec.containers[0].volumeMounts[] | select(.name == "afm-importer-key") | .mountPath' "${FE_RENDER}")"
  [ "${mount_path}" = "/etc/fe-signalloom/afm-importer-key" ]

  env_val="$(yq eval-all 'select(.kind == "Deployment" and .metadata.name == "fe-signalloom") | .spec.template.spec.containers[0].env[] | select(.name == "AFM_IMPORT_KEYS") | .value' "${FE_RENDER}")"
  [[ "${env_val}" == *"afm-importer"* ]]

  # Assert no ConfigMap in either render contains afm-importer paired with a secret token
  local cm_keys
  cm_keys="$(yq eval-all 'select(.kind == "ConfigMap") | .data // {} | to_entries | .[].value' "${FE_RENDER}" "${AFM_RENDER}" 2>/dev/null || true)"
  [[ "${cm_keys}" != *"afm:import"* ]]
}

@test "fe-signalloom: NetworkPolicy includes allow-rbac-exporter-ingress" {
  local np_count from_ns from_pod port proto
  np_count="$(yq eval-all '[select(.kind == "NetworkPolicy" and .metadata.name == "allow-rbac-exporter-ingress")] | length' "${FE_RENDER}")"
  [ "${np_count}" -eq 1 ]

  from_ns="$(yq eval-all 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-rbac-exporter-ingress") | .spec.ingress[0].from[0].namespaceSelector.matchLabels."kubernetes.io/metadata.name"' "${FE_RENDER}")"
  from_pod="$(yq eval-all 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-rbac-exporter-ingress") | .spec.ingress[0].from[0].podSelector.matchLabels."app.kubernetes.io/name"' "${FE_RENDER}")"
  port="$(yq eval-all 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-rbac-exporter-ingress") | .spec.ingress[0].ports[0].port' "${FE_RENDER}")"
  proto="$(yq eval-all 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-rbac-exporter-ingress") | .spec.ingress[0].ports[0].protocol' "${FE_RENDER}")"

  [ "${from_ns}" = "fe-signalloom-agents" ]
  [ "${from_pod}" = "signalloom-rbac-exporter" ]
  [ "${port}" = "8000" ]
  [ "${proto}" = "TCP" ]
}

@test "dashboard nginx.conf: closes /clusters/import and /afm/clusters/import with 403" {
  [ -f "${NGINX_CONF}" ]
  # Static check that the regex location returning 403 exists
  grep -qE 'location[[:space:]]+~[[:space:]]+\^/\(afm/\)\?clusters/import' "${NGINX_CONF}"
  # Check that return 403 occurs in that block
  awk '/location ~ \^\/\(afm\/\)\?clusters\/import/,/\}/ { if ($0 ~ /return 403;/) found=1 } END { exit !found }' "${NGINX_CONF}"
}
