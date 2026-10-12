#!/usr/bin/env bats
# ==============================================================================
# test/slsi-host-mounts.bats — SLSI-P2-2 Host Persistence & Kind Config Tests
# ==============================================================================

setup() {
  TEST_DIR="$(mktemp -d)"
  TENANT_ID="tenant-$(date +%s)-$RANDOM"
  OUTPUT_DIR="${TEST_DIR}/${TENANT_ID}"
  DATA_DIR="${OUTPUT_DIR}/data"
  KIND_CONFIG="${OUTPUT_DIR}/kind-config.yaml"
}

teardown() {
  if [[ -n "${TEST_DIR:-}" && -d "${TEST_DIR}" ]]; then
    rm -rf "${TEST_DIR}"
  fi
}

@test "init-tenant.sh stage p2-2 initializes host directories with mode 0700" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --stage p2-2

  [ "$status" -eq 0 ]
  [ -d "${DATA_DIR}" ]
  [ "$(stat -c '%a' "${DATA_DIR}")" = "700" ]

  [ -d "${DATA_DIR}/postgres" ]
  [ "$(stat -c '%a' "${DATA_DIR}/postgres")" = "700" ]

  [ -d "${DATA_DIR}/openbao" ]
  [ "$(stat -c '%a' "${DATA_DIR}/openbao")" = "700" ]

  [ -d "${DATA_DIR}/zot" ]
  [ "$(stat -c '%a' "${DATA_DIR}/zot")" = "700" ]

  [ -d "${DATA_DIR}/frostdb" ]
  [ "$(stat -c '%a' "${DATA_DIR}/frostdb")" = "700" ]

  # Strict constraint: NO nats directory created
  [ ! -d "${DATA_DIR}/nats" ]
}

@test "init-tenant.sh stage p2-2 enforces measured container UIDs under fakeroot" {
  run fakeroot bash -c "
    ./scripts/init-tenant.sh --tenant-id '${TENANT_ID}' --output-dir '${OUTPUT_DIR}' --stage p2-2 || exit 1
    echo \"PG=\$(stat -c '%u:%g' '${DATA_DIR}/postgres')\"
    echo \"BAO=\$(stat -c '%u:%g' '${DATA_DIR}/openbao')\"
    echo \"ZOT=\$(stat -c '%u:%g' '${DATA_DIR}/zot')\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "PG=999:999" ]]
  [[ "$output" =~ "BAO=100:1000" ]]
  [[ "$output" =~ "ZOT=65532:65532" ]]
}

@test "init-tenant.sh stage p2-2 writes ownership.json recording measured workloads" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --stage p2-2

  [ "$status" -eq 0 ]
  local record="${DATA_DIR}/ownership.json"
  [ -f "${record}" ]
  [ "$(stat -c '%a' "${record}")" = "644" ]

  run jq -er '.schema_version' "${record}"
  [ "$status" -eq 0 ]
  [ "$output" = "slsi.host-persistence/v1" ]

  run jq -er '.tenant_id' "${record}"
  [ "$status" -eq 0 ]
  [ "$output" = "${TENANT_ID}" ]

  # Workloads
  [ "$(jq -r '.workloads.postgres.uid' "${record}")" = "999" ]
  [ "$(jq -r '.workloads.postgres.gid' "${record}")" = "999" ]
  [[ "$(jq -r '.workloads.postgres.workload' "${record}")" =~ "postgres" ]]

  [ "$(jq -r '.workloads.openbao.uid' "${record}")" = "100" ]
  [ "$(jq -r '.workloads.openbao.gid' "${record}")" = "1000" ]
  [[ "$(jq -r '.workloads.openbao.workload' "${record}")" =~ "openbao" ]]

  [ "$(jq -r '.workloads.zot.uid' "${record}")" = "65532" ]
  [ "$(jq -r '.workloads.zot.gid' "${record}")" = "65532" ]
  [[ "$(jq -r '.workloads.zot.workload' "${record}")" =~ "zot" ]]
}

@test "init-tenant.sh stage p2-2 generates valid Kind cluster YAML configuration" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --stage p2-2

  [ "$status" -eq 0 ]
  [ -f "${KIND_CONFIG}" ]
  [ "$(stat -c '%a' "${KIND_CONFIG}")" = "644" ]

  # Python YAML parser validation
  run python3 -c "import yaml; d = yaml.safe_load(open('${KIND_CONFIG}')); assert d['kind'] == 'Cluster'"
  [ "$status" -eq 0 ]

  # Assert cluster name
  run python3 -c "import yaml; d = yaml.safe_load(open('${KIND_CONFIG}')); print(d['name'])"
  [ "$status" -eq 0 ]
  [ "$output" = "kind-${TENANT_ID}" ]

  # Assert kubeadmConfigPatches contains nodeStatusMaxImages: -1
  run python3 -c "import yaml; d = yaml.safe_load(open('${KIND_CONFIG}')); print(d['kubeadmConfigPatches'][0])"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "nodeStatusMaxImages: -1" ]]

  # Assert extraPortMappings (80, 443 TCP)
  run python3 -c "
