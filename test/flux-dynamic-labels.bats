#!/usr/bin/env bats
# Tests for check-flux-dynamic-labels.sh.
#
# The rule under test is BOTH, not either: a runtime-owned field must be
# DECLARED in a Flux-managed manifest AND covered by a `.spec.ignore` JSON
# Pointer. Measured with a matched control in
# docs/signalloom/_research-flux-ignore.md (TEST G / TEST H):
#
#   declared, NOT ignored     -> reverted on reconcile        (the original bug)
#   NOT declared, ignored     -> field DELETED outright       (strictly worse)
#   declared AND ignored      -> survives                     (correct)
#
# An earlier version of this suite asserted the middle row was the fix, which
# made CI enforce the falsified option and block the correct one. Each red-path
# test below constructs the failing condition and proves the checker bites — a
# checker that cannot go red converts "we have a test for that" into a false
# statement.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  CHECK="${REPO_ROOT}/scripts/check-flux-dynamic-labels.sh"
  FIXTURE="$(mktemp -d)"
  mkdir -p "${FIXTURE}/d2-signalloom/apps/thing" "${FIXTURE}/d2-osramp-fleet"
}

teardown() { rm -rf "$FIXTURE"; }

run_fixture() { CHECK_ROOT="$FIXTURE" run "$CHECK"; }

# All three fields declared on a pod.
declare_all() {
  cat > "${FIXTURE}/d2-signalloom/apps/thing/pod.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  labels:
    signalloom.ai/state: idle
  annotations:
    signalloom.ai/stunned-at: ""
    signalloom.ai/stun-reason: ""
YAML
}

# Kustomization ignoring all three JSON Pointer paths.
ignore_all() {
  cat > "${FIXTURE}/d2-osramp-fleet/apps.yaml" <<'YAML'
spec:
  ignore:
    - target: {kind: Pod}
      paths:
        - /metadata/labels/signalloom.ai~1state
        - /metadata/annotations/signalloom.ai~1stunned-at
        - /metadata/annotations/signalloom.ai~1stun-reason
YAML
}

@test "the real repository passes" {
  run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"declared AND covered"* ]]
}

@test "PASSES when every field is declared and ignored" {
  declare_all; ignore_all
  run_fixture
  [ "$status" -eq 0 ]
}

@test "FAILS when a field is declared but NOT ignored — the original bug" {
  declare_all
  run_fixture
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO .spec.ignore rule covers it"* ]]
}

@test "FAILS when a field is ignored but NOT declared — strictly worse than the bug" {
  ignore_all
  run_fixture
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT DECLARED"* ]]
}

@test "FAILS when only the label is handled and the annotations are forgotten" {
  # The exact shape of the first shipped fix: the label was reasoned about and
  # the two stun annotations were missed entirely.
  cat > "${FIXTURE}/d2-signalloom/apps/thing/pod.yaml" <<'YAML'
metadata:
  labels:
    signalloom.ai/state: idle
YAML
  cat > "${FIXTURE}/d2-osramp-fleet/apps.yaml" <<'YAML'
spec:
  ignore:
    - paths: ["/metadata/labels/signalloom.ai~1state"]
YAML
  run_fixture
  [ "$status" -eq 1 ]
  [[ "$output" == *"stunned-at"* ]]
}

@test "a policy SELECTOR does not count as a declaration" {
  # A quarantine NetworkPolicy legitimately selects on the field. If a selector
  # satisfied the declaration requirement, a repo could pass with no real
  # declaration anywhere and the field would still be dropped on apply.
  ignore_all
  cat > "${FIXTURE}/d2-signalloom/apps/thing/netpol.yaml" <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
spec:
  podSelector:
    matchLabels:
      signalloom.ai/state: stunned
YAML
  run_fixture
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT DECLARED"* ]]
}

@test "a commented-out declaration does not count" {
  ignore_all
  cat > "${FIXTURE}/d2-signalloom/apps/thing/pod.yaml" <<'YAML'
metadata:
  labels:
    # signalloom.ai/state: idle
    app: thing
YAML
  run_fixture
  [ "$status" -eq 1 ]
}

@test "deep ResourceSet indentation still counts as a declaration" {
  ignore_all
  cat > "${FIXTURE}/d2-osramp-fleet/rs.yaml" <<'YAML'
spec:
  ignore:
    - paths:
        - /metadata/labels/signalloom.ai~1state
        - /metadata/annotations/signalloom.ai~1stunned-at
        - /metadata/annotations/signalloom.ai~1stun-reason
  resources:
    - kind: Pod
      metadata:
        labels:
                    signalloom.ai/state: idle
        annotations:
                    signalloom.ai/stunned-at: ""
                    signalloom.ai/stun-reason: ""
YAML
  rm -f "${FIXTURE}/d2-osramp-fleet/apps.yaml"
  run_fixture
  [ "$status" -eq 0 ]
}
