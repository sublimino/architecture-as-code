#!/usr/bin/env bats

setup() {
  root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  dex_manifest="$root/d2-signalloom/infra/inf-signalloom/base/dex.yaml"
  portal_manifest="$root/d2-signalloom/apps/fe-signalloom/base/deployment.yaml"
  portal_network_policy="$root/d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml"
  infra_network_policy="$root/d2-signalloom/infra/inf-signalloom/configs/base/networkpolicy.yaml"
}

@test "Dex credentials are bcrypt-hashed and never plaintext" {
  run grep -E 'hash: \$2[aby]\$' "$dex_manifest"
  [ "$status" -eq 0 ]
  run grep -E '^[[:space:]]*(password|passwords):' "$dex_manifest"
  [ "$status" -ne 0 ]
}

@test "Dex OIDC contract requests the documented compatibility API audience" {
  run grep -F 'redirectURIs:' "$dex_manifest"
  [ "$status" -eq 0 ]
  # Gateway callback (primary path — all automated tests go through Envoy).
  run grep -F 'https://dashboard.osramp.acme.local:30754/callback' "$dex_manifest"
  [ "$status" -eq 0 ]
  # Local vite dev callback (kept so `bun run dev` auth works without the Gateway).
  run grep -F 'http://localhost:5173/callback' "$dex_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'value: openid profile email groups audience:server:client_id:signalloom-api' "$portal_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'name: OIDC_CLIENT_ID' "$portal_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'value: signalloom-dashboard' "$portal_manifest"
  [ "$status" -eq 0 ]
}

@test "Dex declares the compatibility API peer and tenant subject" {
  run grep -F 'id: signalloom-dashboard' "$dex_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'id: signalloom-api' "$dex_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'secret: signalloom-api-local-only' "$dex_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'trustedPeers:' "$dex_manifest"
  [ "$status" -eq 0 ]
  run grep -F -- '- signalloom-dashboard' "$dex_manifest"
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
  # The issuer is now ${PUBLIC_ORIGIN:=<url>}/dex so the demo can be published
  # on a tunnel or an external IP. Still asserted as strictly as before: it must
  # end in /dex, and whether literal or templated it must resolve to a real
  # http(s) URL — a token with no default would break every login silently,
  # because a missing substituteFrom key is a no-op rather than an error.
  run grep -E 'issuer: (https?://[^ ]+|\$\{[A-Za-z_][A-Za-z0-9_]*:=https?://[^}]+\})/dex$' "$dex_manifest"
  [ "$status" -eq 0 ]
  run grep -F '/dex/.well-known/openid-configuration' "$dex_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'path: /dex/.well-known/openid-configuration' "$dex_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'args: ["dex", "serve", "/etc/dex/config.yaml"]' "$dex_manifest"
  [ "$status" -eq 0 ]
}

@test "Dex has writable temporary storage under read-only root filesystem" {
  run grep -F 'mountPath: /tmp' "$dex_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'emptyDir: {}' "$dex_manifest"
  [ "$status" -eq 0 ]
}

@test "local Kustomize overlay renders the complete Dex runtime" {
  run kubectl kustomize "$root/d2-signalloom/infra/inf-signalloom/configs/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"name: dex-local-auth"* ]]
  [[ "$output" == *"kind: Deployment"* ]]
  [[ "$output" == *"name: dex"* ]]
  [[ "$output" == *"kind: Service"* ]]
}

@test "Dex password grant uses the local password connector" {
  run grep -F 'passwordConnector: local' "$dex_manifest"
  [ "$status" -eq 0 ]
}

@test "portal validates Dex tokens through the configured JWKS endpoint" {
  run grep -F 'name: API_JWKS_URL' "$portal_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'value: http://dex.inf-signalloom.svc.cluster.local:5556/dex/keys' "$portal_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'name: API_JWT_AUTHORIZED_PARTY' "$portal_manifest"
  [ "$status" -eq 0 ]
  run grep -F 'value: signalloom-dashboard' "$portal_manifest"
  [ "$status" -eq 0 ]
}
