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

@test "healthcheck.sh invokes the substitution check" {
  # Ready=True is necessary but not sufficient; the foundation is not "healthy"
  # until this has run. Guard the wiring so it cannot be quietly dropped.
  run grep -c 'check-flux-substitution.sh' "${REPO_ROOT}/scripts/healthcheck.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}
