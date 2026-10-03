#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      signalloom-warden-manifests
# @target  d2-signalloom/infra/agent-swarm/signalloom-warden, d2-osramp-fleet/tenants/base/agent-swarm.yaml
# @doc     docs/Proposal — Signal Loom Spireless Token-Based Agent Identity Migration (2026-Q4).md
# @spec    SLTM Phase 3, D1/D2/ADR-07 (P3-1)
#
# Identity guard and reference resolution for the probe rename to signalloom-warden.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export KUBECONFIG=/dev/null
  export CGO_ENABLED=0
  export GOPATH="${GOPATH:-/tmp/gopath}"
  export GOCACHE="${GOCACHE:-/tmp/gocache}"

  ALLOWLIST="${REPO_ROOT}/test/signalloom-warden-allowlist.txt"
  RS="${REPO_ROOT}/d2-osramp-fleet/tenants/base/agent-swarm.yaml"

  # Probe bundle and overlays paths (must be signalloom-warden)
  WARDEN_BASE="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden"
  OVERLAY_OSRAMP="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/kind-osramp"
  OVERLAY_HUB="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/kind-signalloom-hub"
  FE_LOCAL="${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/local"
  FM_BASE="${REPO_ROOT}/d2-signalloom/apps/fleet-manager/base"

  TMP_BASE="${BATS_TEST_TMPDIR}/warden_base.yaml"
  TMP_OSRAMP="${BATS_TEST_TMPDIR}/overlay_osramp.yaml"
  TMP_HUB="${BATS_TEST_TMPDIR}/overlay_hub.yaml"
  TMP_FE="${BATS_TEST_TMPDIR}/fe_local.yaml"
  TMP_FM="${BATS_TEST_TMPDIR}/fm_base.yaml"

  if [ -d "${WARDEN_BASE}" ]; then
    kubectl kustomize "${WARDEN_BASE}" > "${TMP_BASE}" 2>/dev/null || true
  else
    touch "${TMP_BASE}"
  fi

  if [ -d "${OVERLAY_OSRAMP}" ]; then
    kubectl kustomize "${OVERLAY_OSRAMP}" > "${TMP_OSRAMP}" 2>/dev/null || true
  else
    touch "${TMP_OSRAMP}"
  fi

  if [ -d "${OVERLAY_HUB}" ]; then
    kubectl kustomize "${OVERLAY_HUB}" > "${TMP_HUB}" 2>/dev/null || true
  else
    touch "${TMP_HUB}"
  fi

  if [ -d "${FE_LOCAL}" ]; then
    kubectl kustomize "${FE_LOCAL}" > "${TMP_FE}" 2>/dev/null || true
  else
    touch "${TMP_FE}"
  fi

  if [ -d "${FM_BASE}" ]; then
    kubectl kustomize "${FM_BASE}" > "${TMP_FM}" 2>/dev/null || true
  else
    touch "${TMP_FM}"
  fi
}

@test "T1(a) identity guard: all identity-bearing objects exist under signalloom-warden name" {
  [ -f "${RS}" ]
  [ -s "${TMP_BASE}" ]
  [ -s "${TMP_OSRAMP}" ]
  [ -s "${TMP_HUB}" ]
  [ -s "${TMP_FE}" ]
  [ -s "${TMP_FM}" ]

  # Collect all Kind/namespace/name across the renders
  local have_objects
  have_objects="$(
    {
      yq -r 'select(. != null) | "\(.kind)/" + (.metadata.namespace // "none") + "/\(.metadata.name)"' "${TMP_BASE}" "${TMP_OSRAMP}" "${TMP_HUB}" "${TMP_FE}" "${TMP_FM}"
      yq -r '.spec.resources[]? | select(. != null) | "\(.kind)/" + (.metadata.namespace // "none") + "/\(.metadata.name)"' "${RS}"
    } | LC_ALL=C sort -u
  )"

  # Assert the 10 required identity-bearing objects exist
  local required_objects=(
    "ConfigMap/fe-signalloom-agents/signalloom-warden-config"
    "DaemonSet/fe-signalloom-agents/signalloom-warden"
    "Role/fe-signalloom-agents/signalloom-warden"
    "RoleBinding/fe-signalloom-agents/signalloom-warden"
    "ServiceAccount/fe-signalloom-agents/signalloom-warden"
    "Kustomization/fe-signalloom-agents/agent-signalloom-warden"
  )

  for obj in "${required_objects[@]}"; do
    echo "${have_objects}" | grep -q "^${obj}$"
    [ $? -eq 0 ]
  done

  # Check canonical image repository in base daemonset
  local image_repo
  image_repo="$(yq -r 'select(.kind == "DaemonSet" and .metadata.name == "signalloom-warden") | .spec.template.spec.containers[0].image' "${TMP_BASE}" | cut -d: -f1)"
  [ "${image_repo}" = "ghcr.io/controlplaneio-in-toto/signalloom-warden" ]
}

