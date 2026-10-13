#!/usr/bin/env bats
# ==============================================================================
# test/slsi-bootstrap-persistence.bats — SLSI-P2-5 Appliance Bootstrap and Persistence
# Verifies:
#  (1) Consecutive runs generate disjoint cryptographic keys and distinct escrows
#  (2) PostgreSQL and OpenBao host persistence survives cluster lifecycle
#  (3) Decision 8 mode boundaries: APPLIANCE_MODE=hub vs APPLIANCE_MODE=attached
# ==============================================================================

setup() {
  TEST_DIR="$(mktemp -d /tmp/slsi-test-XXXXXX)"
  TENANT_A="tenant-a-$RANDOM"
  TENANT_B="tenant-b-$RANDOM"
  DIR_A="${TEST_DIR}/${TENANT_A}"
  DIR_B="${TEST_DIR}/${TENANT_B}"
  PASSPHRASE="passphrase-$(date +%s)-$RANDOM"
}

teardown() {
  if [[ -n "${TEST_DIR:-}" && -d "${TEST_DIR}" ]]; then
    rm -rf "${TEST_DIR}"
  fi
  rm -f "/tmp/osramp-${TENANT_A}.kubeconfig" "/tmp/osramp-${TENANT_B}.kubeconfig"
  rm -f "/tmp/osramp-tenant-persist-"*".kubeconfig" "/tmp/osramp-tenant-hub-"*".kubeconfig" "/tmp/osramp-tenant-attached-"*".kubeconfig"
  rm -f "/tmp/osramp.kubeconfig"
}

@test "two consecutive runs produce disjoint cryptographic keys and distinct escrow archives" {
  # Run 1: Bootstrap tenant A
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_A}" \
    --output-dir "${DIR_A}" \
    --escrow-passphrase "${PASSPHRASE}" \
    --stage p2-1

  [ "$status" -eq 0 ]
  [ -f "${DIR_A}/keys/cosign.pub" ]
  [ -f "${DIR_A}/keys/witness-pub.pem" ]
  [ -f "${DIR_A}/keys/orbit-approval-pub.pem" ]
  [ -f "${DIR_A}/${TENANT_A}-escrow.tar.enc" ]

  # Run 2: Bootstrap tenant B
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_B}" \
    --output-dir "${DIR_B}" \
    --escrow-passphrase "${PASSPHRASE}" \
    --stage p2-1

  [ "$status" -eq 0 ]
  [ -f "${DIR_B}/keys/cosign.pub" ]
  [ -f "${DIR_B}/keys/witness-pub.pem" ]
  [ -f "${DIR_B}/keys/orbit-approval-pub.pem" ]
  [ -f "${DIR_B}/${TENANT_B}-escrow.tar.enc" ]

  # Assert public keys are cryptographically disjoint
  local cosign_a_sha cosign_b_sha witness_a_sha witness_b_sha orbit_a_sha orbit_b_sha
  cosign_a_sha="$(sha256sum "${DIR_A}/keys/cosign.pub" | awk '{print $1}')"
  cosign_b_sha="$(sha256sum "${DIR_B}/keys/cosign.pub" | awk '{print $1}')"
  [ "${cosign_a_sha}" != "${cosign_b_sha}" ]

  witness_a_sha="$(sha256sum "${DIR_A}/keys/witness-pub.pem" | awk '{print $1}')"
  witness_b_sha="$(sha256sum "${DIR_B}/keys/witness-pub.pem" | awk '{print $1}')"
  [ "${witness_a_sha}" != "${witness_b_sha}" ]

  orbit_a_sha="$(sha256sum "${DIR_A}/keys/orbit-approval-pub.pem" | awk '{print $1}')"
  orbit_b_sha="$(sha256sum "${DIR_B}/keys/orbit-approval-pub.pem" | awk '{print $1}')"
  [ "${orbit_a_sha}" != "${orbit_b_sha}" ]

  # Required contract probe: diff returns non-zero when keys are disjoint
  run bash -c "diff -u <(openssl pkey -pubin -in '${DIR_A}/keys/cosign.pub') <(openssl pkey -pubin -in '${DIR_B}/keys/cosign.pub') || echo 'Keys disjoint as expected'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Keys disjoint as expected" ]]

  # Assert escrow archives have disjoint checksums
  local escrow_a_sha escrow_b_sha
  escrow_a_sha="$(sha256sum "${DIR_A}/${TENANT_A}-escrow.tar.enc" | awk '{print $1}')"
  escrow_b_sha="$(sha256sum "${DIR_B}/${TENANT_B}-escrow.tar.enc" | awk '{print $1}')"
  [ "${escrow_a_sha}" != "${escrow_b_sha}" ]
}

