#!/usr/bin/env bats

setup() {
  root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  dex_manifest="$root/d2-signalloom/infra/inf-signalloom/base/dex.yaml"
  portal_manifest="$root/d2-signalloom/apps/fe-signalloom/base/deployment.yaml"
  portal_network_policy="$root/d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml"
  infra_network_policy="$root/d2-signalloom/infra/inf-signalloom/configs/base/networkpolicy.yaml"
}

@test "Dex credentials are bcrypt-hashed and never plaintext" {
  run grep -F 'hash: $2a$' "$dex_manifest"
  [ "$status" -eq 0 ]
  run grep -E '^[[:space:]]*(password|passwords):' "$dex_manifest"
  [ "$status" -ne 0 ]
}

@test "Dex declares the local dashboard client and tenant subject" {
  run grep -F 'id: signalloom-dashboard' "$dex_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'username: demo-user' "$dex_manifest"
  [ "$status" -eq 0 ]
  run grep -F '"demo-user":"tenant-demo"' "$portal_manifest"
  [ "$status" -eq 0 ]
}

@test "dashboard generic OIDC provider uses the Dex issuer" {
  run grep -F 'name: OIDC_PROVIDER' "$portal_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'value: generic' "$portal_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'name: OIDC_ISSUER_URL' "$portal_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'http://dex.inf-signalloom.svc.cluster.local:5556/dex' "$portal_manifest"
  [ "$status" -eq 0 ]
}

@test "NetworkPolicies allow only dashboard-to-Dex OIDC traffic" {
  run grep -F 'port: 5556' "$portal_network_policy"
  [ "$status" -eq 0 ]
  run grep -F 'name: allow-dex-oidc' "$infra_network_policy"
  [ "$status" -eq 0 ]
  run grep -F 'kubernetes.io/metadata.name: fe-signalloom' "$infra_network_policy"
  [ "$status" -eq 0 ]
}

@test "Dex discovery and JWKS endpoints are served by the local issuer" {
  run grep -F 'issuer: http://dex.inf-signalloom.svc.cluster.local:5556/dex' "$dex_manifest"
  [ "$status" -eq 0 ]
  run grep -F '/dex/.well-known/openid-configuration' "$dex_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'path: /healthz' "$dex_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'args: ["dex", "serve", "/etc/dex/config.yaml"]' "$dex_manifest"
  [ "$status" -eq 0 ]
}
