#!/usr/bin/env bats
# ==============================================================================
# test/slsi-tenant-keys.bats — SLSI-P2-1 Tenant Cryptographic Bootstrap Tests
# ==============================================================================

setup() {
  TEST_DIR="$(mktemp -d)"
  TENANT_A="tenant-$(date +%s)-a"
  TENANT_B="tenant-$(date +%s)-b"
  PASSPHRASE="test-passphrase-$(date +%s)"
}

teardown() {
  if [[ -n "${TEST_DIR:-}" && -d "${TEST_DIR}" ]]; then
    rm -rf "${TEST_DIR}"
  fi
}

@test "init-tenant.sh --help displays usage" {
  run ./scripts/init-tenant.sh --help
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Usage:" ]]
  [[ "$output" =~ "--tenant-id" ]]
}

@test "init-tenant.sh fails when --tenant-id is missing" {
  run ./scripts/init-tenant.sh --output-dir "${TEST_DIR}/dummy"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "--tenant-id is required" ]]
}

@test "init-tenant.sh fails when --escrow-passphrase is missing" {
  run ./scripts/init-tenant.sh --tenant-id "${TENANT_A}" --output-dir "${TEST_DIR}/${TENANT_A}"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Escrow passphrase is required" ]]
}

@test "init-tenant.sh creates keys directory with mode 0700" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_A}" \
    --output-dir "${TEST_DIR}/${TENANT_A}" \
    --escrow-passphrase "${PASSPHRASE}"
  [ "$status" -eq 0 ]

  local mode
  mode="$(stat -c '%a' "${TEST_DIR}/${TENANT_A}/keys")"
  [ "$mode" = "700" ]
}

@test "init-tenant.sh generates Cosign ECDSA P-256 keypair with mode 0600 and 0644" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_A}" \
    --output-dir "${TEST_DIR}/${TENANT_A}" \
    --escrow-passphrase "${PASSPHRASE}"
  [ "$status" -eq 0 ]

  local key_path="${TEST_DIR}/${TENANT_A}/keys/cosign.key"
  local pub_path="${TEST_DIR}/${TENANT_A}/keys/cosign.pub"

  [ -f "${key_path}" ]
  [ -f "${pub_path}" ]

  [ "$(stat -c '%a' "${key_path}")" = "600" ]
  [ "$(stat -c '%a' "${pub_path}")" = "644" ]

  run openssl pkey -pubin -in "${pub_path}" -text -noout
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Public-Key: (256 bit)" ]] || [[ "$output" =~ "prime256v1" ]] || [[ "$output" =~ "P-256" ]]
}

@test "init-tenant.sh generates Witness Ed25519 keypair with mode 0600 and 0644" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_A}" \
    --output-dir "${TEST_DIR}/${TENANT_A}" \
    --escrow-passphrase "${PASSPHRASE}"
  [ "$status" -eq 0 ]

  local key_path="${TEST_DIR}/${TENANT_A}/keys/witness.pem"
  local pub_path="${TEST_DIR}/${TENANT_A}/keys/witness-pub.pem"

  [ -f "${key_path}" ]
  [ -f "${pub_path}" ]
  [ -f "${TEST_DIR}/${TENANT_A}/keys/witness-key.pem" ]

  [ "$(stat -c '%a' "${key_path}")" = "600" ]
  [ "$(stat -c '%a' "${pub_path}")" = "644" ]

  run openssl pkey -pubin -in "${pub_path}" -text -noout
  [ "$status" -eq 0 ]
  [[ "$output" =~ "ED25519" ]]
}

@test "init-tenant.sh generates Orbit approval Ed25519 keypair with mode 0600 and 0644" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_A}" \
    --output-dir "${TEST_DIR}/${TENANT_A}" \
    --escrow-passphrase "${PASSPHRASE}"
  [ "$status" -eq 0 ]

  local key_path="${TEST_DIR}/${TENANT_A}/keys/orbit-approval.pem"
  local pub_path="${TEST_DIR}/${TENANT_A}/keys/orbit-approval-pub.pem"

  [ -f "${key_path}" ]
  [ -f "${pub_path}" ]
  [ -f "${TEST_DIR}/${TENANT_A}/keys/orbit-approval.key" ]

  [ "$(stat -c '%a' "${key_path}")" = "600" ]
  [ "$(stat -c '%a' "${pub_path}")" = "644" ]

  run openssl pkey -pubin -in "${pub_path}" -text -noout
  [ "$status" -eq 0 ]
  [[ "$output" =~ "ED25519" ]]
}

