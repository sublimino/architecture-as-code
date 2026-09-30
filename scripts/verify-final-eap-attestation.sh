#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/verify-final-eap-attestation.sh: one-shot independent verification of the SLDC platform
#
# @doc   docs/eap/FINAL-MISSION-CERTIFICATION-REPORT.md
# @spec  schemas/eap-evidence-bundle-schema.json
#
# Complete, automated verification auditing all deliverables, security checks,
# evidence bundles, and replay suites across Phases 0 through 6.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

echo "════ Final Mission EAP Attestation and Audit Verification ════"
echo "Repository: $REPO_ROOT"
echo "Timestamp:  $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "Commit:     $(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")"
echo "─────────────────────────────────────────────────────────────"

TOTAL_STEPS=0
PASSED_STEPS=0

run_step() {
  local id="$1"
  local desc="$2"
  local cmd="$3"
  TOTAL_STEPS=$((TOTAL_STEPS + 1))

  echo "[Step $id] $desc..."
  if eval "$cmd"; then
    PASSED_STEPS=$((PASSED_STEPS + 1))
    printf '✓ [Step %s] PASS\n' "$id"
  else
    printf '✗ [Step %s] FAIL\n' "$id" >&2
    return 1
  fi
  echo ""
}

# Step 1: Pre-flight readiness checks
run_step "1" "Phase 6 Teardown and Scratch Readiness" \
  "bash '$REPO_ROOT/scripts/verify-teardown-prereqs.sh' --dry-run"

# Step 2: Adversarial Purple-Team Security Probes
run_step "2" "Adversarial Purple-Team Security Probes" \
  "bash '$REPO_ROOT/scripts/super-test-adversarial.sh' --run-all"

# Step 3: Security Assertion Mutation Gate
run_step "3" "Security Mutation Verification (No Vacuous Greens)" \
  "bash '$REPO_ROOT/scripts/verify-mutation-gate.sh' --check-all"

# Step 4: Replay BATS Test Suite
run_step "4" "Cold-Start Replay and Attestation Suite" \
  "bats '$REPO_ROOT/test/e2e-scratch-coldstart-replay.bats'"

# Step 5: Evidence Packager and Integrity Verifier
run_step "5" "Forensic Evidence Packager and Tamper Verification" \
  "bats '$REPO_ROOT/test/evidence-bundle-integrity.bats'"

# Step 6: Final Governor Certification Suite
if [ -f "$REPO_ROOT/test/final-mission-governor.bats" ]; then
  run_step "6" "Final Mission Governor Gates" \
    "bats '$REPO_ROOT/test/final-mission-governor.bats'"
fi

# Step 7: Cryptographic Signing Key Inventory
run_step "7" "Cryptographic Signing Keys Check" \
  "test -r '$REPO_ROOT/.keys/cosign.key' && test -r '$REPO_ROOT/.keys/cosign.pub' && test -r '$REPO_ROOT/.keys/witness.pem'"

echo "═════════════════════════════════════════════════════════════"
printf 'FINAL ATTESTATION VERDICT: PASS (%d/%d steps verified)\n' "$PASSED_STEPS" "$TOTAL_STEPS"
exit 0
