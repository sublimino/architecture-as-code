#!/usr/bin/env bats
#
# Verify the dashboard-signalloom SPA is reachable through the Envoy Ingress
# Gateway (HTTPS, port 18443) — not just the direct nginx port-forward.
# This proves the HTTPRoute, TLS termination, and SPA fallback work end-to-end.
#
# Precondition: kubectl -n ingress port-forward svc/envoy-ingress-cluster-* 18443:443
# Skips gracefully when the port-forward is absent.

setup() {
  gw_host="dashboard.osramp.acme.local"
  gw_port="${SIGNALLOOM_GW_PORT:-18443}"
  gw_base="https://${gw_host}:${gw_port}"
  resolve="--resolve ${gw_host}:${gw_port}:127.0.0.1"
  curl_opts="-sk --max-time 10 --noproxy '*' ${resolve}"

  # shellcheck disable=SC2086
  curl $curl_opts "$gw_base/readyz" >/dev/null 2>&1 || skip "Gateway not reachable at $gw_base (port-forward required)"
}

@test "Gateway: / returns the SPA index" {
  # shellcheck disable=SC2086
  run curl $curl_opts "$gw_base/"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]
}

@test "Gateway: /readyz returns ready" {
  # shellcheck disable=SC2086
  run curl $curl_opts "$gw_base/readyz"
  [ "$status" -eq 0 ]
  [ "$output" = "ready" ]
}

@test "Gateway: /api returns 401 without a token (auth enforced)" {
  # shellcheck disable=SC2086
  run curl $curl_opts -o /dev/null -w '%{http_code}' "$gw_base/api/agents"
  [ "$status" -eq 0 ]
  [ "$output" = "401" ]
}

@test "Gateway: Dex discovery is reachable through the proxy" {
  # shellcheck disable=SC2086
  run curl $curl_opts "$gw_base/dex/.well-known/openid-configuration"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"issuer"'* ]]
}

@test "Gateway: SPA fallback for /cryptography" {
  # shellcheck disable=SC2086
  run curl $curl_opts "$gw_base/cryptography"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]
}

@test "Gateway: SPA fallback for /federated-services" {
  # shellcheck disable=SC2086
  run curl $curl_opts "$gw_base/federated-services"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]
}

@test "Gateway: SPA fallback for /collusion-access" {
  # shellcheck disable=SC2086
  run curl $curl_opts "$gw_base/collusion-access"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]
}

# Repointed from /ktp-collusion-graph.png, which was the Collusion & Access
# backdrop until that backdrop was removed for uniformity with its sibling pages.
# The file outlived the only thing that referenced it, so this test was guarding
# an orphan.
#
# The asset changed; the invariant did not. This proves the gateway passes a
# non-HTML response through intact — content_type is the discriminator, since a
# route misconfiguration that lands on the SPA fallback still returns HTTP 200,
# just with text/html. /brand/signal-loom-logo.png is rendered by Sidebar.tsx on
# every page, so unlike the KTP graph it cannot silently become unreferenced.
@test "Gateway: static assets pass through with their real content type" {
  # shellcheck disable=SC2086
  run curl $curl_opts -o /dev/null -w '%{content_type}' "$gw_base/brand/signal-loom-logo.png"
  [ "$status" -eq 0 ]
  [[ "$output" == image/* ]]
}

@test "Gateway: JS bundle references new routes" {
  # shellcheck disable=SC2086
  index="$(curl $curl_opts "$gw_base/")"
  js_path="$(echo "$index" | grep -oE 'assets/index-[A-Za-z0-9_-]+\.js' | head -1)"
  [ -n "$js_path" ]
  # shellcheck disable=SC2086
  bundle="$(curl $curl_opts "$gw_base/$js_path")"
  [[ "$bundle" == *"cryptography"* ]]
  [[ "$bundle" == *"federated-services"* ]]
  [[ "$bundle" == *"collusion-access"* ]]
}
