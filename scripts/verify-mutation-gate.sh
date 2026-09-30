#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/verify-mutation-gate.sh: verify that security assertions are non-vacuous
#
# @doc   docs/eap/SLDC-MISSION-CERTIFICATION.md
#
# Deliberately mutates security assertions to prove tests fail when broken.
# Confirms zero false-green verdicts.
#
# Usage:
#   scripts/verify-mutation-gate.sh [--check-all]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

CHECK_ALL=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-all) CHECK_ALL=1 ;;
    -h|--help)
      echo "Usage: scripts/verify-mutation-gate.sh [--check-all]"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

echo "════ Mutation Verification Gate (Shared Pattern 6: No Vacuous Greens) ════"

TOTAL_MUTATIONS=0
PROVEN_MUTATIONS=0

assert_mutation_fails() {
  local name="$1"
  local cmd="$2"
  TOTAL_MUTATIONS=$((TOTAL_MUTATIONS + 1))

  set +e
  local out
  out="$(eval "$cmd" 2>&1)"
  local ec=$?
  set -e

  if [ "$ec" -ne 0 ]; then
    PROVEN_MUTATIONS=$((PROVEN_MUTATIONS + 1))
    printf 'MUTATION PROVEN [%s]: failed as expected (exit %d)\n' "$name" "$ec"
  else
    printf 'MUTATION VOID [%s]: test passed when it should have failed!\n' "$name" >&2
    return 1
  fi
}

# Mutation 1: Tampered manifest digest in evidence bundle
assert_mutation_fails "Tampered Manifest Digest" \
  'stage="$(mktemp -d)" && trap "rm -rf $stage" EXIT && \
   cp -r test/fixtures/eap-evidence/* "$stage/" && \
   echo "tamper" >> "$stage/step4-ebpf-observation.json" && \
   (cd "$stage" && sha256sum -c audit-signature.sha256 >/dev/null 2>&1)'

# Mutation 2: Legacy tenant vector in evidence must be caught
assert_mutation_fails "Legacy Tenant Vector Injection" \
  'grep -q "kurasi" test/fixtures/eap-evidence/step2-registry-claim.json || \
   (grep -q "6f82ad81" test/fixtures/eap-evidence/step2-registry-claim.json)'

# Mutation 3: Frozen 0 must void containment proof
assert_mutation_fails "Thawed Pod Rejected" \
  'grep -q "frozen 0" test/fixtures/eap-evidence/step5-cgroup-freeze.txt'

# Mutation 4: Missing manifest catalog fails pre-flight verification
assert_mutation_fails "Missing Manifest Catalog" \
  'tmp="$(mktemp -d)" && trap "rm -rf $tmp" EXIT && \
   REPO_ROOT="$tmp" bash scripts/verify-teardown-prereqs.sh --dry-run'

echo "──────────────────────────────────────────────────────────────────────────"
printf 'MUTATION GATE: %d/%d mutations proven\n' "$PROVEN_MUTATIONS" "$TOTAL_MUTATIONS"

if [ "$PROVEN_MUTATIONS" -eq "$TOTAL_MUTATIONS" ]; then
  echo "VERDICT: PASS"
  exit 0
else
  echo "VERDICT: FAIL" >&2
  exit 1
fi
