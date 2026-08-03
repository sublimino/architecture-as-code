#!/usr/bin/env bats
# Unit tests for check-flux-dynamic-labels.sh.
#
# The checker guards against a silent failure: a runtime-owned label declared in
# Flux-managed desired state gets reverted on the next reconcile, erasing the
# evidence of a live containment while the containment itself persists.
#
# These tests exist because a checker that cannot go red is worse than no
# checker — it converts "we have a test for that" into a false statement. Each
# test below constructs the violating condition and asserts the script actually
# fails on it.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  CHECK="${REPO_ROOT}/scripts/check-flux-dynamic-labels.sh"
  FIXTURE="$(mktemp -d)"
}

teardown() {
  rm -rf "$FIXTURE"
}

# Run the checker against a synthetic tree rather than the real repo, so the
# red-path tests do not depend on the repo being broken.
run_against_fixture() {
  mkdir -p "${FIXTURE}/d2-signalloom/apps"
  cp "$CHECK" "${FIXTURE}/check.sh"
  # The script resolves REPO_ROOT from its own location, so placing it one
  # level down makes the fixture root the repo root.
  mkdir -p "${FIXTURE}/scripts"
  mv "${FIXTURE}/check.sh" "${FIXTURE}/scripts/check-flux-dynamic-labels.sh"
  chmod +x "${FIXTURE}/scripts/check-flux-dynamic-labels.sh"
  run "${FIXTURE}/scripts/check-flux-dynamic-labels.sh"
}

@test "the real repository passes" {
  run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no runtime-owned fields declared"* ]]
}

@test "FAILS when signalloom.ai/state is declared with a value" {
  mkdir -p "${FIXTURE}/d2-signalloom/apps/thing"
  cat > "${FIXTURE}/d2-signalloom/apps/thing/pod.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  labels:
    signalloom.ai/state: idle
YAML
  run_against_fixture
  [ "$status" -eq 1 ]
  [[ "$output" == *"runtime-owned field"* ]]
}

@test "FAILS on the stunned value too, not just idle" {
  mkdir -p "${FIXTURE}/d2-signalloom/apps/thing"
  cat > "${FIXTURE}/d2-signalloom/apps/thing/pod.yaml" <<'YAML'
metadata:
  labels:
    signalloom.ai/state: stunned
YAML
  run_against_fixture
  [ "$status" -eq 1 ]
}

@test "FAILS regardless of indentation depth" {
  # ResourceSet templates nest the pod spec several levels deep; a check that
  # only matched a fixed indent would miss the flux-operator copy, which is
  # exactly where one of the two real declarations lived.
  mkdir -p "${FIXTURE}/d2-osramp-fleet/tenants/local"
  cat > "${FIXTURE}/d2-osramp-fleet/tenants/local/rs.yaml" <<'YAML'
spec:
  resources:
    - kind: Pod
      metadata:
        labels:
                    signalloom.ai/state: idle
YAML
  run_against_fixture
  [ "$status" -eq 1 ]
}

@test "PASSES when the field appears only in a comment" {
  # The real manifests carry long explanatory comments naming this exact field.
  # A fixed-string search would flag its own documentation and force whoever
  # hit it to delete the explanation to get green — the worst outcome.
  mkdir -p "${FIXTURE}/d2-signalloom/apps/thing"
  cat > "${FIXTURE}/d2-signalloom/apps/thing/pod.yaml" <<'YAML'
metadata:
  labels:
    # signalloom.ai/state is deliberately not declared here — it is runtime
    # state and Flux would revert it.
    signalloom.ai/agent: "true"
YAML
  run_against_fixture
  [ "$status" -eq 0 ]
}

@test "PASSES when the field is used as a SELECTOR rather than declared" {
  # A NetworkPolicy that quarantines stunned pods MUST reference the field.
  # Selecting on it is the intended use; only declaring a value is the defect.
  mkdir -p "${FIXTURE}/d2-signalloom/apps/thing"
  cat > "${FIXTURE}/d2-signalloom/apps/thing/netpol.yaml" <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
spec:
  podSelector:
    matchLabels:
      signalloom.ai/state: stunned
YAML
  run_against_fixture
  # This is the load-bearing case. A quarantine NetworkPolicy selecting stunned
  # pods is the intended enforcement mechanism; if the checker rejected it, the
  # checker would forbid the very control it exists to protect. Selector and
  # declaration are syntactically identical, so the checker distinguishes them
  # by enclosing block.
  [ "$status" -eq 0 ]
}

@test "PASSES when the field is used under matchExpressions" {
  mkdir -p "${FIXTURE}/d2-signalloom/apps/thing"
  cat > "${FIXTURE}/d2-signalloom/apps/thing/netpol.yaml" <<'YAML'
spec:
  podSelector:
    matchExpressions:
      signalloom.ai/state: stunned
YAML
  run_against_fixture
  [ "$status" -eq 0 ]
}

@test "still FAILS for a declaration in the same file as a selector" {
  # The realistic regression: someone adds the quarantine policy correctly and
  # re-adds the literal to the pod spec in the same change.
  mkdir -p "${FIXTURE}/d2-signalloom/apps/thing"
  cat > "${FIXTURE}/d2-signalloom/apps/thing/both.yaml" <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
spec:
  podSelector:
    matchLabels:
      signalloom.ai/state: stunned
---
apiVersion: v1
kind: Pod
metadata:
  labels:
    signalloom.ai/state: idle
YAML
  run_against_fixture
  [ "$status" -eq 1 ]
}

@test "PASSES when an unrelated signalloom label is declared" {
  mkdir -p "${FIXTURE}/d2-signalloom/apps/thing"
  cat > "${FIXTURE}/d2-signalloom/apps/thing/pod.yaml" <<'YAML'
metadata:
  labels:
    signalloom.ai/agent-name: cardvault
    signalloom.ai/supercred: "true"
YAML
  run_against_fixture
  [ "$status" -eq 0 ]
}

@test "PASSES on an empty tree" {
  run_against_fixture
  [ "$status" -eq 0 ]
}