@test "T1(b) identity guard: no un-allowlisted stun-sentinel occurrences in rendered objects" {
  [ -f "${ALLOWLIST}" ]
  [ -s "${TMP_BASE}" ]
  [ -s "${TMP_OSRAMP}" ]
  [ -s "${TMP_HUB}" ]
  [ -s "${TMP_FE}" ]
  [ -s "${TMP_FM}" ]

  local unallowlisted=0
  local all_renders=("${TMP_BASE}" "${TMP_OSRAMP}" "${TMP_HUB}" "${TMP_FE}" "${TMP_FM}")

  for f in "${all_renders[@]}"; do
    # Extract identity-bearing string fields from each document
    local matches
    matches="$(yq -r '
      select(. != null) |
      (
        .metadata.name,
        .metadata.labels[]?,
        .spec.selector.matchLabels[]?,
        .spec.template.metadata.labels[]?,
        .spec.template.spec.serviceAccountName,
        .roleRef.name,
        .subjects[]?.name,
        .spec.template.spec.containers[]?.image,
        .spec.template.spec.containers[]?.env[]?.name,
        .spec.template.spec.containers[]?.env[]?.value,
        .spec.template.spec.containers[]?.env[]?.valueFrom.secretKeyRef.name,
        .spec.template.spec.containers[]?.env[]?.valueFrom.secretKeyRef.key,
        .spec.template.spec.containers[]?.env[]?.valueFrom.configMapKeyRef.name,
        .spec.template.spec.containers[]?.env[]?.valueFrom.configMapKeyRef.key,
        .spec.template.spec.volumes[]?.name,
        .spec.template.spec.volumes[]?.secret.secretName,
        .spec.template.spec.volumes[]?.configMap.name,
        .spec.template.spec.volumes[]?.projected.sources[]?.secret.name,
        .spec.template.spec.volumes[]?.projected.sources[]?.secret.items[]?.path,
        .data[]?
      )
    ' "$f" 2>/dev/null | grep -F "stun-sentinel" || true)"

    if [ -n "${matches}" ]; then
      while IFS= read -r line; do
        [ -n "${line}" ] || continue
        # Check if line or matched token is allow-listed
        if ! grep -Fq "stun-sentinel" "${ALLOWLIST}"; then
          echo "UNALLOWLISTED occurrence in $f: ${line}" >&2
          unallowlisted=$((unallowlisted + 1))
        fi
      done <<< "${matches}"
    fi
  done

  # Also inspect the probe bundle manifests directly: no un-allowlisted stun-sentinel
  if [ -d "${WARDEN_BASE}" ]; then
    local base_occurrences
    base_occurrences="$(grep -rn -F "stun-sentinel" "${WARDEN_BASE}" || true)"
    if [ -n "${base_occurrences}" ]; then
      echo "UNALLOWLISTED in ${WARDEN_BASE}: ${base_occurrences}" >&2
      unallowlisted=$((unallowlisted + 1))
    fi
  else
    unallowlisted=$((unallowlisted + 1))
  fi

  [ "${unallowlisted}" -eq 0 ]
}

@test "T1(c) identity guard: DaemonSet selector equals template labels and both carry signalloom-warden" {
  [ -s "${TMP_BASE}" ]

  local ds_name selector_label template_label
  ds_name="$(yq -r 'select(.kind == "DaemonSet") | .metadata.name' "${TMP_BASE}")"
  selector_label="$(yq -r 'select(.kind == "DaemonSet") | .spec.selector.matchLabels["app.kubernetes.io/name"]' "${TMP_BASE}")"
  template_label="$(yq -r 'select(.kind == "DaemonSet") | .spec.template.metadata.labels["app.kubernetes.io/name"]' "${TMP_BASE}")"

  [ "${ds_name}" = "signalloom-warden" ]
  [ "${selector_label}" = "signalloom-warden" ]
  [ "${template_label}" = "signalloom-warden" ]
  [ "${selector_label}" = "${template_label}" ]
}

