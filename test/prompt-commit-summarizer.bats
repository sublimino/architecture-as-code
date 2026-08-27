#!/usr/bin/env bats

# prompt-commit-summarizer: validate the Tier 1 stateless prompt function
# agent's structure, manifests, and HTTP contract.

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  app_dir="$root/d2-signalloom/apps/prompt-commit-summarizer"
  infra_dir="$root/d2-signalloom/infra/agent-swarm/prompt-commit-summarizer"
}

# -- Structure --

@test "prompt-commit-summarizer: main.go exists" {
  [[ -f "$app_dir/main.go" ]]
}

@test "prompt-commit-summarizer: Dockerfile exists" {
  [[ -f "$app_dir/Dockerfile" ]]
}

@test "prompt-commit-summarizer: go.mod exists and names the correct module" {
  [[ -f "$app_dir/go.mod" ]]
  grep -q 'module.*prompt-commit-summarizer' "$app_dir/go.mod"
}

@test "prompt-commit-summarizer: Dockerfile uses distroless static base" {
  grep -q 'cgr.dev/chainguard/static' "$app_dir/Dockerfile"
}

@test "prompt-commit-summarizer: Dockerfile disables CGO and buildvcs" {
  grep -q 'CGO_ENABLED=0' "$app_dir/Dockerfile"
  grep -q 'buildvcs=false' "$app_dir/Dockerfile"
}

# -- K8s manifests --

@test "prompt-commit-summarizer: knative-service.yaml exists with correct labels" {
  [[ -f "$infra_dir/knative-service.yaml" ]]
  grep -q 'signalloom.ai/agent.*true' "$infra_dir/knative-service.yaml"
  grep -q 'signalloom.ai/role.*summarizer' "$infra_dir/knative-service.yaml"
  grep -q 'signalloom.ai/harness.*go-static' "$infra_dir/knative-service.yaml"
  grep -q 'signalloom.ai/model.*gemini-2.5-flash' "$infra_dir/knative-service.yaml"
  grep -q 'signalloom.ai/tenant.*controlplane' "$infra_dir/knative-service.yaml"
  grep -q 'signalloom.ai/project.*osramp' "$infra_dir/knative-service.yaml"
}

@test "prompt-commit-summarizer: service-account.yaml exists in fe-signalloom-agents" {
  [[ -f "$infra_dir/service-account.yaml" ]]
  grep -q 'namespace: fe-signalloom-agents' "$infra_dir/service-account.yaml"
  grep -q 'name: prompt-commit-summarizer' "$infra_dir/service-account.yaml"
}

@test "prompt-commit-summarizer: kustomization.yaml references both resources" {
  [[ -f "$infra_dir/kustomization.yaml" ]]
  grep -q 'service-account.yaml' "$infra_dir/kustomization.yaml"
  grep -q 'knative-service.yaml' "$infra_dir/kustomization.yaml"
}

@test "prompt-commit-summarizer: knative-service has scale-to-zero annotation" {
  grep -q 'autoscaling.knative.dev/min-scale.*"0"' "$infra_dir/knative-service.yaml"
}

@test "prompt-commit-summarizer: knative-service has resource limits" {
  grep -q 'limits:' "$infra_dir/knative-service.yaml"
  grep -q 'cpu:' "$infra_dir/knative-service.yaml"
  grep -q 'memory:' "$infra_dir/knative-service.yaml"
}

@test "prompt-commit-summarizer: knative-service has health probes" {
  grep -q 'livenessProbe:' "$infra_dir/knative-service.yaml"
  grep -q 'readinessProbe:' "$infra_dir/knative-service.yaml"
}

# -- Go source contract --

@test "prompt-commit-summarizer: main.go handles /health endpoint" {
  grep -q '/health' "$app_dir/main.go"
}

@test "prompt-commit-summarizer: main.go reads LLM_ENDPOINT from env" {
  grep -q 'LLM_ENDPOINT' "$app_dir/main.go"
}

@test "prompt-commit-summarizer: main.go validates CloudEvent type header" {
  grep -q 'Ce-Type' "$app_dir/main.go"
  grep -q 'dev.knative.source.github.push' "$app_dir/main.go"
}

@test "prompt-commit-summarizer: main.go truncates large diffs" {
  grep -q 'maxDiffLen' "$app_dir/main.go"
}

@test "prompt-commit-summarizer: main.go returns commit_message and confidence" {
  grep -q 'commit_message' "$app_dir/main.go"
  grep -q 'confidence' "$app_dir/main.go"
}