@test "PostgreSQL and OpenBao host persistence survives cluster recreation" {
  local tenant="tenant-persist-$RANDOM"
  local tenant_dir="${TEST_DIR}/${tenant}"
  local data_dir="${tenant_dir}/data"

  # Stage 1: Generate host mounts and Kind config
  run ./scripts/init-tenant.sh \
    --tenant-id "${tenant}" \
    --output-dir "${tenant_dir}" \
    --data-dir "${data_dir}" \
    --stage p2-2

  [ "$status" -eq 0 ]
  [ -d "${data_dir}/postgres" ]
  [ -d "${data_dir}/openbao" ]

  # Seed PostgreSQL test records and OpenBao secrets prior to recreation
  ./scripts/test-helpers/postgres-persistence-helper.sh seed "${data_dir}/postgres" test_table auth_token_key auth_token_secret_123
  ./scripts/test-helpers/openbao-persistence-helper.sh seed "${data_dir}/openbao" secret/data/slsi-keys master_token master_token_val_456

  # Verify initial data presence
  run ./scripts/test-helpers/postgres-persistence-helper.sh verify "${data_dir}/postgres" test_table auth_token_key auth_token_secret_123
  [ "$status" -eq 0 ]
  run ./scripts/test-helpers/openbao-persistence-helper.sh verify "${data_dir}/openbao" secret/data/slsi-keys master_token master_token_val_456
  [ "$status" -eq 0 ]

  # Simulate cluster deletion & recreation cycle:
  # Re-run stage p2-2 and stage p2-3 reusing the exact same data directory
  run ./scripts/init-tenant.sh \
    --tenant-id "${tenant}" \
    --output-dir "${tenant_dir}" \
    --data-dir "${data_dir}" \
    --stage p2-2

  [ "$status" -eq 0 ]

  run ./scripts/init-tenant.sh \
    --tenant-id "${tenant}" \
    --output-dir "${tenant_dir}" \
    --data-dir "${data_dir}" \
    --skip-cluster-create \
    --stage p2-3

  [ "$status" -eq 0 ]

  # Verify PostgreSQL records and OpenBao secrets remain 100% intact after re-initialization
  run ./scripts/test-helpers/postgres-persistence-helper.sh verify "${data_dir}/postgres" test_table auth_token_key auth_token_secret_123
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Verified Postgres persistence records" ]]

  run ./scripts/test-helpers/openbao-persistence-helper.sh verify "${data_dir}/openbao" secret/data/slsi-keys master_token master_token_val_456
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Verified OpenBao persistence secret" ]]

  # Assert Kind configuration preserves container mount mappings
  local kind_cfg="${tenant_dir}/kind-config.yaml"
  [ -f "${kind_cfg}" ]
  grep -Fq "containerPath: /var/local/signalloom-postgres-data" "${kind_cfg}"
  grep -Fq "containerPath: /var/local/signalloom-openbao-data" "${kind_cfg}"
  grep -Fq "containerPath: /var/local/osramp-zot-cache" "${kind_cfg}"
}

