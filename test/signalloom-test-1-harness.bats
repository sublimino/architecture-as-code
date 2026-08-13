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

@test "TEST-1 browser cases enumerate the committed React SPA journeys" {
  spec="$root/test/acceptance/signalloom-test-1.spec.ts"
  run bash -c '
    for journey in "Dashboard root" Agents Compliance "Audit Trail" Cryptography \
      "Federated Services" "Collusion & Access" Settings; do
      grep -F "[\"$journey\"" "$1" >/dev/null || exit 1
    done
  ' _ "$spec"
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

# The spec-name gate may select FORWARDS and nothing else.
#
# This assertion used to run every check inside a single `bash -c` with no
# `set -e`, so only the last command decided the status and every grep above it
# was dead — it reported green against a script that had already stopped
# satisfying most of them. Each condition is now its own bats assertion, so a
# violation names itself.
@test "TEST-1 acceptance narrows only its forward set" {
  acceptance="$root/scripts/acceptance-test.sh"
  run bash -c 'sed -n "/signalloom-test-1.spec.ts.*then/,/^else/p" "$1"' _ "$acceptance"
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  # TEST-1 is the slice-isolation harness: signalloom forwards only.
  [[ "$output" == *"fe-signalloom"* ]]
  [[ "$output" == *"inf-signalloom"* ]]
  [[ "$output" != *"olly-replica"* ]]
  [[ "$output" != *"osramp-archivista"* ]]
  [[ "$output" != *"kube-prometheus-stack-grafana"* ]]

  # Anything EVERY Dex-authenticating spec needs must live outside this branch.
  [[ "$output" != *"setup_gateway_forward"* ]]
  [[ "$output" != *"SIGNALLOOM_API_URL"* ]]
  [[ "$output" != *"SIGNALLOOM_DEX_URL"* ]]

  run grep -F '127.0.0.1:8675' "$root/test/acceptance/signalloom-test-1.spec.ts"
  [ "$status" -ne 0 ]
}

# CI stage 8b failed 18/18 on both lanes because setup that every spec needs was
# reachable only through a spec-name allowlist. Adding the next spec to that
# allowlist would have repeated it, so the invariant worth guarding is that the
# allowlist cannot grow a second member and cannot acquire shared setup.
@test "acceptance Gateway setup and Signalloom URLs run for every spec" {
  acceptance="$root/scripts/acceptance-test.sh"

  # Exactly one branch in the whole script may inspect argv.
  run grep -cF '$*' "$acceptance"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]

  # Column 0 is top level in this script; every branch body is indented.
  run grep -c '^setup_gateway_forward$' "$acceptance"
  [ "$output" -eq 1 ]
  run grep -c '^export SIGNALLOOM_API_URL=' "$acceptance"
  [ "$output" -eq 1 ]
  run grep -c '^export SIGNALLOOM_DEX_URL=' "$acceptance"
  [ "$output" -eq 1 ]
}

# Every Chrome the suite launches must resolve the SNI-only Gateway hostname.
# Declaring the resolver rule per project made omission the default and cost
# stage 8b every one of its tests with net::ERR_NAME_NOT_RESOLVED.
@test "acceptance Playwright resolves the Gateway hostname for every project" {
  config="$root/test/acceptance/playwright.config.ts"
  run grep -c 'host-resolver-rules=MAP dashboard.osramp.acme.local' "$config"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
  # Exactly one launchOptions DECLARATION. Playwright merges `use` shallowly per
  # key, so a project-level launchOptions replaces the shared one wholesale and
  # would silently drop the resolver rule again.
  run grep -cE '^ *launchOptions: \{' "$config"
  [ "$output" -eq 1 ]
}
@test "TEST-1 acceptance preflight validates dashboard readiness semantics" {
  acceptance="$root/scripts/acceptance-test.sh"
  run grep -F '${DASHBOARD_URL}/readyz' "$acceptance"
  [ "$status" -eq 0 ]
  run grep -F '[[ "$dashboard_ready" != "ready" ]]' "$acceptance"
  [ "$status" -eq 0 ]
}

@test "TEST-1 acceptance reuses healthy existing local listeners" {
  acceptance="$root/scripts/acceptance-test.sh"
  run grep -F 'nc -z 127.0.0.1 "${local_port}"' "$acceptance"
  [ "$status" -eq 0 ]
  run grep -F 'reusing existing listener on localhost:${local_port}' "$acceptance"
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
  run grep -F 'dashboard.osramp.acme.local' "$acceptance"
  [ "$status" -eq 0 ]
  config="$root/test/acceptance/playwright.config.ts"
  run grep -F 'host-resolver-rules=MAP dashboard.osramp.acme.local' "$config"
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
