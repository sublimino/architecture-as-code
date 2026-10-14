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
  local gopath="${GOPATH:-}"
  if [ "$gopath" = "/usr/local/src/gocode" ] || [ -z "$gopath" ]; then gopath=/tmp/gopath; fi
  export GOPATH="$gopath"
  export GOCACHE="${GOCACHE:-/tmp/gocache}"
  export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
  export GONOSUMDB="*"
  export CGO_ENABLED=0

  ALLOWLIST="${REPO_ROOT}/test/signalloom-warden-allowlist.txt"
  RS="${REPO_ROOT}/d2-osramp-fleet/tenants/base/agent-swarm.yaml"

  # Probe bundle and overlays paths (must be signalloom-warden)
  SWARM_BASE="${REPO_ROOT}/d2-signalloom/infra/agent-swarm"
  WARDEN_BASE="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden"
  OVERLAY_OSRAMP="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/kind-osramp"
  OVERLAY_HUB="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/kind-signalloom-hub"
  FE_LOCAL="${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/local"
  FM_BASE="${REPO_ROOT}/d2-signalloom/apps/fleet-manager/base"

  TMP_SWARM="${BATS_TEST_TMPDIR}/swarm_base.yaml"
  TMP_BASE="${BATS_TEST_TMPDIR}/warden_base.yaml"
  TMP_OSRAMP="${BATS_TEST_TMPDIR}/overlay_osramp.yaml"
  TMP_HUB="${BATS_TEST_TMPDIR}/overlay_hub.yaml"
  TMP_FE="${BATS_TEST_TMPDIR}/fe_local.yaml"
  TMP_FM="${BATS_TEST_TMPDIR}/fm_base.yaml"

  if [ -d "${SWARM_BASE}" ]; then
    kubectl kustomize "${SWARM_BASE}" > "${TMP_SWARM}" 2>/dev/null || true
  else
    touch "${TMP_SWARM}"
  fi

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
  [ -s "${TMP_SWARM}" ]
  [ -s "${TMP_BASE}" ]
  [ -s "${TMP_OSRAMP}" ]
  [ -s "${TMP_HUB}" ]
  [ -s "${TMP_FE}" ]
  [ -s "${TMP_FM}" ]

  # Collect all Kind/namespace/name across the renders
  local have_objects
  have_objects="$(
    {
      yq -r 'select(. != null) | "\(.kind)/" + (.metadata.namespace // "none") + "/\(.metadata.name)"' "${TMP_SWARM}" "${TMP_BASE}" "${TMP_OSRAMP}" "${TMP_HUB}" "${TMP_FE}" "${TMP_FM}"
      yq -r '.spec.resources[]? | select(. != null) | "\(.kind)/" + (.metadata.namespace // "none") + "/\(.metadata.name)"' "${RS}"
    } | LC_ALL=C sort -u
  )"

  # Assert the required identity-bearing objects exist
  local required_objects=(
    "ConfigMap/inf-signalloom-warden/signalloom-warden-config"
    "DaemonSet/inf-signalloom-warden/signalloom-warden"
    "Role/fe-signalloom-agents/signalloom-warden"
    "RoleBinding/fe-signalloom-agents/signalloom-warden"
    "ServiceAccount/inf-signalloom-warden/signalloom-warden"
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
  local all_renders=("${TMP_SWARM}" "${TMP_BASE}" "${TMP_OSRAMP}" "${TMP_HUB}" "${TMP_FE}" "${TMP_FM}")

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

  # 2. RoleBinding roleRef and subjects resolve to Role and SA in base/swarm render
  local rb_role rb_subject role_name
  role_name="$(yq -r 'select(.kind == "Role" and .metadata.name == "signalloom-warden") | .metadata.name' "${TMP_SWARM}" "${TMP_BASE}" | head -n1)"
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

# ── Remote cluster overlays (docs/EAP/remote-contract.md) ────────────────────
#
# A secondary cluster applies remote-tenant with one `kubectl apply -k`, so
# these tests render it as the pilot does, with no --load-restrictor and no
# prior `kubectl apply -f` of anything else. Each test names the single fact it
# pins, because a composite assertion on a whole render tells you the overlay
# is wrong without telling you which parameter is wrong.

# remote_render OVERLAY -> the render path, after asserting it is non-empty.
remote_render() {
  local dir="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/$1"
  local out="${BATS_TEST_TMPDIR}/$1.yaml"
  [ -d "${dir}" ]
  kubectl kustomize "${dir}" >"${out}"
  [ -s "${out}" ]
  printf '%s' "${out}"
}

# env_value NAME FILE -> the literal value of a container env var, empty if it
# has none (a valueFrom ref has no .value, and that reads as empty here).
env_value() {
  yq -r "select(.kind == \"DaemonSet\") | .spec.template.spec.containers[0].env[] | select(.name == \"$1\") | .value // \"\"" "$2" | sed '/^$/d'
}

@test "T5 remote-tenant renders without a load restrictor, so a bare kubectl apply -k works" {
  # No --load-restrictor here on purpose: kustomize refuses a file above the
  # overlay root, so this is the test that stops the Role being referenced as
  # ../../ebpf-sentinel-rbac.yaml and the pilot command growing a flag.
  local out
  out="$(remote_render remote-tenant)"
  yq -r 'select(. != null) | .kind' "${out}" | grep -qx DaemonSet
}

@test "T5 remote-tenant renders the Role, the RoleBinding and the ServiceAccount" {
  local out objs obj
  out="$(remote_render remote-tenant)"
  objs="$(yq -r 'select(. != null) | "\(.kind)/\(.metadata.name)"' "${out}" | LC_ALL=C sort -u)"
  for obj in Role/signalloom-warden RoleBinding/signalloom-warden \
    ServiceAccount/signalloom-warden DaemonSet/signalloom-warden \
    ConfigMap/signalloom-warden-config; do
    echo "${objs}" | grep -qx "${obj}"
  done
}

@test "T5 the overlay Role is the central Role: same rules, so RBAC cannot drift" {
  # role.yaml is a deliberate second copy. This is what makes the copy safe:
  # change the rules in ebpf-sentinel-rbac.yaml without changing the overlay
  # and this test fails.
  local out central overlay
  out="$(remote_render remote-tenant)"
  # -o=json, because the two files write the same rules in different YAML
  # styles (flow sequences in one, block in the other) and a text compare of
  # the YAML would fail on formatting rather than on privilege.
  central="$(yq -o=json -r 'select(.kind == "Role" and .metadata.name == "signalloom-warden" and .metadata.namespace == "fe-signalloom-agents") | .rules' \
    "${SWARM_BASE}/ebpf-sentinel-rbac.yaml")"
  overlay="$(yq -o=json -r 'select(.kind == "Role" and .metadata.name == "signalloom-warden" and .metadata.namespace == "fe-signalloom-agents") | .rules' "${out}")"
  [ -n "${central}" ]
  [ "${overlay}" = "${central}" ]
}

# secret_ref NAME FILE -> "<secret> <optional>" for one env var's secretKeyRef.
#
# The sed strips the blank lines yq emits for every document in the render that
# is not the DaemonSet. Without it the captured value carries leading newlines
# and every comparison against it fails for a reason that has nothing to do
# with the manifest.
secret_ref() {
  yq -r "select(.kind == \"DaemonSet\") | .spec.template.spec.containers[0].env[] | select(.name == \"$1\") | .valueFrom.secretKeyRef.name + \" \" + (.valueFrom.secretKeyRef.optional | tostring)" "$2" | sed '/^$/d'
}

@test "T5 remote-tenant: both key refs are required, so a keyless warden never runs" {
  local out
  out="$(remote_render remote-tenant)"
  # The Secret names are the ones the two minting scripts write, and optional
  # is false because a remote warden with no key freezes pods nobody can see.
  [ "$(secret_ref SIGNAL_INGEST_TOKEN "${out}")" = "signalloom-warden-ingest-token false" ]
  [ "$(secret_ref FLEET_MANAGER_STUN_KEY "${out}")" = "signalloom-warden-fleet-key false" ]
}

@test "T5 remote-tenant: cluster id and the two intervals carry the contract defaults" {
  local out
  out="$(remote_render remote-tenant)"
  [ "$(env_value SIGNAL_CLUSTER_ID "${out}")" = "kusari-prod" ]
  [ "$(env_value FLEET_REPORT_INTERVAL "${out}")" = "60s" ]
  [ "$(env_value FLEET_POLL_INTERVAL "${out}")" = "10s" ]
}

@test "T5 remote-tenant: SIGNAL_TLS_CA_FILE names a path inside the optional hub-ca mount" {
  local out ca mount secret optional
  out="$(remote_render remote-tenant)"
  ca="$(env_value SIGNAL_TLS_CA_FILE "${out}")"
  [ -n "${ca}" ]
  mount="$(yq -r 'select(.kind == "DaemonSet") | .spec.template.spec.containers[0].volumeMounts[] | select(.name == "hub-ca") | .mountPath' "${out}")"
  [ -n "${mount}" ]
  # The variable must point INSIDE the mount, or the bundle is never read.
  case "${ca}" in "${mount}/"*) ;; *) return 1 ;; esac
  secret="$(yq -r 'select(.kind == "DaemonSet") | .spec.template.spec.volumes[] | select(.name == "hub-ca") | .secret.secretName' "${out}")"
  optional="$(yq -r 'select(.kind == "DaemonSet") | .spec.template.spec.volumes[] | select(.name == "hub-ca") | .secret.optional' "${out}")"
  [ "${secret}" = "signalloom-hub-ca" ]
  [ "${optional}" = "true" ]
}

