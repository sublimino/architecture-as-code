#!/usr/bin/env bats

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  routes="$repo_root/d2-signalloom/apps/fe-signalloom/base/gateway-route.yaml"
  makefile="$repo_root/Makefile"
}

@test "Gateway routes dashboard root and API through distinct bound Services" {
  run kubectl kustomize "$repo_root/d2-signalloom/apps/fe-signalloom/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: signalloom-dashboard"* ]]
  [[ "$output" == *"value: /"* ]]
  [[ "$output" == *"name: dashboard-signalloom"* ]]
  [[ "$output" == *"port: 8080"* ]]
  [[ "$output" == *"name: signalloom-api"* ]]
  [[ "$output" == *"value: /api"* ]]
  [[ "$output" == *"name: fe-signalloom-api"* ]]
  [[ "$output" == *"port: 8000"* ]]
  [[ "$output" == *"namespace: ingress"* ]]
  [[ "$output" == *"sectionName: https"* ]]
}

@test "Gateway route package includes dashboard workload and gateway-only policies" {
  run kubectl kustomize "$repo_root/d2-signalloom/apps/fe-signalloom/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: dashboard-signalloom"* ]]
  [[ "$output" == *"containerPort: 8080"* ]]
  [[ "$output" == *"name: allow-dashboard-gateway-ingress"* ]]
  [[ "$output" == *"name: allow-api-gateway-ingress"* ]]
  [[ "$output" == *"kubernetes.io/metadata.name: ingress"* ]]
  [[ "$output" == *"gateway.envoyproxy.io/owning-gateway-name: cluster"* ]]
}

@test "Dashboard permits nginx temporary files under read-only root" {
  run kubectl kustomize "$repo_root/d2-signalloom/apps/fe-signalloom/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: nginx-tmp"* ]]
  [[ "$output" == *"mountPath: /tmp"* ]]
  [[ "$output" == *"emptyDir: {}"* ]]
}

@test "Local lifecycle publishes the dashboard image selected by root routing" {
  run grep -F 'signalloom/apps/dashboard-signalloom:latest' "$makefile"
  [ "$status" -eq 0 ]
  run grep -F 'd2-signalloom/apps/dashboard-signalloom' "$makefile"
  [ "$status" -eq 0 ]
  run grep -F 'kind load docker-image --name $(CLUSTER_NAME) zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/dashboard-signalloom:latest' "$makefile"
  [ "$status" -eq 0 ]
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
