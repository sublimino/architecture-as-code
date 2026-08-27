#!/usr/bin/env bats

# triage-ci-worker: validate the Tier 2 deterministic worker agent's
# structure, manifests, parser logic, and HTTP contract.

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  app_dir="$root/d2-signalloom/apps/triage-ci-worker"
  infra_dir="$root/d2-signalloom/infra/agent-swarm/triage-ci-worker"
}

# -- Structure --

@test "triage-ci-worker: main.go exists" {
  [[ -f "$app_dir/main.go" ]]
}

@test "triage-ci-worker: parser.go exists" {
  [[ -f "$app_dir/parser.go" ]]
}

@test "triage-ci-worker: parser_test.go exists" {
  [[ -f "$app_dir/parser_test.go" ]]
}

@test "triage-ci-worker: Dockerfile exists" {
  [[ -f "$app_dir/Dockerfile" ]]
}

@test "triage-ci-worker: go.mod exists and names the correct module" {
  [[ -f "$app_dir/go.mod" ]]
  grep -q 'module.*triage-ci-worker' "$app_dir/go.mod"
}

@test "triage-ci-worker: Dockerfile uses wolfi-base" {
  grep -q 'cgr.dev/chainguard/wolfi-base' "$app_dir/Dockerfile"
}

@test "triage-ci-worker: Dockerfile includes gh CLI" {
  grep -q 'github-cli' "$app_dir/Dockerfile"
}

@test "triage-ci-worker: Dockerfile disables CGO and buildvcs" {
  grep -q 'CGO_ENABLED=0' "$app_dir/Dockerfile"
  grep -q 'buildvcs=false' "$app_dir/Dockerfile"
}

# -- K8s manifests --

@test "triage-ci-worker: knative-service.yaml exists with correct labels" {
  [[ -f "$infra_dir/knative-service.yaml" ]]
  grep -q 'signalloom.ai/agent.*true' "$infra_dir/knative-service.yaml"
  grep -q 'signalloom.ai/role.*triage' "$infra_dir/knative-service.yaml"
  grep -q 'signalloom.ai/harness.*go-worker' "$infra_dir/knative-service.yaml"
  grep -q 'signalloom.ai/model.*deterministic' "$infra_dir/knative-service.yaml"
  grep -q 'signalloom.ai/tenant.*controlplane' "$infra_dir/knative-service.yaml"
  grep -q 'signalloom.ai/project.*osramp' "$infra_dir/knative-service.yaml"
}

@test "triage-ci-worker: service-account.yaml exists in fe-signalloom-agents" {
  [[ -f "$infra_dir/service-account.yaml" ]]
  grep -q 'namespace: fe-signalloom-agents' "$infra_dir/service-account.yaml"
  grep -q 'name: triage-ci-worker' "$infra_dir/service-account.yaml"
}

@test "triage-ci-worker: kustomization.yaml references both resources" {
  [[ -f "$infra_dir/kustomization.yaml" ]]
  grep -q 'service-account.yaml' "$infra_dir/kustomization.yaml"
  grep -q 'knative-service.yaml' "$infra_dir/kustomization.yaml"
}

@test "triage-ci-worker: knative-service has scale-to-zero annotation" {
  grep -q 'autoscaling.knative.dev/min-scale.*"0"' "$infra_dir/knative-service.yaml"
}

# -- Go source contract --

@test "triage-ci-worker: main.go handles /health endpoint" {
  grep -q '/health' "$app_dir/main.go"
}

@test "triage-ci-worker: main.go validates CloudEvent type header" {
  grep -q 'Ce-Type' "$app_dir/main.go"
  grep -q 'dev.knative.source.github.check_run' "$app_dir/main.go"
}

@test "triage-ci-worker: parser.go exports ParseFailures" {
  grep -q 'func ParseFailures' "$app_dir/parser.go"
}

@test "triage-ci-worker: parser.go exports DeduplicateFlaky" {
  grep -q 'func DeduplicateFlaky' "$app_dir/parser.go"
}

@test "triage-ci-worker: parser.go exports FormatTriageComment" {
  grep -q 'func FormatTriageComment' "$app_dir/parser.go"
}

@test "triage-ci-worker: parser.go exports SuggestLabels" {
  grep -q 'func SuggestLabels' "$app_dir/parser.go"
}

@test "triage-ci-worker: main.go uses gh CLI for GitHub interaction" {
  grep -q '"gh"' "$app_dir/main.go"
}

@test "triage-ci-worker: main.go reads GITHUB_REPO from env" {
  grep -q 'GITHUB_REPO' "$app_dir/main.go"
}

# -- Go unit tests pass --

@test "triage-ci-worker: parser unit tests pass" {
  cd "$app_dir"
  run go test -v -count=1 ./...
  echo "$output"
  [[ "$status" -eq 0 ]]
}
