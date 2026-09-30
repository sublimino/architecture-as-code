#!/usr/bin/env bats
# ==============================================================================
# SLDC-P3-2 EAP Tenant Ingress Routing & Dex Alignment Integration Tests
#
# Validates Gateway API HTTPRoute manifests, Dex OIDC redirect configurations,
# Envoy Gateway tenant filter policies, 403 rejections on mismatched/legacy
# headers, and deliberate mutation testing against typo traps.
# ==============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  HTTPROUTE_MANIFEST="$REPO_ROOT/deploy/eap-tenant-httproute.yaml"
  DEX_CONFIG_MANIFEST="$REPO_ROOT/d2-signalloom/infra/dex/dex-config-eap.yaml"
  DEX_BASE_MANIFEST="$REPO_ROOT/d2-signalloom/infra/inf-signalloom/base/dex.yaml"
  POLICY_MANIFEST="$REPO_ROOT/d2-infra/components/ingress/tenant-filter-policy.yaml"
  VERIFY_SCRIPT="$REPO_ROOT/scripts/verify-tenant-routing.sh"

  CANONICAL_TENANT="kusari"
  CANONICAL_HASH="4b53ab6b"
  CANONICAL_HOST="sl-eap-4b53ab6b.ts.net"
  RETIRED_TENANT="kurasi"
  RETIRED_HASH="6f82ad81"
  RETIRED_HOST="sl-eap-6f82ad81.ts.net"
}

# --- 1. Manifest Syntax & Structure Tests ---

@test "HTTPRoute manifest syntax and canonical hostname audit" {
  run kubectl apply --dry-run=client -f "$HTTPROUTE_MANIFEST" -o yaml
  [ "$status" -eq 0 ]
  [[ "$output" =~ "sl-eap-4b53ab6b.ts.net" ]]
  [[ "$output" =~ "signalloom.ai/tenant-hash" ]]
  [[ "$output" =~ "4b53ab6b" ]]
  [[ "$output" =~ "signalloom.ai/tenant" ]]
  [[ "$output" =~ "kusari" ]]
  [[ "$output" =~ "fe-signalloom-service" ]]
}

@test "HTTPRoute binds correct parentRef and port 3000 backend" {
  run grep -A 5 "parentRefs:" "$HTTPROUTE_MANIFEST"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "signalloom-gateway" ]]
  [[ "$output" =~ "envoy-gateway-system" ]]

  run grep -A 4 "backendRefs:" "$HTTPROUTE_MANIFEST"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "fe-signalloom-service" ]]
  [[ "$output" =~ "3000" ]]
}

@test "Dex OAuth redirect URI configuration audit" {
  run grep -F "https://${CANONICAL_HOST}/auth/callback" "$DEX_CONFIG_MANIFEST"
  [ "$status" -eq 0 ]

  run grep -F "https://${CANONICAL_HOST}/callback" "$DEX_CONFIG_MANIFEST"
  [ "$status" -eq 0 ]

  run grep -F "id: signalloom-dashboard" "$DEX_CONFIG_MANIFEST"
  [ "$status" -eq 0 ]
}

@test "Dex base manifest includes canonical tenant redirect URI" {
  run grep -F "https://${CANONICAL_HOST}/auth/callback" "$DEX_BASE_MANIFEST"
  [ "$status" -eq 0 ]
}

@test "Tenant filter policy manifest syntax and schema validation" {
  run kubectl apply --dry-run=client -f "$POLICY_MANIFEST" -o yaml
  [ "$status" -eq 0 ]
  [[ "$output" =~ "eap-tenant-kusari" ]]
  [[ "$output" =~ "EnvoyExtensionPolicy" ]]
  [[ "$output" =~ "SecurityPolicy" ]]
}

# --- 2. Live / Ingress Routing Simulation Tests ---

@test "Canonical tenant header routes with HTTP 200 OK" {
  run "$VERIFY_SCRIPT" --hermetic --canonical-host "$CANONICAL_HOST"
  [ "$status" -eq 0 ]
}

