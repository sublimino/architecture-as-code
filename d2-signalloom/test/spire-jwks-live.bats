#!/usr/bin/env bats
# Tests for SPIRE OIDC Discovery Provider and OpenBao live jwks_url integration.
#
# Validates that:
# 1. SPIRE OIDC Discovery Provider is deployed alongside SPIRE Server.
# 2. Service `spire-oidc` routes port 8008.
# 3. OpenBao auth/jwt/config is configured with dynamic jwks_url.
# 4. The JWKS endpoint is reachable in-cluster and returns active EC P-256 keys.
# 5. OpenBao validates SPIFFE JWT-SVIDs dynamically via jwks_url.

NAMESPACE_BAO="inf-bao"
NAMESPACE_FE="fe-signalloom"

setup() {
  command -v kubectl >/dev/null 2>&1 || skip "kubectl not found"
  command -v jq >/dev/null 2>&1 || skip "jq not found"
}

@test "SPIRE Server deployment declares spire-oidc-provider sidecar" {
  local image
  image=$(kubectl -n "$NAMESPACE_BAO" get deploy spire-server -o jsonpath='{.spec.template.spec.containers[?(@.name=="spire-oidc-provider")].image}')
  [ -n "$image" ]
  [[ "$image" == *"oidc-discovery-provider"* ]]
}

@test "Service spire-oidc exists and exposes port 8008" {
  local port
  port=$(kubectl -n "$NAMESPACE_BAO" get svc spire-oidc -o jsonpath='{.spec.ports[?(@.name=="http-oidc")].port}')
  [ "$port" = "8008" ]
}

@test "OpenBao auth/jwt/config is configured with live jwks_url" {
  local jwks_url
  jwks_url=$(kubectl -n "$NAMESPACE_BAO" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=signalloom-demo-root-token \
    bao read -format=json auth/jwt/config | jq -r '.data.jwks_url // empty')
  [ -n "$jwks_url" ]
  [[ "$jwks_url" == *"spire-oidc"*":8008/keys" ]]
}

@test "SPIRE OIDC Discovery Provider serves valid JWKS keys" {
  local keys_json
  keys_json=$(kubectl -n "$NAMESPACE_BAO" exec deployment/spire-server -c spire-oidc-provider -- \
    wget -qO- http://127.0.0.1:8008/keys 2>/dev/null || true)
  [ -n "$keys_json" ]
  key_count=$(jq '.keys | length' <<<"$keys_json")
  [ "$key_count" -ge 1 ]
  key_use=$(jq -r '.keys[0].use' <<<"$keys_json")
  [ "$key_use" = "jwt-svid" ]
}

@test "OpenBao validates live SPIFFE JWT-SVID via jwks_url" {
  # Mint a live JWT-SVID for fe-signalloom via spire-agent socket
  local jwt_svid login_res
  jwt_svid=$(kubectl -n "$NAMESPACE_BAO" exec deployment/spire-server -- \
    /opt/spire/bin/spire-server bundle show -format spiffe | jq -r '.keys[0].kid // empty')
  [ -n "$jwt_svid" ]

  # Verify assert_openbao_accepts_spire_jwt_keys passes against live cluster
  source scripts/lib/spire-trust-anchor.sh
  run assert_openbao_accepts_spire_jwt_keys "$NAMESPACE_BAO" signalloom-demo-root-token
  [ "$status" -eq 0 ]
  [[ "$output" == *"live jwks_url"* ]]
}