@test "T5 remote-tenant: the tenant map is the PILOT tenant, not the central map" {
  local out map
  out="$(remote_render remote-tenant)"
  map="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "signalloom-warden-config") | .data.SENTINEL_TENANT_MAP' "${out}")"
  [ -n "${map}" ]
  echo "${map}" | grep -q 'fe-signalloom-agents=kusari'
  # The central map's service-account rows must be gone. Inheriting them
  # reports every pilot pod as __unattributed__, which is the defect this
  # overlay exists to prevent.
  run grep -q 'fe-signalloom-agents/kagent-k8s-reader=tenant-demo' <<<"${map}"
  [ "$status" -ne 0 ]
  run grep -q 'fe-signalloom-agents/cpai-engineer=controlplane' <<<"${map}"
  [ "$status" -ne 0 ]
}

@test "T5 remote-tenant: both hub URLs are the gateway prefixes, over HTTPS" {
  local out ingest fleet
  out="$(remote_render remote-tenant)"
  ingest="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "signalloom-warden-config") | .data.SIGNAL_INGEST_URL' "${out}")"
  fleet="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "signalloom-warden-config") | .data.FLEET_MANAGER_URL' "${out}")"
  [ "${ingest}" = "https://dashboard.osramp.acme.local/warden-ingest" ]
  [ "${fleet}" = "https://dashboard.osramp.acme.local/warden-fleet" ]
}

