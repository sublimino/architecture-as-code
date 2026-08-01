#!/usr/bin/env bash
# Deterministic local lifecycle for the Phase 1 Signal Loom Flux slice.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
readonly repo_root
# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"
readonly timeout="${DEMO_WAIT_TIMEOUT:-10m}"

usage() {
  cat <<'EOF'
Usage: signalloom-local.sh <up|verify>

up      create Kind/zot/Flux (unless SIGNALLOOM_SKIP_PREPARE=1), then reconcile
        inf-bao, inf-signalloom, and fe-signalloom in that order.
verify  assert the three Flux tenants and their Phase 1 reconciliation state.
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'required command unavailable: %s\n' "$1" >&2
    exit 1
  }
}

wait_resourceset() {
  local name="$1"
  printf 'waiting for Flux ResourceSet/%s\n' "$name"
  wait_flux_ready ResourceSet "$name" -n flux-system 600
}

wait_namespace() {
  local namespace="$1"
  printf 'waiting for tenant namespace/%s\n' "$namespace"
  wait_k8s_exists namespace "$namespace" 120
}

prepare() {
  if [[ "${SIGNALLOOM_SKIP_PREPARE:-0}" == 1 ]]; then
    return 0
  fi
  # `make up` creates the shared foundation without starting a demo.
  make -C "$repo_root" up
  make -C "$repo_root" push-local-signalloom
  make -C "$repo_root" signalloom-spire-helper
  make -C "$repo_root" signalloom-images
}

activate_resourceset() {
  local name="$1" inputs="$2"
  kubectl -n flux-system patch "resourceset/${name}" --type merge \
    -p "{\"spec\":{\"inputs\":${inputs}}}"
  kubectl -n flux-system annotate "resourceset/${name}" \
    reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
}

up() {
  require_command kubectl
  require_command flux
  prepare

  # Both ResourceSets are inactive after `make up`; this explicit lifecycle
  # enables Signal Loom's infra first, then its frontend.
  activate_resourceset signalloom-infra '[{"artifactSubjectGitRef":"local","artifactSubjectWorkflow":"local","component":"inf-bao","environment":"local","tag":"latest","tenant":"inf-bao"},{"artifactSubjectGitRef":"local","artifactSubjectWorkflow":"local","component":"inf-signalloom","environment":"local","tag":"latest","tenant":"inf-signalloom"}]'
  wait_resourceset signalloom-infra
  wait_namespace inf-bao
  "$repo_root/scripts/demo-lifecycle.sh" bao-up
  wait_namespace inf-signalloom
  activate_resourceset signalloom-apps '[{"artifactSubjectGitRef":"local","artifactSubjectWorkflow":"local","component":"fe-signalloom","environment":"local","tag":"latest","tenant":"fe-signalloom"}]'
  "$repo_root/scripts/demo-lifecycle.sh" signalloom-up
  wait_resourceset signalloom-apps
  wait_namespace fe-signalloom
  "$repo_root/scripts/demo-lifecycle.sh" flux-test
  printf 'Signal Loom Phase 1 local reconciliation converged\n'
}

verify() {
  require_command kubectl
  "$repo_root/scripts/demo-lifecycle.sh" flux-test
  printf 'Signal Loom Phase 1 Flux verification passed\n'
}

case "${1:-}" in
  up) up ;;
  verify) verify ;;
  *) usage; exit 64 ;;
esac
