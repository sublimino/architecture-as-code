#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  harness="$root/scripts/signalloom-test-1.sh"
}

@test "TEST-1 has one documented Make entrypoint" {
  run make -C "$root" -n demo-signalloom-test-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"./scripts/signalloom-test-1.sh"* ]]
}

@test "TEST-1 composes Playwright BATS pytest and Go contracts" {
  run bash -n "$harness"
  [ "$status" -eq 0 ]

  run grep -E 'playwright|acceptance-test' "$harness"
  [ "$status" -eq 0 ]
  run grep -E 'bats .*test-1-runtime|test-1-runtime\.bats' "$harness"
  [ "$status" -eq 0 ]
  run grep -E 'python -m pytest' "$harness"
  [ "$status" -eq 0 ]
  run grep -E 'go test' "$harness"
  [ "$status" -eq 0 ]
}

@test "TEST-1 browser cases enumerate the committed window matrix" {
  matrix="$root/docs/signalloom/dashboard-journey-matrix.md"
  spec="$root/test/acceptance/signalloom-test-1.spec.ts"
  run bash -c '
    count=0
    while IFS="|" read -r _ journey _rest; do
      journey="$(printf "%s" "$journey" | xargs)"
      case "$journey" in Journey|---|"") continue ;; esac
      grep -F "[\"$journey\"" "$2" >/dev/null || exit 1
      count=$((count + 1))
    done < <(sed -n "/## Routes and windows/,/## API journeys/p" "$1")
    test "$count" -eq 14
  ' _ "$matrix" "$spec"
  [ "$status" -eq 0 ]
}

@test "TEST-1 includes persistence fakes Gateway probes and policy negatives" {
  run grep -F 'API contracts and persistence' "$harness"
  [ "$status" -eq 0 ]
  run grep -F 'fake-integration-proxy/test' "$harness"
  [ "$status" -eq 0 ]

  runtime="$root/d2-signalloom/test/test-1-runtime.bats"
  run grep -E 'HTTPRoute|livez|readyz|NetworkPolicy|external egress|persistence' "$runtime"
  [ "$status" -eq 0 ]
}

@test "TEST-1 continues after failures but returns nonzero" {
  run grep -F 'FAILURES=$((FAILURES + 1))' "$harness"
  [ "$status" -eq 0 ]
  run grep -F 'if ((FAILURES > 0))' "$harness"
  [ "$status" -eq 0 ]
}

@test "TEST-1 acceptance uses only Signalloom and shared Gateway forwards" {
  acceptance="$root/scripts/acceptance-test.sh"
  run bash -c '
    block="$(sed -n "/if \[\[ \" \\$\* \" == .*signalloom-test-1/,/^else$/p" "$1")"
    grep -F "fe-signalloom" <<<"$block" >/dev/null
    grep -F "inf-signalloom" <<<"$block" >/dev/null
    grep -F "envoy-gateway-system" <<<"$block" >/dev/null
    test "$(grep -c "start_port_forward" <<<"$block")" -eq 3
    grep -F "DASHBOARD_URL" <<<"$block" >/dev/null
    grep -F "SIGNALLOOM_API_URL" <<<"$block" >/dev/null
    grep -F "SIGNALLOOM_DEX_URL" <<<"$block" >/dev/null
    ! grep -E "olly-replica|osramp-archivista|namespace/(frontend|backend)" <<<"$block"
  ' _ "$acceptance"
  [ "$status" -eq 0 ]
  run grep -F '127.0.0.1:8675' "$root/test/acceptance/signalloom-test-1.spec.ts"
  [ "$status" -ne 0 ]
}
@test "TEST-1 acceptance preflight validates dashboard readiness semantics" {
  acceptance="$root/scripts/acceptance-test.sh"
  run grep -F '${DASHBOARD_URL}/readyz' "$acceptance"
  [ "$status" -eq 0 ]
  run grep -F '[[ "$dashboard_ready" != "ready" ]]' "$acceptance"
  [ "$status" -eq 0 ]
}

@test "TEST-1 discovers the shared Gateway data-plane Service dynamically" {
  acceptance="$root/scripts/acceptance-test.sh"
  run grep -F 'kubectl get service -A' "$acceptance"
  [ "$status" -eq 0 ]
  run grep -F 'read -r gateway_namespace gateway_service' "$acceptance"
  [ "$status" -eq 0 ]
  run grep -F 'gateway_node_port=' "$acceptance"
  [ "$status" -eq 0 ]
}

@test "TEST-1 preserves the Gateway listener hostname through local access" {
  acceptance="$root/scripts/acceptance-test.sh"
  config="$root/test/acceptance/playwright.config.ts"
  run grep -F 'dashboard.osramp.acme.local:${gateway_node_port}' "$acceptance"
  [ "$status" -eq 0 ]
  run grep -F 'host-resolver-rules=MAP dashboard.osramp.acme.local ${gatewayAddress}' "$config"
  [ "$status" -eq 0 ]
}

@test "TEST-1 defaults its documented local-only password while preserving overrides" {
  spec="$root/test/acceptance/signalloom-test-1.spec.ts"
  run make -n demo-signalloom-test-1
  [ "$status" -eq 0 ]
  [[ "$output" == *'DEX_DEMO_PASSWORD="${DEX_DEMO_PASSWORD:-demo-user}"'* ]]
  run grep -F 'process.env.DEX_DEMO_PASSWORD' "$spec"
  [ "$status" -eq 0 ]
  run grep -F '.fill("demo-user")' "$spec"
  [ "$status" -ne 0 ]
}

@test "Dex local demo credential is documented and bcrypt protected" {
  dex="$root/d2-signalloom/infra/inf-signalloom/base/dex.yaml"
  design="$root/docs/signalloom/dex-oidc-design.md"
  run grep -E 'hash: [$]2[ayb][$]10[$]' "$dex"
  [ "$status" -eq 0 ]
  run grep -F '| Password | `demo-user` |' "$design"
  [ "$status" -eq 0 ]
  run grep -F 'principal-approved on 2026-07-27' "$design"
  [ "$status" -eq 0 ]
  run grep -F 'self-contained local-only demo' "$design"
  [ "$status" -eq 0 ]
}
