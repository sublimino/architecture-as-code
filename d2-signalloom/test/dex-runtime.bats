#!/usr/bin/env bats

setup() {
  root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  dex_manifest="$root/d2-signalloom/infra/inf-signalloom/base/dex.yaml"
  workdir="$(mktemp -d)"
  container="signalloom-dex-auth-test-$$"
  port=15556
  config="$workdir/config.yaml"
  discovery="$workdir/discovery.json"
}

teardown() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$workdir"
}

@test "Dex serves discovery and JWKS from its local issuer" {
  command -v docker >/dev/null
  docker info >/dev/null

  awk '/^  config.yaml: \|/{capture=1; next} capture && /^---$/{exit} capture {sub(/^    /, ""); print}' "$dex_manifest" >"$config"
  run docker run --rm -d --name "$container" -p "127.0.0.1:${port}:5556" -v "$config:/etc/dex/config.yaml:ro" ghcr.io/dexidp/dex:v2.41.1 dex serve /etc/dex/config.yaml
  [ "$status" -eq 0 ]

  for _ in {1..30}; do
    curl -fsS "http://127.0.0.1:${port}/dex/.well-known/openid-configuration" >"$discovery" && break
    sleep 1
  done
  test -s "$discovery"
  python3 -c 'import json, sys; d = json.load(sys.stdin); assert d["issuer"] == "http://dex.inf-signalloom.svc.cluster.local:5556/dex"; assert d["jwks_uri"] == "http://dex.inf-signalloom.svc.cluster.local:5556/dex/keys"' <"$discovery"

  run curl -fsS "http://127.0.0.1:${port}/dex/keys"
  [ "$status" -eq 0 ]
  python3 -c 'import json, sys; assert json.load(sys.stdin)["keys"]' <<<"$output"

}
