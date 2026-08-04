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
  wait_flux_ready resourceset "$name" -n flux-system 600
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
  # Wait for the object to EXIST before patching it.
  #
  # These ResourceSets are delivered by the flux-system/tenants Kustomization,
  # which reconciles asynchronously. Patching one that has not arrived yet
  # fails outright:
  #
  #   Error from server (NotFound): resourcesets.fluxcd.controlplane.io
  #   "signalloom-infra" not found
  #
  # and under `set -euo pipefail` that aborts `up` on its first activation. The
  # CI pipeline then falls back to patching signalloom-APPS only, leaving
  # signalloom-infra inactive, so infra-controllers is never created and every
  # later stage fails against a cluster that was never brought up. The run is
  # reported as "aborted, NOT a test failure", which is accurate and points
  # nowhere near the cause.
  #
  # Purely a race, and it only loses on a cold cluster: on a warm one the
  # ResourceSets are already present from an earlier run, which is why this
  # survived every local run and lost on a VM built from nothing. The wait is
  # generous because it costs nothing when the object is already there.
  wait_k8s_exists resourceset "${name}" -n flux-system 300
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
  #
  # `appsTenant` on the INFRA inputs is not redundant with `tenant`. The
  # SuperCred runner's cross-namespace RBAC has to be declared by
  # signalloom-infra (a RoleBinding created by signalloom-apps trips the
  # kustomize-controller privilege-escalation dry run -- see the long comment
  # in tenants/local/signalloom.yaml), but its SUBJECT is a ServiceAccount in
  # the APPS tenant. `tenant` here is inf-bao / inf-signalloom, so templating
  # the subject off it named a ServiceAccount that never existed and left the
  # runner with no authority at all -- silently, because RBAC does not
  # validate subjects. Both infra inputs carry the same appsTenant value, and
  # it MUST equal the apps activation's `tenant` below;
  # d2-signalloom/test/supercred-runner-rbac.bats asserts exactly that.
  activate_resourceset signalloom-infra '[{"appsTenant":"fe-signalloom","artifactSubjectGitRef":"local","artifactSubjectWorkflow":"local","component":"inf-bao","environment":"local","tag":"latest","tenant":"inf-bao"},{"appsTenant":"fe-signalloom","artifactSubjectGitRef":"local","artifactSubjectWorkflow":"local","component":"inf-signalloom","environment":"local","tag":"latest","tenant":"inf-signalloom"}]'
  wait_resourceset signalloom-infra
  wait_namespace inf-bao
  "$repo_root/scripts/demo-lifecycle.sh" bao-up
  wait_namespace inf-signalloom
  # The agent-inventory namespace + cross-namespace RBAC are now in
  # inf-signalloom/configs (deployed by signalloom-infra above), so the
  # namespace and Roles exist before the apps kustomization applies.
  activate_resourceset signalloom-apps '[{"artifactSubjectGitRef":"local","artifactSubjectWorkflow":"local","component":"fe-signalloom","environment":"fe-signalloom/local","tag":"latest","tenant":"fe-signalloom"}]'
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