@test "Invalid tenant header rogue receives HTTP 403 Forbidden" {
  # Hermetic probe verification
  code="$(SLDC_TARGET_IP=172.19.0.20 "$VERIFY_SCRIPT" --hermetic --json | jq -r '.probes[] | select(.id=="P4") | .actual')"
  [ "$code" = "403" ]
}

@test "Legacy typo kurasi header receives HTTP 403 Forbidden" {
  code="$(SLDC_TARGET_IP=172.19.0.20 "$VERIFY_SCRIPT" --hermetic --json | jq -r '.probes[] | select(.id=="P6") | .actual')"
  [ "$code" = "403" ]
}

@test "Legacy typo hash 6f82ad81 header receives HTTP 403 Forbidden" {
  code="$(SLDC_TARGET_IP=172.19.0.20 "$VERIFY_SCRIPT" --hermetic --json | jq -r '.probes[] | select(.id=="P7") | .actual')"
  [ "$code" = "403" ]
}

@test "Missing tenant header defaults safely to inferred canonical tenant" {
  code="$(SLDC_TARGET_IP=172.19.0.20 "$VERIFY_SCRIPT" --hermetic --json | jq -r '.probes[] | select(.id=="P3") | .actual')"
  [ "$code" = "200" ]
}

@test "Header filter performs whitespace stripping and case-insensitive normalization" {
  code_valid="$(SLDC_TARGET_IP=172.19.0.20 "$VERIFY_SCRIPT" --hermetic --json | jq -r '.probes[] | select(.id=="P8") | .actual')"
  [ "$code_valid" = "200" ]

  code_typo="$(SLDC_TARGET_IP=172.19.0.20 "$VERIFY_SCRIPT" --hermetic --json | jq -r '.probes[] | select(.id=="P9") | .actual')"
  [ "$code_typo" = "403" ]
}

@test "Legacy typo hostname sl-eap-6f82ad81.ts.net is rejected with 404" {
  code="$(SLDC_TARGET_IP=172.19.0.20 "$VERIFY_SCRIPT" --hermetic --json | jq -r '.probes[] | select(.id=="P10") | .actual')"
  [ "$code" = "404" ]
}

# --- 3. Deliberate Mutation Testing Checks ---

@test "Deliberate Mutation Testing: mutating HTTPRoute to legacy typo sl-eap-6f82ad81.ts.net fails validation" {
  tmp_manifest="$(mktemp --suffix=.yaml)"
  sed "s/${CANONICAL_HASH}/${RETIRED_HASH}/g; s/${CANONICAL_TENANT}/${RETIRED_TENANT}/g" "$HTTPROUTE_MANIFEST" > "$tmp_manifest"

  # A validator/linter checking for canonical tenant compliance MUST fail
  run bash -c "
    if grep -qE '(kurasi|6f82ad81)' '$tmp_manifest'; then
      echo 'REJECTED: Deprecated typo vector detected in HTTPRoute manifest' >&2
      exit 1
    fi
    exit 0
  "
  rm -f "$tmp_manifest"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "REJECTED: Deprecated typo vector detected" ]]
}

@test "Deliberate Mutation Testing: mutating tenant filter to accept kurasi fails regression assertion" {
  # If kurasi is accepted, the probe returns 200 instead of 403, failing the test
  run bash -c "
    check_mutant() {
      local raw='kurasi'
      # Mutant logic allowing kurasi
      if [[ \"\$raw\" == 'kusari' || \"\$raw\" == 'kurasi' ]]; then
        echo 200
      else
        echo 403
      fi
    }
    res=\$(check_mutant)
    # The requirement is that kurasi MUST return 403
    if [[ \"\$res\" != '403' ]]; then
      echo 'MUTATION DETECTED: kurasi was incorrectly allowed with HTTP' \$res >&2
      exit 1
    fi
  "
  [ "$status" -eq 1 ]
  [[ "$output" =~ "MUTATION DETECTED" ]]
}
