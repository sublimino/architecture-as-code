#!/usr/bin/env bats
# ==============================================================================
# test/slsi-ingress-modes.bats — SLSI-P3-1 Multi-Mode Ingress Verification
# ==============================================================================

setup() {
  TEST_DIR="$(mktemp -d)"
  TENANT_ID="tenant-$(date +%s)-$RANDOM"
  OUTPUT_DIR="${TEST_DIR}/${TENANT_ID}"
}

teardown() {
  if [[ -n "${TEST_DIR:-}" && -d "${TEST_DIR}" ]]; then
    rm -rf "${TEST_DIR}"
  fi
}

@test "init-tenant.sh stage ingress generates valid manifests for airgap-local mode" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --stage ingress \
    --ingress-mode airgap-local

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Multi-mode ingress configuration complete" ]]

  # Check generated files
  [ -f "${OUTPUT_DIR}/ingress/00-issuer.yaml" ]
  [ -f "${OUTPUT_DIR}/ingress/01-gateway.yaml" ]
  [ -f "${OUTPUT_DIR}/ingress/02-clienttrafficpolicy.yaml" ]
  [ -f "${OUTPUT_DIR}/ingress/03-httproutes.yaml" ]
  [ -f "${OUTPUT_DIR}/ingress/04-certificates.yaml" ]
  [ -f "${OUTPUT_DIR}/ingress/ingress-summary.json" ]

  # Verify Gateway manifest
  grep -q "gatewayClassName: envoy-gateway" "${OUTPUT_DIR}/ingress/01-gateway.yaml"
  grep -q "hostname: \"\*\.${TENANT_ID}\.osramp\.acme\.local\"" "${OUTPUT_DIR}/ingress/01-gateway.yaml"
  grep -q "name: cluster-tls" "${OUTPUT_DIR}/ingress/01-gateway.yaml"

  # Verify Self-signed Issuer
  grep -q "selfSigned: {}" "${OUTPUT_DIR}/ingress/00-issuer.yaml"

  # Verify Summary JSON
  grep -q '"schema_version": "slsi.ingress/v1"' "${OUTPUT_DIR}/ingress/ingress-summary.json"
  grep -q '"ingress_mode": "airgap-local"' "${OUTPUT_DIR}/ingress/ingress-summary.json"
  grep -q '"proxy_protocol_disabled": true' "${OUTPUT_DIR}/ingress/ingress-summary.json"
}

@test "init-tenant.sh stage ingress generates valid ACME DNS-01 ClusterIssuer and Certificate" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --stage ingress \
    --ingress-mode acme-dns01

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Multi-mode ingress configuration complete" ]]

  # Verify ACME ClusterIssuer
  grep -q "name: acme-dns01-issuer" "${OUTPUT_DIR}/ingress/00-issuer.yaml"
  grep -q "dns01:" "${OUTPUT_DIR}/ingress/00-issuer.yaml"
  grep -q "acme-v02.api.letsencrypt.org" "${OUTPUT_DIR}/ingress/00-issuer.yaml"

  # Verify Certificate requesting from ACME issuer
  grep -q "name: ${TENANT_ID}-acme-cert" "${OUTPUT_DIR}/ingress/04-certificates.yaml"
  grep -q "secretName: ${TENANT_ID}-acme-tls" "${OUTPUT_DIR}/ingress/04-certificates.yaml"
  grep -q "name: acme-dns01-issuer" "${OUTPUT_DIR}/ingress/04-certificates.yaml"

  # Verify Gateway references ACME secret
  grep -q "name: ${TENANT_ID}-acme-tls" "${OUTPUT_DIR}/ingress/01-gateway.yaml"
}

