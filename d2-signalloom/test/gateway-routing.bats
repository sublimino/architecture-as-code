#!/usr/bin/env bats

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  routes="$repo_root/d2-signalloom/apps/fe-signalloom/base/gateway-route.yaml"
}

@test "Gateway routes dashboard root and API through bound Services" {
  run kubectl kustomize "$repo_root/d2-signalloom/apps/fe-signalloom/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: signalloom-dashboard"* ]]
  [[ "$output" == *"value: /"* ]]
  [[ "$output" == *"name: fe-signalloom"* ]]
  [[ "$output" == *"name: signalloom-api"* ]]
  [[ "$output" == *"value: /api"* ]]
  [[ "$output" == *"name: fe-signalloom-api"* ]]
  [[ "$output" == *"namespace: ingress"* ]]
  [[ "$output" == *"sectionName: https"* ]]
}

@test "Gateway exposes no internal Signalloom dependency" {
  run grep -E 'name: (fake-integration-proxy|dex|postgres|redis|minio)' "$routes"
  [ "$status" -ne 0 ]

  run kubectl kustomize "$repo_root/d2-signalloom/infra/inf-signalloom/configs/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: default-deny"* ]]
  [[ "$output" == *"name: allow-fake-integration-proxy"* ]]
  [[ "$output" == *"port: 8080"* ]]
}