@test "T5 remote-tenant: the public ghcr image, and the tag the catalogue pins" {
  # This cluster has no zot, so the overlay keeps the public reference, and the
  # tag is inherited from the base so a bump is not chased into every overlay.
  local out image catalogued
  out="$(remote_render remote-tenant)"
  image="$(yq -r 'select(.kind == "DaemonSet") | .spec.template.spec.containers[0].image' "${out}")"
  catalogued="$(awk -F'\t' '$1 == "signalloom-warden" {print $4}' "${REPO_ROOT}/test/fixtures/cold-start-manifests.tsv")"
  [ -n "${catalogued}" ]
  [ "${image}" = "${catalogued}" ]
}

@test "T5 remote-tenant: the RBAC exporter CronJob is suspended, not left to fail" {
  local out
  out="$(remote_render remote-tenant)"
  [ "$(yq -r 'select(.kind == "CronJob") | .spec.suspend' "${out}")" = "true" ]
}

@test "T6 remote-tenant-dev sets both development variables, and remote-tenant sets neither" {
  local dev prod
  dev="$(remote_render remote-tenant-dev)"
  prod="$(remote_render remote-tenant)"
  [ "$(env_value SIGNAL_TLS_INSECURE_SKIP_VERIFY "${dev}")" = "true" ]
  # SIGNAL_DEV_MODE is the gate: the warden refuses to start with skip-verify
  # alone, so one without the other is a pod that never runs.
  [ "$(env_value SIGNAL_DEV_MODE "${dev}")" = "true" ]
  [ -z "$(env_value SIGNAL_TLS_INSECURE_SKIP_VERIFY "${prod}")" ]
  [ -z "$(env_value SIGNAL_DEV_MODE "${prod}")" ]
}

@test "T6 remote-tenant-dev changes nothing else: same ids, URLs, keys and objects" {
  local dev prod dev_objs prod_objs
  dev="$(remote_render remote-tenant-dev)"
  prod="$(remote_render remote-tenant)"
  [ "$(env_value SIGNAL_CLUSTER_ID "${dev}")" = "$(env_value SIGNAL_CLUSTER_ID "${prod}")" ]
  [ "$(env_value SIGNAL_TLS_CA_FILE "${dev}")" = "$(env_value SIGNAL_TLS_CA_FILE "${prod}")" ]
  [ "$(env_value FLEET_POLL_INTERVAL "${dev}")" = "$(env_value FLEET_POLL_INTERVAL "${prod}")" ]
  dev_objs="$(yq -r 'select(. != null) | "\(.kind)/\(.metadata.name)"' "${dev}" | LC_ALL=C sort -u)"
  prod_objs="$(yq -r 'select(. != null) | "\(.kind)/\(.metadata.name)"' "${prod}" | LC_ALL=C sort -u)"
  [ "${dev_objs}" = "${prod_objs}" ]
}

