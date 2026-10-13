#!/usr/bin/env bats
# ==============================================================================
# test/slsi-upgrade-rollback.bats — SLSI-P3-2 Day-2 Upgrade & Rollback Verification
# ==============================================================================

setup() {
  TEST_DIR="$(mktemp -d /tmp/slsi-test-XXXXXX)"
  TENANT_ID="tenant-$(date +%s)-$RANDOM"
  OUTPUT_DIR="${TEST_DIR}/${TENANT_ID}"
}

teardown() {
  if [[ -n "${TEST_DIR:-}" && -d "${TEST_DIR}" ]]; then
    rm -rf "${TEST_DIR}"
  fi
  rm -f "/tmp/osramp-${TENANT_ID}.kubeconfig" "/tmp/osramp.kubeconfig"
}

@test "init-tenant.sh stage p2-2 initializes snapshot storage directory with mode 0700" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --stage p2-2

  [ "$status" -eq 0 ]
  [ -d "${OUTPUT_DIR}/snapshots" ]

  local mode
  mode="$(stat -c '%a' "${OUTPUT_DIR}/snapshots")"
  [ "$mode" -eq 700 ]
}

@test "upgrade-tenant.sh creates atomic pre-upgrade snapshot and preserves persistent data" {
  mkdir -p "${OUTPUT_DIR}/data/postgres" "${OUTPUT_DIR}/data/openbao" "${OUTPUT_DIR}/keys"
  echo "record-v1-initial" > "${OUTPUT_DIR}/data/postgres/data.txt"
  echo "secret-v1-token" > "${OUTPUT_DIR}/data/openbao/secret.txt"
  echo "key-v1-material" > "${OUTPUT_DIR}/keys/cosign.pub"

  run ./scripts/upgrade-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --skip-image-reload

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Day-2 In-Place Upgrade Complete" ]]

  # Check that snapshot directory exists and has mode 0700
  [ -d "${OUTPUT_DIR}/snapshots" ]
  local snapshot_subdirs
  snapshot_subdirs=( "${OUTPUT_DIR}/snapshots/"* )
  [ "${#snapshot_subdirs[@]}" -ge 1 ]

  local latest_snap="${snapshot_subdirs[0]}"
  [ -d "$latest_snap" ]

  local snap_mode
  snap_mode="$(stat -c '%a' "$latest_snap")"
  [ "$snap_mode" -eq 700 ]

  # Check manifest.json
  [ -f "${latest_snap}/manifest.json" ]
  grep -q '"postgres_preserved": true' "${latest_snap}/manifest.json"
  grep -q '"openbao_preserved": true' "${latest_snap}/manifest.json"
  grep -q '"keys_preserved": true' "${latest_snap}/manifest.json"

  # Verify contents match original data
  [ -f "${latest_snap}/postgres/data.txt" ]
  [ "$(cat "${latest_snap}/postgres/data.txt")" = "record-v1-initial" ]

  [ -f "${latest_snap}/openbao/secret.txt" ]
  [ "$(cat "${latest_snap}/openbao/secret.txt")" = "secret-v1-token" ]

  # Check success report
  [ -f "${latest_snap}/upgrade-success.json" ]
  grep -q '"status": "upgraded"' "${latest_snap}/upgrade-success.json"
}

@test "upgrade-tenant.sh automated rollback triggers on health failure and restores data" {
  mkdir -p "${OUTPUT_DIR}/data/postgres" "${OUTPUT_DIR}/data/openbao" "${OUTPUT_DIR}/keys"
  echo "golden-record-must-survive" > "${OUTPUT_DIR}/data/postgres/data.txt"
  echo "golden-secret-must-survive" > "${OUTPUT_DIR}/data/openbao/secret.txt"

  run ./scripts/upgrade-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --skip-image-reload \
    --fail-health-check

  # Should fail with non-zero exit code
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Initiating automated rollback" ]]
  [[ "$output" =~ "Rollback successfully completed" ]]

  # Check that original data volumes were restored
  [ -f "${OUTPUT_DIR}/data/postgres/data.txt" ]
  [ "$(cat "${OUTPUT_DIR}/data/postgres/data.txt")" = "golden-record-must-survive" ]

  [ -f "${OUTPUT_DIR}/data/openbao/secret.txt" ]
  [ "$(cat "${OUTPUT_DIR}/data/openbao/secret.txt")" = "golden-secret-must-survive" ]

  # Check rollback report
  local snapshot_subdirs=( "${OUTPUT_DIR}/snapshots/"* )
  local latest_snap="${snapshot_subdirs[0]}"
  [ -f "${latest_snap}/rollback-report.json" ]
  grep -q '"status": "rolled_back"' "${latest_snap}/rollback-report.json"
  grep -q '"reason": "health_probe_failure"' "${latest_snap}/rollback-report.json"
}

@test "upgrade-tenant.sh rejects missing tenant-id argument" {
  run ./scripts/upgrade-tenant.sh

  [ "$status" -ne 0 ]
  [[ "$output" =~ "ERROR: --tenant-id is required" ]]
}

@test "upgrade-tenant.sh dry-run creates snapshot without executing mutating cluster changes" {
  mkdir -p "${OUTPUT_DIR}/data/postgres"
  echo "dryrun-test-data" > "${OUTPUT_DIR}/data/postgres/data.txt"

  run ./scripts/upgrade-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --skip-image-reload \
    --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Dry-run mode: skipping cluster manifest mutation" ]]

  # Verify snapshot was created
  local snapshot_subdirs=( "${OUTPUT_DIR}/snapshots/"* )
  local latest_snap="${snapshot_subdirs[0]}"
  [ -d "$latest_snap" ]
  [ "$(cat "${latest_snap}/postgres/data.txt")" = "dryrun-test-data" ]
}

@test "upgrade-tenant.sh enforces strict file permissions (0700 snapshot dir, 0600 report)" {
  mkdir -p "${OUTPUT_DIR}/data/postgres"
  echo "perms-test" > "${OUTPUT_DIR}/data/postgres/data.txt"

  run ./scripts/upgrade-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --skip-image-reload

  [ "$status" -eq 0 ]

  local snapshot_subdirs=( "${OUTPUT_DIR}/snapshots/"* )
  local latest_snap="${snapshot_subdirs[0]}"

  local snap_dir_mode
  snap_dir_mode="$(stat -c '%a' "$latest_snap")"
  [ "$snap_dir_mode" -eq 700 ]

  local manifest_mode
  manifest_mode="$(stat -c '%a' "${latest_snap}/manifest.json")"
  [ "$manifest_mode" -eq 600 ]

  local success_mode
  success_mode="$(stat -c '%a' "${latest_snap}/upgrade-success.json")"
  [ "$success_mode" -eq 600 ]
}
