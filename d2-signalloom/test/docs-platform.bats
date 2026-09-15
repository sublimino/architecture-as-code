#!/usr/bin/env bats

setup() {
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  docs="$root/d2-signalloom/apps/docs-signalloom"
  deployment="$root/d2-signalloom/apps/fe-signalloom/base/docs-deployment.yaml"
  service="$root/d2-signalloom/apps/fe-signalloom/base/docs-service.yaml"
  route="$root/d2-signalloom/apps/fe-signalloom/base/gateway-route.yaml"
  policy="$root/d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml"
}

@test "Docs build uses Astro Starlight at the docs base path" {
  run grep -F 'base: "/docs"' "$docs/astro.config.mjs"
  [ "$status" -eq 0 ]
  run grep -F '@astrojs/starlight' "$docs/package.json"
  [ "$status" -eq 0 ]
  run grep -F '/app/dist /usr/share/nginx/html/docs' "$docs/Dockerfile"
  [ "$status" -eq 0 ]
  run grep -F 'FROM cgr.dev/chainguard/nginx:latest@sha256:' "$docs/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "Docs nginx serves health and fail-closed static routes" {
  run grep -F 'location = /readyz' "$docs/nginx.conf"
  [ "$status" -eq 0 ]
  run grep -F 'return 308 /docs/;' "$docs/nginx.conf"
  [ "$status" -eq 0 ]
  run grep -F 'try_files $uri $uri/ $uri/index.html =404;' "$docs/nginx.conf"
  [ "$status" -eq 0 ]
}

@test "Docs Deployment uses the signed image and hardened runtime" {
  run yq -e 'select(.kind == "Deployment") | (.metadata.name == "docs-signalloom" and .spec.template.spec.automountServiceAccountToken == false and .spec.template.spec.containers[0].image == "${IMAGE_BASE}/signalloom/apps/docs-signalloom:${ARTIFACT_TAG}" and .spec.template.spec.containers[0].readinessProbe.httpGet.path == "/readyz" and .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true and .spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation == false and .spec.template.spec.volumes[0].emptyDir.sizeLimit == "16Mi")' "$deployment"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "Docs source identity covers its build context" {
  run bash -c 'source "$1/scripts/lib/source-id.sh"; id="$(source_id_for docs-signalloom)"; [[ "$id" =~ ^[0-9a-f]{64}$ ]]' _ "$root"
  [ "$status" -eq 0 ]
}

@test "Docs publishing passes the source identity build argument" {
  workflow="$root/.github/workflows/push-images.yaml"
  run grep -F 'workload: docs-signalloom' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'SOURCE_ID=${{ steps.source.outputs.source_id }}' "$workflow"
  [ "$status" -eq 0 ]
}

@test "Docs Service selects the docs workload on port 8080" {
  run yq -e '(.kind == "Service" and .metadata.name == "docs-signalloom" and .spec.selector["app.kubernetes.io/name"] == "docs-signalloom" and .spec.ports[0].port == 8080)' "$service"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "Docs HTTPRoute owns the docs prefix without rewriting it" {
  run yq -e 'select(.kind == "HTTPRoute" and .metadata.name == "signalloom-docs") | (.spec.hostnames[0] == "dashboard.${CLUSTER_DOMAIN}" and .spec.rules[0].matches[0].path.value == "/docs" and .spec.rules[0].backendRefs[0].name == "docs-signalloom" and (.spec.rules[0].filters // [] | length) == 0)' "$route"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "Docs NetworkPolicy allows only Gateway ingress" {
  run yq -e 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-docs-gateway-ingress") | (.spec.podSelector.matchLabels["app.kubernetes.io/name"] == "docs-signalloom" and (.spec.policyTypes | length) == 1 and .spec.policyTypes[0] == "Ingress" and .spec.ingress[0].ports[0].port == 8080 and .spec.ingress[0].from[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "ingress")' "$policy"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "Docs content covers the requested user journeys" {
  for page in \
    start/quick-start.mdx \
    start/first-agent.md \
    start/external-linux-agent.mdx \
    operate/stun-agent.mdx \
    demos/superadmin.md \
    roles/view-only.md \
    roles/advanced.md \
    roles/security-team.md \
    roles/platform-admin.md \
    reference/roadmap.md; do
    [ -s "$docs/src/content/docs/$page" ]
  done
}