import yaml
d = yaml.safe_load(open('${KIND_CONFIG}'))
ports = d['nodes'][0]['extraPortMappings']
ports_dict = {p['containerPort']: (p['hostPort'], p['protocol']) for p in ports}
assert 80 in ports_dict and ports_dict[80] == (80, 'TCP'), f'port 80 missing or invalid: {ports_dict}'
assert 443 in ports_dict and ports_dict[443] == (443, 'TCP'), f'port 443 missing or invalid: {ports_dict}'
print(f'PORTS_OK: {len(ports)}')
"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PORTS_OK: 2" ]]

  # Assert extraMounts paths and readOnly properties
  run python3 -c "
import yaml
d = yaml.safe_load(open('${KIND_CONFIG}'))
mounts = d['nodes'][0]['extraMounts']
mount_map = {m['containerPath']: m for m in mounts}

# Storage mounts
assert '/var/local/osramp-zot-cache' in mount_map
assert mount_map['/var/local/osramp-zot-cache']['hostPath'] == '${DATA_DIR}/zot'

assert '/var/local/signalloom-postgres-data' in mount_map
assert mount_map['/var/local/signalloom-postgres-data']['hostPath'] == '${DATA_DIR}/postgres'

assert '/var/local/signalloom-openbao-data' in mount_map
assert mount_map['/var/local/signalloom-openbao-data']['hostPath'] == '${DATA_DIR}/openbao'

# Kernel mounts (must be readOnly: True)
assert '/lib/modules' in mount_map
assert mount_map['/lib/modules']['hostPath'] == '/lib/modules'
assert mount_map['/lib/modules'].get('readOnly') is True

assert '/sys/kernel/btf' in mount_map
assert mount_map['/sys/kernel/btf']['hostPath'] == '/sys/kernel/btf'
assert mount_map['/sys/kernel/btf'].get('readOnly') is True

# Explicit constraint: NO /sys/fs/cgroup mount
assert '/sys/fs/cgroup' not in mount_map

print(f'MOUNTS_OK: {len(mounts)}')
"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "MOUNTS_OK: 5" ]]
}

@test "init-tenant.sh stage p2-2 performs GH-8 legacy cache migration" {
  local mock_legacy_zot="${TEST_DIR}/legacy_zot"
  local mock_legacy_pg="${TEST_DIR}/legacy_pg"
  mkdir -p "${mock_legacy_zot}/v2" "${mock_legacy_pg}/base"
  echo "mock-zot-blob-data" > "${mock_legacy_zot}/v2/blob.txt"
  echo "mock-pg-table-data" > "${mock_legacy_pg}/base/table.txt"

  run fakeroot bash -c "
    ./scripts/init-tenant.sh \
      --tenant-id '${TENANT_ID}' \
      --output-dir '${OUTPUT_DIR}' \
      --legacy-zot-dir '${mock_legacy_zot}' \
      --legacy-postgres-dir '${mock_legacy_pg}' \
      --assert-migrated \
      --stage p2-2 || exit 1

    echo \"ZOT_FILE=\$(stat -c '%u:%g' '${DATA_DIR}/zot/v2/blob.txt')\"
    echo \"PG_FILE=\$(stat -c '%u:%g' '${DATA_DIR}/postgres/base/table.txt')\"
  "

  [ "$status" -eq 0 ]
  [ -f "${DATA_DIR}/zot/v2/blob.txt" ]
  [ "$(< "${DATA_DIR}/zot/v2/blob.txt")" = "mock-zot-blob-data" ]

  [ -f "${DATA_DIR}/postgres/base/table.txt" ]
  [ "$(< "${DATA_DIR}/postgres/base/table.txt")" = "mock-pg-table-data" ]

  [[ "$output" =~ "ZOT_FILE=65532:65532" ]]
  [[ "$output" =~ "PG_FILE=999:999" ]]
}

@test "init-tenant.sh stage p2-2 fails when --assert-migrated is requested but legacy dir is empty" {
  local empty_legacy="${TEST_DIR}/empty_legacy"
  mkdir -p "${empty_legacy}"

  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --legacy-zot-dir "${empty_legacy}" \
    --assert-migrated \
    --stage p2-2

  [ "$status" -ne 0 ]
  [[ "$output" =~ "Migration assertion failed" ]]
}

@test "init-tenant.sh stage p2-2 rejects YAML control characters in DATA_DIR" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --data-dir "/tmp/test:unsafe[dir]" \
    --stage p2-2

  [ "$status" -ne 0 ]
  [[ "$output" =~ "contains YAML control characters" ]]
}
