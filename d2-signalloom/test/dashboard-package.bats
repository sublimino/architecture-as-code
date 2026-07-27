#!/usr/bin/env bats

setup() {
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  dashboard="$root/d2-signalloom/apps/dashboard-signalloom"
  deployment="$root/d2-signalloom/apps/fe-signalloom/base/dashboard-deployment.yaml"
  service="$root/d2-signalloom/apps/fe-signalloom/base/dashboard-service.yaml"
}

@test "Dashboard image builds React assets into nginx runtime" {
  run grep -F 'FROM node:22-alpine AS build' "$dashboard/Dockerfile"
  [ "$status" -eq 0 ]
  run grep -F 'npm ci' "$dashboard/Dockerfile"
  [ "$status" -eq 0 ]
  run grep -F 'FROM nginxinc/nginx-unprivileged:1.27-alpine' "$dashboard/Dockerfile"
  [ "$status" -eq 0 ]
  run grep -F 'EXPOSE 8080' "$dashboard/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "Nginx falls back to index while retaining static paths" {
  run grep -F 'try_files $uri $uri/ /index.html;' "$dashboard/nginx.conf"
  [ "$status" -eq 0 ]
  run grep -F 'location = /readyz' "$dashboard/nginx.conf"
  [ "$status" -eq 0 ]
}

@test "Dashboard Deployment exposes a ready nginx workload" {
  run yq -e 'select(.kind == "Deployment") | (.metadata.name == "dashboard-signalloom" and .spec.template.spec.containers[0].image == "${IMAGE_BASE}/signalloom/apps/dashboard-signalloom:${ARTIFACT_TAG}" and .spec.template.spec.containers[0].ports[0].containerPort == 8080 and .spec.template.spec.containers[0].readinessProbe.httpGet.path == "/readyz")' "$deployment"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "Dashboard Service selects nginx port" {
  run yq -e '(.kind == "Service" and .metadata.name == "dashboard-signalloom" and .spec.selector["app.kubernetes.io/name"] == "dashboard-signalloom" and .spec.ports[0].port == 8080 and .spec.ports[0].targetPort == "http")' "$service"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}