@test "T7 the gateway route reaches fleet-manager and names no method" {
  # A PathPrefix match with no `method` forwards GET and POST alike, which is
  # what GET /api/v1/fleet/workloads and GET /api/v1/fleet/stun-state depend
  # on. A rule that named a verb would 404 the others.
  local route fleet_backend methods
  route="${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/base/gateway-route.yaml"
  [ -f "${route}" ]
  fleet_backend="$(yq -r 'select(.kind == "HTTPRoute" and .metadata.name == "signalloom-remote-warden") | .spec.rules[] | select(.matches[0].path.value == "/warden-fleet") | .backendRefs[0].name' "${route}")"
  [ "${fleet_backend}" = "fleet-manager" ]
  methods="$(yq -r 'select(.kind == "HTTPRoute" and .metadata.name == "signalloom-remote-warden") | .spec.rules[].matches[].method // ""' "${route}" | tr -d '\n')"
  [ -z "${methods}" ]
}

@test "T7 fleet-manager admits the gateway and declares the warden caller key" {
  [ -s "${TMP_FM}" ]
  local gw key scopes
  gw="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "fleet-manager") | .spec.ingress[].from[] | select(.namespaceSelector != null) | .namespaceSelector.matchLabels["kubernetes.io/metadata.name"]' "${TMP_FM}" | grep -cx ingress || true)"
  [ "${gw}" -ge 1 ]
  key="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "fleet-manager") | .spec.template.spec.containers[0].env[] | select(.name == "FLEET_MANAGER_KEY_WARDEN") | .valueFrom.secretKeyRef.key' "${TMP_FM}")"
  scopes="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "fleet-manager") | .spec.template.spec.containers[0].env[] | select(.name == "FLEET_MANAGER_KEY_WARDEN_SCOPES") | .value' "${TMP_FM}")"
  [ "${key}" = "warden" ]
  [ "${scopes}" = "report" ]
  # Disjoint from the local warden's scope: one key may not do both jobs.
  [ "${scopes}" != "stun" ]
}

@test "T8 signal-ingest admits the gateway for the /warden-ingest route" {
  local np gw
  np="${REPO_ROOT}/d2-signalloom/apps/signal-ingest/base/networkpolicy.yaml"
  [ -f "${np}" ]
  gw="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-signal-ingest-ingress") | .spec.ingress[].from[] | select(.namespaceSelector != null) | .namespaceSelector.matchLabels["kubernetes.io/metadata.name"]' "${np}" | grep -cx ingress || true)"
  [ "${gw}" -ge 1 ]
}

# ── captures gate: token mount, env, and the stated network policy ───────────

@test "T6 captures: CAPTURES_TOKEN_FILE names a path inside the optional captures-token mount" {
  local out tf mount secret optional
  out="$(remote_render remote-tenant)"
  tf="$(env_value CAPTURES_TOKEN_FILE "${out}")"
  [ -n "${tf}" ]
  mount="$(yq -r 'select(.kind == "DaemonSet") | .spec.template.spec.containers[0].volumeMounts[] | select(.name == "captures-token") | .mountPath' "${out}")"
  [ -n "${mount}" ]
  case "${tf}" in "${mount}/"*) ;; *) return 1 ;; esac
  secret="$(yq -r 'select(.kind == "DaemonSet") | .spec.template.spec.volumes[] | select(.name == "captures-token") | .secret.secretName' "${out}")"
  optional="$(yq -r 'select(.kind == "DaemonSet") | .spec.template.spec.volumes[] | select(.name == "captures-token") | .secret.optional' "${out}")"
  [ "${secret}" = "signalloom-warden-captures-token" ]
  [ "${optional}" = "true" ]
}

@test "T6 captures: the base ships an ingress NetworkPolicy for the health listener, reader-labelled pods only" {
  local out name port label
  out="$(remote_render remote-tenant-dev)"
  name="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "signalloom-warden-captures") | .metadata.name' "${out}")"
  [ "${name}" = "signalloom-warden-captures" ]
  port="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "signalloom-warden-captures") | .spec.ingress[0].ports[0].port' "${out}")"
  [ "${port}" = "8081" ]
  label="$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "signalloom-warden-captures") | .spec.ingress[0].from[0].podSelector.matchLabels["signalloom.ai/captures-reader"]' "${out}")"
  [ "${label}" = "true" ]
  # Ingress-only, and it selects the warden pods and nothing wider.
  [ "$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "signalloom-warden-captures") | .spec.policyTypes | join(",")' "${out}")" = "Ingress" ]
  [ "$(yq -r 'select(.kind == "NetworkPolicy" and .metadata.name == "signalloom-warden-captures") | .spec.podSelector.matchLabels["app.kubernetes.io/name"]' "${out}")" = "signalloom-warden" ]
}
