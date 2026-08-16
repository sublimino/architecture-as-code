#!/usr/bin/env bats
#
# Deployment-time guard: no unsubstituted ${VAR} tokens in live Flux objects.
#
# Flux's postBuild.substituteFrom is a SILENT no-op when a key is missing from its
# source — the token is left literal, the apply succeeds, and the object is marked
# Ready=True. Nothing retries. So "all Kustomizations Ready" is not evidence the
# estate reconciled correctly, and this is the check that closes that gap.
#
# Deliberately a detector, not a fix. The remaining intra-ResourceSet race (a
# copyFrom ConfigMap and the Kustomization that substitutes from it sharing one
# unordered resources: list) is not structurally fixed — see AGENTS.md. This makes
# it loud at deploy time instead of silent forever.

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  CHECK="${REPO_ROOT}/scripts/check-flux-substitution.sh"
  CANARY_NS="default"
  CANARY_NAME="subst-check-canary-bats"
}

teardown() {
  kubectl delete ocirepository "${CANARY_NAME}" -n "${CANARY_NS}" \
    --ignore-not-found >/dev/null 2>&1 || true
}

cluster_up() {
  kubectl cluster-info >/dev/null 2>&1
}

@test "the substitution check script exists and is executable" {
  [ -x "${CHECK}" ]
}

@test "live Flux objects carry no unsubstituted \${VAR} tokens" {
  cluster_up || skip "no cluster reachable"
  run "${CHECK}"
  [ "$status" -eq 0 ]
}

@test "the check FAILS when a token survives — it can detect what it claims to" {
  cluster_up || skip "no cluster reachable"

  # A test that only ever passes proves nothing. Inject a literal ${ARTIFACT_TAG}
  # into a live Flux object and assert the check goes red. The canary points at an
  # invalid host and is consumed by nothing, so it cannot affect the estate.
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: ${CANARY_NAME}
  namespace: ${CANARY_NS}
spec:
  interval: 60m
  url: oci://example.invalid/canary
  ref:
    tag: \${ARTIFACT_TAG}
EOF

  run "${CHECK}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FLUX SUBSTITUTION CHECK: FAILED"* ]]
  [[ "$output" == *"${CANARY_NAME}"* ]]
  [[ "$output" == *'${ARTIFACT_TAG}'* ]]
}

@test "the check passes again once the offending object is removed" {
  cluster_up || skip "no cluster reachable"
  kubectl delete ocirepository "${CANARY_NAME}" -n "${CANARY_NS}" \
    --ignore-not-found >/dev/null 2>&1 || true
  run "${CHECK}"
  [ "$status" -eq 0 ]
}

@test "allowlisted tokens are not flagged" {
  cluster_up || skip "no cluster reachable"

  # Grafana dashboards ship ${DS_PROMETHEUS} for their own render-time expansion
  # and SPIRE carries ${JOIN_TOKEN} for -expandEnv. Neither is Flux's to
  # substitute, so neither may fail the deploy.
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: ${CANARY_NAME}
  namespace: ${CANARY_NS}
spec:
  interval: 60m
  url: oci://example.invalid/canary
  ref:
    tag: \${DS_PROMETHEUS}
EOF

  run "${CHECK}"
  [ "$status" -eq 0 ]
}

@test "the substitution check reports CANNOT VERIFY rather than success when it cannot look" {
  # The defect this pins, reproduced 2026-08-16 against the shipped script:
  #
  #   $ KUBECONFIG=/nonexistent bash scripts/check-flux-substitution.sh
  #   flux substitution check: no unsubstituted ${VAR} tokens in live Flux objects
  #   EXIT=0
  #
  # `kubectl get … 2>/dev/null || true` swallowed every failure mode at once, so
  # an empty result was indistinguishable from a clean one. A compensating
  # control for a known-unfixed race, printing success against no cluster at all
  # -- the exact silent no-op it exists to catch, living inside it.
  #
  # This matters more than it looks: the guard is only worth putting in CI if it
  # can fail. A green stage that proves nothing is worse than no stage.
  run env KUBECONFIG=/nonexistent-kubeconfig-for-bats \
    bash "${REPO_ROOT}/scripts/check-flux-substitution.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "the substitution check reports CANNOT VERIFY when it scans zero objects" {
  # The quieter half of the same lie. A kinds list matching no CRD, or a context
  # pointing at a cluster with no Flux, examines nothing -- and "nothing was
  # wrong with the nothing I looked at" is not a pass.
  run env FLUX_SUBST_KINDS=nosuchkind.example.com \
    bash "${REPO_ROOT}/scripts/check-flux-substitution.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ZERO Flux objects"* ]]
}

@test "CI runs the substitution check, not just make healthcheck" {
  # Item 5 on the leverage-ordered fix list: "move the substitution guard from
  # make healthcheck into CI -- catch at PR, not deploy". It had never been
  # done. The script was reachable only from healthcheck.sh, which no CI stage
  # invokes, so a literal ${VAR} in live Flux objects passed every CI run.
  #
  # Guard the wiring, because the wiring is the whole fix.
  #
  # Comments are stripped first, and that is not fussiness. The first version of
  # this test grepped the whole file, and the stage above carries a long comment
  # block naming the script -- so replacing the actual invocation with `true`
  # left this test GREEN. It counted a string in a comment and called it wiring:
  # decorative, in precisely the way this repo keeps getting caught by. Only the
  # mutation proof exposed it.
  run bash -c "grep -vE '^[[:space:]]*#' '${REPO_ROOT}/scripts/ci/vm-pipeline.sh' | grep -c 'check-flux-substitution\.sh'"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "healthcheck.sh invokes the substitution check" {
  # Ready=True is necessary but not sufficient; the foundation is not "healthy"
  # until this has run. Guard the wiring so it cannot be quietly dropped.
  run grep -c 'check-flux-substitution.sh' "${REPO_ROOT}/scripts/healthcheck.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}