@test "init-tenant.sh stage ingress configures ClientTrafficPolicy and pins trusted hops (Decision 5)" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --stage ingress \
    --ingress-mode cloud-lb-l7 \
    --num-trusted-hops 2

  [ "$status" -eq 0 ]

  local ctp="${OUTPUT_DIR}/ingress/02-clienttrafficpolicy.yaml"
  [ -f "$ctp" ]

  # Verify ClientTrafficPolicy structure
  grep -q "kind: ClientTrafficPolicy" "$ctp"
  grep -q "name: cluster-strip-spoofable-client-headers" "$ctp"
  grep -q "numTrustedHops: 2" "$ctp"
  grep -q -- "- X-Forwarded-For" "$ctp"
  grep -q -- "- X-Real-IP" "$ctp"

  # Decision 5 strict check: PROXY protocol must be avoided
  ! grep -qi "proxyProtocol" "$ctp"
  ! grep -qi "proxy_protocol" "$ctp"
}

@test "init-tenant.sh stage ingress renders ReferenceGrant and Secret in custom-byo-pki mode" {
  local dummy_ca="${TEST_DIR}/dummy-ca.crt"
  echo "-----BEGIN CERTIFICATE-----" > "$dummy_ca"
  echo "MIIB dummy certificate content" >> "$dummy_ca"
  echo "-----END CERTIFICATE-----" >> "$dummy_ca"

  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --stage ingress \
    --ingress-mode custom-byo-pki \
    --byo-ca-cert "$dummy_ca"

  [ "$status" -eq 0 ]

  # Verify ReferenceGrant named byo-tls-grant
  grep -q "name: byo-tls-grant" "${OUTPUT_DIR}/ingress/01-gateway.yaml"
  grep -q "name: byo-tls" "${OUTPUT_DIR}/ingress/01-gateway.yaml"

  # Verify BYO Secret in cert-manager
  grep -q "name: byo-tls" "${OUTPUT_DIR}/ingress/04-certificates.yaml"
  grep -q "ca.crt:" "${OUTPUT_DIR}/ingress/04-certificates.yaml"
}

@test "init-tenant.sh stage ingress generates HTTPRoute resources for dashboard, api, and docs" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --stage ingress \
    --ingress-mode airgap-local

  [ "$status" -eq 0 ]

  local routes="${OUTPUT_DIR}/ingress/03-httproutes.yaml"
  [ -f "$routes" ]

  # Verify dashboard route
  grep -q "name: ${TENANT_ID}-dashboard" "$routes"
  grep -q "name: dashboard-signalloom" "$routes"
  grep -q "port: 8080" "$routes"

  # Verify API route
  grep -q "name: ${TENANT_ID}-api" "$routes"
  grep -q "name: fe-signalloom-api" "$routes"
  grep -q "value: /api" "$routes"
  grep -q "port: 8000" "$routes"

  # Verify docs route
  grep -q "name: ${TENANT_ID}-docs" "$routes"
  grep -q "name: docs-signalloom" "$routes"
}

@test "init-tenant.sh rejects unknown ingress mode" {
  run ./scripts/init-tenant.sh \
    --tenant-id "${TENANT_ID}" \
    --output-dir "${OUTPUT_DIR}" \
    --stage ingress \
    --ingress-mode unpermitted-mode

  [ "$status" -ne 0 ]
  [[ "$output" =~ "ERROR: Unknown ingress mode 'unpermitted-mode'" ]]
}

@test "all generated YAML manifests across all 4 modes are syntactically valid YAML" {
  local modes=("airgap-local" "acme-dns01" "cloud-lb-l7" "custom-byo-pki")

  for mode in "${modes[@]}"; do
    local mode_dir="${TEST_DIR}/test-${mode}"
    ./scripts/init-tenant.sh \
      --tenant-id "${TENANT_ID}" \
      --output-dir "${mode_dir}" \
      --stage ingress \
      --ingress-mode "${mode}"

    # Validate each YAML file in output ingress dir
    for yf in "${mode_dir}/ingress/"*.yaml; do
      [ -f "$yf" ]
      python3 -c "import yaml; list(yaml.safe_load_all(open('$yf')))"
    done
  done
}
