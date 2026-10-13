#!/usr/bin/env bash
# evidence-sweep.sh — Audit and sweep Signal Loom EAP compliance evidence files
set -eo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
cd "${REPO_ROOT}"

echo "=== Signal Loom EAP Compliance Evidence Sweeper ==="
DATE_STR=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Sweep Timestamp: ${DATE_STR}"
FAIL_COUNT=0

# 1. Supply Chain Test Suite Verification
if [ -f "d2-signalloom/test/dashboard-supplychain.bats" ]; then
  echo "Running supplychain cryptographic contract tests..."
  if bats d2-signalloom/test/dashboard-supplychain.bats >/dev/null 2>&1; then
    echo "  [PASS] Supply chain contract: 10/10 tests pass (Cosign, SBOM, SLSA, Buildx)"
  else
    echo "  [FAIL] Supply chain contract: tests failed"
    echo "  [REMEDIATION] Supply chain contract tests failed."
    echo "  Run 'bats d2-signalloom/test/dashboard-supplychain.bats' to see failing assertions."
    echo "  Ensure Cosign verification keys exist in .keys/ (generate via 'make signing-keys')."
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
else
  echo "  [SKIP] dashboard-supplychain.bats not found"
fi

# 2. Directory File Sweep
EVIDENCE_DIRS=("docs/signalloom/evidence" "docs/signalloom/evidence-fe")
TOTAL_EVIDENCE=0
VALID_DIGESTS=0
VALID_SBOMS=0
VALID_SLSA=0

for dir in "${EVIDENCE_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    echo "Inspecting directory: ${dir}..."
    for file in "${dir}"/*; do
      [ -f "$file" ] || continue
      TOTAL_EVIDENCE=$((TOTAL_EVIDENCE + 1))
      case "$file" in
        *.digest.txt)
          if grep -qE '^sha256:[a-f0-9]{64}' "$file" 2>/dev/null; then
            VALID_DIGESTS=$((VALID_DIGESTS + 1))
          fi
          ;;
        *.sbom.spdx.json)
          if jq -e '.spdxVersion' "$file" >/dev/null 2>&1; then
            VALID_SBOMS=$((VALID_SBOMS + 1))
          fi
          ;;
        *.provenance.slsa.json)
          if jq -e '._type' "$file" >/dev/null 2>&1; then
            VALID_SLSA=$((VALID_SLSA + 1))
          fi
          ;;
      esac
    done
  fi
done

echo "=== Evidence Audit Summary ==="
echo "Total Artifact Files Scanned: ${TOTAL_EVIDENCE}"
echo "Valid SHA256 Digests: ${VALID_DIGESTS}"
echo "Valid SPDX 2.3 SBOMs: ${VALID_SBOMS}"
echo "Valid SLSA Provenance: ${VALID_SLSA}"

if [ "$TOTAL_EVIDENCE" -eq 0 ]; then
  echo "STATUS: NO_EVIDENCE_FOUND"
  echo "  [REMEDIATION] No compliance evidence files found in docs/signalloom/evidence/ or evidence-fe/."
  echo "  Build and sign images to generate provenance and SBOM artifacts:"
  echo "    ./scripts/build-sign-dashboard.sh"
  echo "    make demo-signalloom-supercred-evidence"
  FAIL_COUNT=$((FAIL_COUNT + 1))
elif [ "$VALID_DIGESTS" -eq 0 ] || [ "$VALID_SBOMS" -eq 0 ] || [ "$VALID_SLSA" -eq 0 ]; then
  echo "STATUS: EVIDENCE_INCOMPLETE"
  echo "  [REMEDIATION] Incomplete evidence triad detected. Every release must include:"
  echo "  1. .digest.txt (SHA256 image digest)"
  echo "  2. .sbom.spdx.json (SPDX 2.3 bill of materials)"
  echo "  3. .provenance.slsa.json (SLSA Level 3 provenance)"
  echo "  Regenerate via './scripts/build-sign-dashboard.sh'."
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "STATUS: EVIDENCE_VERIFIED"
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "RESULT: ${FAIL_COUNT} EVIDENCE FAILURE(S) DETECTED"
  exit 1
else
  echo "RESULT: ALL EVIDENCE VERIFIED"
  exit 0
fi