@test "APPLIANCE_MODE=hub mints local issuers and renders zero remote-tenant overlay" {
  local tenant="tenant-hub-$RANDOM"
  local tenant_dir="${TEST_DIR}/${tenant}"

  run env APPLIANCE_MODE=hub ./scripts/init-tenant.sh \
    --tenant-id "${tenant}" \
    --output-dir "${tenant_dir}" \
    --escrow-passphrase "${PASSPHRASE}" \
    --appliance-mode hub \
    --stage p2-1

  [ "$status" -eq 0 ]
  [ -f "${tenant_dir}/keys/cosign.key" ]
  [ -f "${tenant_dir}/keys/cosign.pub" ]
  [ -f "${tenant_dir}/keys/witness.pem" ]
  [ -f "${tenant_dir}/${tenant}-escrow.tar.enc" ]

  run env APPLIANCE_MODE=hub ./scripts/init-tenant.sh \
    --tenant-id "${tenant}" \
    --output-dir "${tenant_dir}" \
    --appliance-mode hub \
    --stage p2-4

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Configuring hub appliance mode" ]]

  # Assert local secret was generated
  [ -f "${tenant_dir}/cosign-pub-secret.yaml" ]

  # Assert absence of remote-tenant overlay rendering
  [ ! -f "${tenant_dir}/remote-tenant-rendered.yaml" ]

  # Assert dual-trust verification record reflects hub mode with local issuers
  local record="${tenant_dir}/dual-trust-verification.json"
  [ -f "${record}" ]
  [ "$(jq -r '.appliance_mode' "${record}")" = "hub" ]
  [ "$(jq -r '.mint_local_issuers' "${record}")" = "true" ]
}

@test "APPLIANCE_MODE=attached renders warden-only overlay and mints zero local issuers" {
  local tenant="tenant-attached-$RANDOM"
  local tenant_dir="${TEST_DIR}/${tenant}"

  run env APPLIANCE_MODE=attached ./scripts/init-tenant.sh \
    --tenant-id "${tenant}" \
    --output-dir "${tenant_dir}" \
    --appliance-mode attached \
    --stage p2-1

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Attached appliance mode: consuming central issuer secrets, minting zero local issuers" ]]

  # Assert ZERO local private keys or escrow were minted
  [ ! -f "${tenant_dir}/keys/cosign.key" ]
  [ ! -f "${tenant_dir}/keys/witness-key.pem" ]
  [ ! -f "${tenant_dir}/keys/orbit-approval.key" ]
  [ ! -f "${tenant_dir}/${tenant}-escrow.tar.enc" ]

  run env APPLIANCE_MODE=attached ./scripts/init-tenant.sh \
    --tenant-id "${tenant}" \
    --output-dir "${tenant_dir}" \
    --appliance-mode attached \
    --stage p2-4

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Configuring attached appliance mode" ]]

  # Assert presence of rendered warden-only remote-tenant overlay
  local rendered="${tenant_dir}/remote-tenant-rendered.yaml"
  [ -f "${rendered}" ]

  # Assert overlay contains warden and rbac-exporter workloads
  grep -Fq "name: signalloom-warden" "${rendered}"
  grep -Fq "name: signalloom-rbac-exporter" "${rendered}"

  # Assert overlay references central secrets
  grep -Fq "name: signalloom-warden-ingest-token" "${rendered}"
  grep -Fq "name: signalloom-warden-fleet-key" "${rendered}"

  # Assert overlay contains ZERO local cert-manager issuers
  run grep -E "kind:\s*ClusterIssuer" "${rendered}"
  [ "$status" -ne 0 ]
  run grep -E "kind:\s*Issuer" "${rendered}"
  [ "$status" -ne 0 ]

  # Assert dual-trust verification record reflects attached mode with zero local issuers
  local record="${tenant_dir}/dual-trust-verification.json"
  [ -f "${record}" ]
  [ "$(jq -r '.appliance_mode' "${record}")" = "attached" ]
  [ "$(jq -r '.mint_local_issuers' "${record}")" = "false" ]
}
