#!/usr/bin/env bats
# ==============================================================================
# test/slsi-dual-trust.bats — SLSI-P2-3 and P2-4 Dual-Trust & Cluster Bootstrap Tests
# ==============================================================================

setup() {
  TEST_DIR="$(mktemp -d /tmp/slsi-test-XXXXXX)"
  TENANT_ID="tenant-$(date +%s)-$RANDOM"
  OUTPUT_DIR="${TEST_DIR}/${TENANT_ID}"
  PASSPHRASE="test-passphrase-$(date +%s)"
}

teardown() {
  if [[ -n "${TEST_DIR:-}" && -d "${TEST_DIR}" ]]; then
    rm -rf "${TEST_DIR}"
  fi
  rm -f "/tmp/osramp-${TENANT_ID}.kubeconfig" "/tmp/osramp.kubeconfig"
}

@test "init-tenant.sh stage p2-3 verifies Zot catalog availability" {
  # Run p2-2 first to produce host mount structure and kind configuration
  ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --stage p2-2

  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --skip-cluster-create \
    --stage p2-3

  [ "$status" -eq 0 ]
  [[ "$output" =~ "stage_p2_3_bootstrap completed successfully" ]]
  [[ "$output" =~ "Zot catalog verified" ]]
}

@test "init-tenant.sh stage p2-4 fails when tenant cosign key is missing" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --keys-dir "${TEST_DIR}/nonexistent-keys" \
    --stage p2-4

  [ "$status" -ne 0 ]
  [[ "$output" =~ "Tenant Cosign public key missing" ]]
}

@test "init-tenant.sh stage p2-4 generates cosign-pub secret and dual-trust verification record in hub mode" {
  # Run p2-1 first to generate keys
  ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --escrow-passphrase "${PASSPHRASE}" \
    --stage p2-1

  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --stage p2-4

  [ "$status" -eq 0 ]
  [ -f "${OUTPUT_DIR}/cosign-pub-secret.yaml" ]
  [ -f "${OUTPUT_DIR}/dual-trust-verification.json" ]

  # Verify Secret content
  run grep -E "name: cosign-pub" "${OUTPUT_DIR}/cosign-pub-secret.yaml"
  [ "$status" -eq 0 ]
  run grep -E "name: slsi-release-pub" "${OUTPUT_DIR}/cosign-pub-secret.yaml"
  [ "$status" -eq 0 ]

  # Verify verification JSON schema and fields
  local record="${OUTPUT_DIR}/dual-trust-verification.json"
  [ "$(jq -r '.schema_version' "${record}")" = "slsi.dual-trust/v1" ]
  [ "$(jq -r '.tenant_id' "${record}")" = "${TENANT_ID}" ]
  [ "$(jq -r '.appliance_mode' "${record}")" = "hub" ]
  [ "$(jq -r '.manifest_verification.provider' "${record}")" = "cosign" ]
  [ "$(jq -r '.image_admission.action' "${record}")" = "Enforce" ]
}

@test "init-tenant.sh stage p2-4 respects Decision 8 attached mode" {
  # Run p2-1 first to generate keys
  ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --escrow-passphrase "${PASSPHRASE}" \
    --stage p2-1

  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --appliance-mode attached \
    --stage p2-4

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Configuring attached appliance mode" ]]
  [[ "$output" =~ "minting zero local issuers" ]]

  local record="${OUTPUT_DIR}/dual-trust-verification.json"
  [ -f "${record}" ]
  [ "$(jq -r '.appliance_mode' "${record}")" = "attached" ]
}

@test "CEL ValidatingAdmissionPolicy defines admission policy across tenant scopes" {
  local policy_file="policy/cel/require-trusted-registry.yaml"
  [ -f "${policy_file}" ]

  # Verify CEL ValidatingAdmissionPolicy presence and enforcement configuration
  run grep -E "kind: ValidatingAdmissionPolicy" "${policy_file}"
  [ "$status" -eq 0 ]
  run grep -E "failurePolicy: Fail" "${policy_file}"
  [ "$status" -eq 0 ]
  run grep -E "zot\.registry\.svc\.cluster\.local" "${policy_file}"
  [ "$status" -eq 0 ]

  # Verify unbundled Kyverno policy is deprecated and absent
  [ ! -e "policy/kyverno-verify-images.yaml" ]
}