@test "init-tenant.sh generates signing-config.json and segment-signing-policy.json" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_A}" \
    --output-dir "${TEST_DIR}/${TENANT_A}" \
    --escrow-passphrase "${PASSPHRASE}"
  [ "$status" -eq 0 ]

  local sc="${TEST_DIR}/${TENANT_A}/keys/signing-config.json"
  local sp="${TEST_DIR}/${TENANT_A}/keys/segment-signing-policy.json"

  [ -f "${sc}" ]
  [ -f "${sp}" ]
  [ "$(stat -c '%a' "${sc}")" = "644" ]
  [ "$(stat -c '%a' "${sp}")" = "644" ]

  # Validate signing-config.json JSON schema
  run jq -e '.mediaType == "application/vnd.dev.sigstore.signingconfig.v0.2+json"' "${sc}"
  [ "$status" -eq 0 ]

  # Validate segment-signing-policy.json carries expected_key_ids matching witness public key
  run jq -er '.expected_key_ids[0]' "${sp}"
  [ "$status" -eq 0 ]
  local key_id="$output"
  [ -n "$key_id" ]

  local expected_id
  expected_id="$(openssl pkey -pubin -in "${TEST_DIR}/${TENANT_A}/keys/witness-pub.pem" -outform DER | sha256sum | awk '{print $1}')"
  [ "$key_id" = "$expected_id" ]
}

@test "init-tenant.sh packages encrypted escrow bundle with mode 0600" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_A}" \
    --output-dir "${TEST_DIR}/${TENANT_A}" \
    --escrow-passphrase "${PASSPHRASE}"
  [ "$status" -eq 0 ]

  local escrow="${TEST_DIR}/${TENANT_A}/${TENANT_A}-escrow.tar.enc"
  [ -f "${escrow}" ]
  [ "$(stat -c '%a' "${escrow}")" = "600" ]

  # Decrypt and verify payload
  local restore_dir="${TEST_DIR}/restored"
  mkdir -p "${restore_dir}"

  run bash -c "openssl enc -d -aes-256-cbc -pbkdf2 -in '${escrow}' -pass 'pass:${PASSPHRASE}' | tar -C '${restore_dir}' -xf -"
  [ "$status" -eq 0 ]

  cmp "${TEST_DIR}/${TENANT_A}/keys/cosign.key" "${restore_dir}/cosign.key"
  cmp "${TEST_DIR}/${TENANT_A}/keys/witness.pem" "${restore_dir}/witness.pem"
  cmp "${TEST_DIR}/${TENANT_A}/keys/orbit-approval.pem" "${restore_dir}/orbit-approval.pem"
}

@test "init-tenant.sh generates disjoint keys across different tenants" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_A}" \
    --output-dir "${TEST_DIR}/${TENANT_A}" \
    --escrow-passphrase "${PASSPHRASE}"
  [ "$status" -eq 0 ]

  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_B}" \
    --output-dir "${TEST_DIR}/${TENANT_B}" \
    --escrow-passphrase "${PASSPHRASE}"
  [ "$status" -eq 0 ]

  # Cosign public keys must differ
  run diff -u "${TEST_DIR}/${TENANT_A}/keys/cosign.pub" "${TEST_DIR}/${TENANT_B}/keys/cosign.pub"
  [ "$status" -ne 0 ]

  # Witness public keys must differ
  run diff -u "${TEST_DIR}/${TENANT_A}/keys/witness-pub.pem" "${TEST_DIR}/${TENANT_B}/keys/witness-pub.pem"
  [ "$status" -ne 0 ]

  # Orbit approval public keys must differ
  run diff -u "${TEST_DIR}/${TENANT_A}/keys/orbit-approval-pub.pem" "${TEST_DIR}/${TENANT_B}/keys/orbit-approval-pub.pem"
  [ "$status" -ne 0 ]

  # Derived segment policy key IDs must differ
  local id_a id_b
  id_a="$(jq -r '.expected_key_ids[0]' "${TEST_DIR}/${TENANT_A}/keys/segment-signing-policy.json")"
  id_b="$(jq -r '.expected_key_ids[0]' "${TEST_DIR}/${TENANT_B}/keys/segment-signing-policy.json")"
  [ "$id_a" != "$id_b" ]
}

@test "init-tenant.sh fails when keys already exist and --force is not given" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_A}" \
    --output-dir "${TEST_DIR}/${TENANT_A}" \
    --escrow-passphrase "${PASSPHRASE}"
  [ "$status" -eq 0 ]

  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_A}" \
    --output-dir "${TEST_DIR}/${TENANT_A}" \
    --escrow-passphrase "${PASSPHRASE}"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Cryptographic keys already exist" ]]

  # With --force it succeeds
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_A}" \
    --output-dir "${TEST_DIR}/${TENANT_A}" \
    --escrow-passphrase "${PASSPHRASE}" \
    --force
  [ "$status" -eq 0 ]
}