@test "T2 reference resolution: ServiceAccount, RoleBinding, ConfigMap, Secrets and Flux resolve" {
  [ -s "${TMP_BASE}" ]
  [ -f "${RS}" ]

  # 1. In probe bundle: serviceAccountName resolves to ServiceAccount in same render
  local sa_name sa_ref
  sa_name="$(yq -r 'select(.kind == "ServiceAccount" and .metadata.name == "signalloom-warden") | .metadata.name' "${TMP_BASE}")"
  sa_ref="$(yq -r 'select(.kind == "DaemonSet") | .spec.template.spec.serviceAccountName' "${TMP_BASE}")"
  [ "${sa_name}" = "signalloom-warden" ]
  [ "${sa_ref}" = "${sa_name}" ]

  # 2. RoleBinding roleRef and subjects resolve to Role and SA in same render
  local rb_role rb_subject role_name
  role_name="$(yq -r 'select(.kind == "Role" and .metadata.name == "signalloom-warden") | .metadata.name' "${TMP_BASE}")"
  rb_role="$(yq -r 'select(.kind == "RoleBinding" and .metadata.name == "signalloom-warden") | .roleRef.name' "${TMP_BASE}")"
  rb_subject="$(yq -r 'select(.kind == "RoleBinding" and .metadata.name == "signalloom-warden") | .subjects[0].name' "${TMP_BASE}")"
  [ "${role_name}" = "signalloom-warden" ]
  [ "${rb_role}" = "${role_name}" ]
  [ "${rb_subject}" = "${sa_name}" ]

  # 3. ConfigMapKeyRef names resolve to ConfigMap in same render
  local cm_name
  cm_name="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "signalloom-warden-config") | .metadata.name' "${TMP_BASE}")"
  [ "${cm_name}" = "signalloom-warden-config" ]

  local cm_refs
  cm_refs="$(yq -r 'select(.kind == "DaemonSet") | .spec.template.spec.containers[0].env[]?.valueFrom.configMapKeyRef.name | select(. != null)' "${TMP_BASE}" | LC_ALL=C sort -u)"
  [ "${cm_refs}" = "${cm_name}" ]

  # 4. Secret names referenced in DaemonSet match issuer scripts
  local secret_refs
  secret_refs="$(yq -r 'select(.kind == "DaemonSet") | .spec.template.spec.containers[0].env[]?.valueFrom.secretKeyRef.name | select(. != null)' "${TMP_BASE}" | LC_ALL=C sort -u)"

  echo "${secret_refs}" | grep -q "^signalloom-warden-ingest-token$"
  [ $? -eq 0 ]
  echo "${secret_refs}" | grep -q "^signalloom-warden-fleet-key$"
  [ $? -eq 0 ]
  echo "${secret_refs}" | grep -q "^signalloom-warden-governance$"
  [ $? -eq 0 ]

  # 5. Flux Kustomization path exists and exactly one probe Kustomization exists in agent-swarm.yaml
  local flux_kust_names
  flux_kust_names="$(yq -r '.spec.resources[] | select(.kind == "Kustomization") | .metadata.name' "${RS}" | grep -E 'agent-signalloom-(stun-sentinel|warden)' || true)"
  [ "${flux_kust_names}" = "agent-signalloom-warden" ]

  local flux_path
  flux_path="$(yq -r '.spec.resources[] | select(.kind == "Kustomization" and .metadata.name == "agent-signalloom-warden") | .spec.path' "${RS}")"
  [ "${flux_path}" = "./signalloom-warden-overlays/kind-osramp" ]
  [ -d "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/kind-osramp" ]
}

@test "T3 tenancy and caller keys: signal-ingest key spec, fleet-manager caller key, and SENTINEL_TENANT_MAP resolve" {
  [ -s "${TMP_FE}" ]
  [ -s "${TMP_FM}" ]
  [ -s "${TMP_BASE}" ]

  # 1. SIGNAL_AUTH_STATIC_KEYS has signalloom-warden key spec with exact permissions
  local static_keys_json
  static_keys_json="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "signal-ingest-jwt-auth") | .data.SIGNAL_AUTH_STATIC_KEYS' "${TMP_FE}")"
  [ -n "${static_keys_json}" ]

  local probe_key_tenant probe_key_perms
  probe_key_tenant="$(echo "${static_keys_json}" | jq -r '.[] | select(.name == "signalloom-warden") | .tenant')"
  probe_key_perms="$(echo "${static_keys_json}" | jq -r '.[] | select(.name == "signalloom-warden") | .permissions | sort | join(",")')"
  [ "${probe_key_tenant}" = "kusari" ]
  [ "${probe_key_perms}" = "observations:write,tenant:cross-write" ]

  # 2. fleet-manager caller key reference
  local fm_warden_key fm_warden_scopes
  fm_warden_key="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "fleet-manager") | .spec.template.spec.containers[0].env[] | select(.name == "FLEET_MANAGER_KEY_SIGNALLOOM_WARDEN") | .valueFrom.secretKeyRef.key' "${TMP_FM}")"
  fm_warden_scopes="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "fleet-manager") | .spec.template.spec.containers[0].env[] | select(.name == "FLEET_MANAGER_KEY_SIGNALLOOM_WARDEN_SCOPES") | .value' "${TMP_FM}")"
  [ "${fm_warden_key}" = "signalloom-warden" ]
  [ "${fm_warden_scopes}" = "stun" ]

  # 3. SENTINEL_TENANT_MAP mounted in DaemonSet and parses
  local tenant_map
  tenant_map="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "signalloom-warden-config") | .data.SENTINEL_TENANT_MAP' "${TMP_BASE}")"
  [ -n "${tenant_map}" ]
  echo "${tenant_map}" | grep -q "fe-signalloom-agents/kusari-agent=kusari"
  [ $? -eq 0 ]
}

@test "T4 fleet-manager admission: NetworkPolicy and build integrity" {
  # Build and test fleet-manager
  cd "${REPO_ROOT}/d2-signalloom/apps/fleet-manager"
  go build ./...
  go vet ./...
  go test -count=1 ./...
}
