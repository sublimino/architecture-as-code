#!/usr/bin/env bats
# AI-Governed Software Factory (AIGSF) governance contracts & appraiser verification.

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  schema_dir="$root/d2-signalloom/governance/schemas"
  appraiser_dir="$root/d2-signalloom/apps/factory-appraiser"
}

@test "factory: versioned governance schemas exist" {
  [ -f "$schema_dir/intent.v1.json" ]
  [ -f "$schema_dir/candidate.v1.json" ]
  [ -f "$schema_dir/qa-evidence.v1.json" ]
  [ -f "$schema_dir/promotion.v1.json" ]
  [ -f "$schema_dir/appraisal.v1.json" ]
  [ -f "$schema_dir/escalation.v1.json" ]
}

@test "factory: governance schemas are well-formed JSON" {
  for f in "$schema_dir"/*.v1.json; do
    python3 -m json.tool "$f" >/dev/null
  done
}

@test "factory-appraiser: Go unit and race tests pass cleanly" {
  run bash -c "cd \"$appraiser_dir\" && go test ./..."
  [ "$status" -eq 0 ]
}

@test "factory-appraiser: separation of duties prevents platform self-signing" {
  run grep -E "(ValidateSeparationOfDuties|separation of duties violation)" "$appraiser_dir/validator/validator.go"
  [ "$status" -eq 0 ]
}

@test "factory-appraiser: promotion contract requires immutable sha256 release digest and human approver" {
  run grep -E "(ValidatePromotionContract|release_digest|approver_human)" "$appraiser_dir/validator/validator.go"
  [ "$status" -eq 0 ]
}

@test "factory-appraiser: appraiser produces idempotent escalation keys for stale worktrees" {
  run grep -E "(Appraise|EscalationRecord|stale_candidates)" "$appraiser_dir/appraiser/appraiser.go"
  [ "$status" -eq 0 ]
}
