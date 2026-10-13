#!/usr/bin/env bats
# ==============================================================================
# test/slsi-diagnostics-bundler.bats — SLSI-P3-3 Diagnostics Bundler & Egress Tests
# ==============================================================================

setup() {
  TEST_DIR="$(mktemp -d)"
  TENANT_ID="tenant-$(date +%s)-$RANDOM"
  OUTPUT_DIR="${TEST_DIR}/${TENANT_ID}"
  PASSPHRASE="test-passphrase-$(date +%s)"
}

teardown() {
  if [[ -n "${TEST_DIR:-}" && -d "${TEST_DIR}" ]]; then
    rm -rf "${TEST_DIR}"
  fi
}

@test "export-diagnostics.sh creates encrypted archive with mode 0600" {
  mkdir -p "${OUTPUT_DIR}/audit/witness" "${OUTPUT_DIR}/data/openbao" "${OUTPUT_DIR}/data/frostdb"
  echo '{"test": "witness-attestation"}' > "${OUTPUT_DIR}/audit/witness/attestation.json"
  echo '{"type": "audit-log-line"}' > "${OUTPUT_DIR}/data/openbao/audit.log"
  echo 'frostdb-segment-data' > "${OUTPUT_DIR}/data/frostdb/seg-001.bin"

  run ./scripts/export-diagnostics.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --passphrase "${PASSPHRASE}"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Diagnostics Packaging Complete" ]]

  local enc_files=( "${OUTPUT_DIR}/audit/diagnostics-"*".tar.enc" )
  [ "${#enc_files[@]}" -ge 1 ]

  local archive="${enc_files[0]}"
  [ -f "$archive" ]

  local mode
  mode="$(stat -c '%a' "$archive")"
  [ "$mode" -eq 600 ]

  local sha_files=( "${OUTPUT_DIR}/audit/diagnostics-"*".sha256" )
  [ "${#sha_files[@]}" -ge 1 ]
  local sha_mode
  sha_mode="$(stat -c '%a' "${sha_files[0]}")"
  [ "$sha_mode" -eq 600 ]
}

@test "encrypted archive decrypts successfully and verifies content integrity" {
  mkdir -p "${OUTPUT_DIR}/audit/witness" "${OUTPUT_DIR}/data/openbao"
  echo "original-witness-data-for-decryption" > "${OUTPUT_DIR}/audit/witness/attestation.json"
  echo "original-openbao-log-for-decryption" > "${OUTPUT_DIR}/data/openbao/audit.log"

  run ./scripts/export-diagnostics.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --passphrase "${PASSPHRASE}"

  [ "$status" -eq 0 ]

  local enc_files=( "${OUTPUT_DIR}/audit/diagnostics-"*".tar.enc" )
  local archive="${enc_files[0]}"

  # Decrypt archive
  local dec_tar="${TEST_DIR}/decrypted.tar.gz"
  openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 100000 \
    -in "$archive" \
    -out "$dec_tar" \
    -pass "pass:${PASSPHRASE}"

  [ -f "$dec_tar" ]

  # Extract tarball
  local extract_dir="${TEST_DIR}/extracted"
  mkdir -p "$extract_dir"
  tar -xzf "$dec_tar" -C "$extract_dir"

  # Verify manifest
  [ -f "${extract_dir}/diagnostics-manifest.json" ]
  grep -q "\"tenant_id\": \"${TENANT_ID}\"" "${extract_dir}/diagnostics-manifest.json"

  # Verify extracted content matches source exactly
  [ -f "${extract_dir}/witness/attestation.json" ]
  [ "$(cat "${extract_dir}/witness/attestation.json")" = "original-witness-data-for-decryption" ]

  [ -f "${extract_dir}/openbao/audit.log" ]
  [ "$(cat "${extract_dir}/openbao/audit.log")" = "original-openbao-log-for-decryption" ]
}

@test "export-diagnostics.sh enforces zero network egress by default" {
  mkdir -p "${OUTPUT_DIR}/audit"

  run ./scripts/export-diagnostics.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --passphrase "${PASSPHRASE}"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Default air-gap egress policy: ZERO network packets transmitted" ]]
  [[ "$output" =~ "Outbound streaming is disabled" ]]
}

@test "export-diagnostics.sh attempts hub transmission only when endpoint and token are provided" {
  mkdir -p "${OUTPUT_DIR}/audit"

  run ./scripts/export-diagnostics.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --passphrase "${PASSPHRASE}" \
    --hub-endpoint "http://127.0.0.1:59999" \
    --hub-token "mock-hub-token"

  # Should output transmission message (curl may warn/fail gracefully)
  [[ "$output" =~ "Transmitting diagnostics bundle to Signal Loom Hub" ]]
}

@test "export-diagnostics.sh rejects missing tenant-id" {
  run ./scripts/export-diagnostics.sh

  [ "$status" -ne 0 ]
  [[ "$output" =~ "ERROR: --tenant-id is required" ]]
}

@test "export-diagnostics.sh dry-run validates sources without generating final archive" {
  mkdir -p "${OUTPUT_DIR}/audit"

  run ./scripts/export-diagnostics.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Dry-run mode: skipping packaging and encryption" ]]

  local enc_files
  enc_files=( "${OUTPUT_DIR}/audit/diagnostics-"*".tar.enc" )
  [ ! -e "${enc_files[0]}" ]
}
