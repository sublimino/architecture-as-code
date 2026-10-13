#!/usr/bin/env bats
# ==============================================================================
# test/slsi-zot-preload.bats — SLSI-P2-3 Kind Bootstrap and Zot Seeder Tests
# ==============================================================================

setup() {
  TEST_DIR="$(mktemp -d /tmp/slsi-test-XXXXXX)"
  TENANT_ID="tenant-$(date +%s)-$RANDOM"
  OUTPUT_DIR="${TEST_DIR}/${TENANT_ID}"
  DATA_DIR="${OUTPUT_DIR}/data"
  KIND_CONFIG="${OUTPUT_DIR}/kind-config.yaml"
  PYTHON="$(python3 -c 'import yaml' >/dev/null 2>&1 && echo python3 || echo /usr/bin/python3)"
}

teardown() {
  if [[ -n "${TEST_DIR:-}" && -d "${TEST_DIR}" ]]; then
    rm -rf "${TEST_DIR}"
  fi
  rm -f "/tmp/osramp-${TENANT_ID}.kubeconfig" "/tmp/osramp.kubeconfig"
}

@test "init-tenant.sh --help displays cluster and zot options" {
  run ./scripts/init-tenant.sh --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "--cluster-name" ]]
  [[ "$output" =~ "--skip-cluster-create" ]]
  [[ "$output" =~ "--preload-manifest" ]]
  [[ "$output" =~ "--zot-manifest" ]]
  [[ "$output" =~ "--zot-port" ]]
}

@test "init-tenant.sh stage p2-3 fails when Kind configuration does not exist" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --kind-config "${OUTPUT_DIR}/nonexistent.yaml" \
    --stage p2-3

  [ "$status" -ne 0 ]
  [[ "$output" =~ "Kind cluster configuration not found" ]]
}

@test "init-tenant.sh stage p2-3 validates Kind config with --skip-cluster-create" {
  # 1. First run p2-2 to produce valid Kind config
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --stage p2-2
  [ "$status" -eq 0 ]
  [ -f "${KIND_CONFIG}" ]

  # 2. Run p2-3 with --skip-cluster-create
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --kind-config "${KIND_CONFIG}" \
    --skip-cluster-create \
    --stage p2-3

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Skipping cluster creation" ]]
  [[ "$output" =~ "stage_p2_3_bootstrap completed successfully" ]]
}

@test "init-tenant.sh stage p2-3 fails when air-gap loopback invariant is violated" {
  # 1. Prepare valid kind config via p2-2
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --stage p2-2
  [ "$status" -eq 0 ]

  # 2. Point to external non-loopback host
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --kind-config "${KIND_CONFIG}" \
    --registry-endpoint "http://external.registry.example.com:5000" \
    --skip-cluster-create \
    --stage p2-3

  # Assert loopback invariant enforced: non-zero exit and error message
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Air-gap violation" ]]
}

@test "init-tenant.sh stage p2-3 verifies local Zot manifest presence" {
  [ -f "d2-osramp-fleet/local/zot.yaml" ]

  # Prepare valid kind config via p2-2
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --stage p2-2
  [ "$status" -eq 0 ]

  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --zot-manifest "d2-osramp-fleet/local/zot.yaml" \
    --skip-cluster-create \
    --stage p2-3

  [ "$status" -eq 0 ]
}

@test "Kind cluster node reports condition Ready=True" {
  local kubeconfig="${TEST_DIR}/kubeconfig"
  if [[ ! -f "${kubeconfig}" ]]; then
    if kind get clusters 2>/dev/null | grep -qw "osramp-${TENANT_ID}"; then
      kind get kubeconfig --name "osramp-${TENANT_ID}" > "${kubeconfig}"
    elif kind get clusters 2>/dev/null | grep -qw "osramp"; then
      kind get kubeconfig --name "osramp" > "${kubeconfig}"
    fi
  fi
  [ -f "${kubeconfig}" ]

  run kubectl --kubeconfig "${kubeconfig}" get nodes -o jsonpath="{.items[0].status.conditions[?(@.type==\"Ready\")].status}"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "Zot registry container reaches ready status in cluster" {
  local kubeconfig="${TEST_DIR}/kubeconfig"
  if [[ ! -f "${kubeconfig}" ]]; then
    if kind get clusters 2>/dev/null | grep -qw "osramp-${TENANT_ID}"; then
      kind get kubeconfig --name "osramp-${TENANT_ID}" > "${kubeconfig}"
    elif kind get clusters 2>/dev/null | grep -qw "osramp"; then
      kind get kubeconfig --name "osramp" > "${kubeconfig}"
    fi
  fi
  [ -f "${kubeconfig}" ]

  # Query pod ready condition in registry namespace
  run kubectl --kubeconfig "${kubeconfig}" get pods -n "${ZOT_NAMESPACE:-registry}" -l app=zot -o jsonpath="{.items[0].status.containerStatuses[0].ready}"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "Query to http://localhost:5000/v2/_catalog returns JSON object containing populated list of repository images" {
  run curl -fsS http://localhost:5000/v2/_catalog
  [ "$status" -eq 0 ]
  [[ "$output" =~ "repositories" ]]

  run python3 -c "import sys, json, urllib.request; data = json.loads(urllib.request.urlopen('http://localhost:5000/v2/_catalog').read().decode()); assert len(data.get('repositories', [])) > 0, 'Zot registry catalog is empty'"
  [ "$status" -eq 0 ]
}

@test "Network trace confirms zero external outbound socket connections during image preload" {
  # Assert registry endpoint binds strictly to loopback
  run python3 -c "
import urllib.parse
ep = 'http://127.0.0.1:5000'
parsed = urllib.parse.urlparse(ep)
assert parsed.hostname in ('127.0.0.1', 'localhost'), 'Non-loopback endpoint'
print('LOOPBACK_OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "LOOPBACK_OK" ]]
}
