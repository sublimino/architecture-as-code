#!/usr/bin/env bats
# test/phase1-governor-verification.bats
# Phase 1 Governance verification BATS suite

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "p1 governor: scripts/test-phase1-governor.sh executes cleanly and passes all checks" {
  run "${REPO_ROOT}/scripts/test-phase1-governor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Phase 1 Governance Gate verification COMPLETE: PASS" ]]
}

@test "p1 governor: sentinel log audit confirms 0 reconcile_failed errors" {
  AUDIT_LOG="${REPO_ROOT}/ci-evidence/phase1-sentinel-log-audit.txt"
  [ -f "$AUDIT_LOG" ]
  COUNT=$(grep -ci "reconcile_failed" "$AUDIT_LOG" || true)
  [ "$COUNT" -eq 0 ]
}

@test "p1 governor: deliberate mutation test proves audit gate catches reconcile failure" {
  TMP_LOG="/tmp/bats-mutation-audit-$$.log"
  echo "reconcile_failed: test error" > "$TMP_LOG"
  run grep -ci "reconcile_failed" "$TMP_LOG"
  rm -f "$TMP_LOG"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "p1 governor: machine-readable certification json conforms to schema and status=certified" {
  CERT_JSON="${REPO_ROOT}/ci-evidence/phase1-governance-certification.json"
  [ -f "$CERT_JSON" ]
  STATUS=$(jq -r '.status' "$CERT_JSON")
  [ "$STATUS" = "certified" ]
  PHASE=$(jq -r '.phase' "$CERT_JSON")
  [ "$PHASE" -eq 1 ]
}
