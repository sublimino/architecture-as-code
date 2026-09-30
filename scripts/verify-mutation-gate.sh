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

# Each mutation breaks one fact in a pristine copy of the fixture evidence and
# must be refused by the REAL packager or verifier with its own message. A
# control first proves the pristine copy is accepted, so a tool that refuses
# everything cannot pass as a tool that catches everything.
PACKAGE="${MUTATION_GATE_PACKAGE:-$REPO_ROOT/scripts/package-eap-evidence.sh}"
VERIFY="${MUTATION_GATE_VERIFY:-$REPO_ROOT/scripts/verify-eap-evidence.sh}"
FIXTURES="$REPO_ROOT/test/fixtures/eap-evidence"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
openssl genpkey -algorithm ed25519 -out "$WORK/key.pem" 2>/dev/null
openssl pkey -in "$WORK/key.pem" -pubout -out "$WORK/pub.pem"
export EAP_SIGNING_KEY="$WORK/key.pem" EAP_VERIFY_PUBKEY="$WORK/pub.pem"
export EAP_OPERATOR="mutation-gate" EAP_CONTAINER_RUNTIME="mutation-gate" SOURCE_DATE_EPOCH=1790726400

TOTAL_MUTATIONS=0
PROVEN_MUTATIONS=0

fresh() { rm -rf "$WORK/$1" && mkdir -p "$WORK/$1" && cp "$FIXTURES"/* "$WORK/$1/" && printf '%s' "$WORK/$1"; }
pack() { "$PACKAGE" --quiet --out "$WORK/out-$(basename "$1")" "$1" 2>&1; }

# assert_refused NAME MESSAGE COMMAND...: COMMAND must exit non-zero AND say MESSAGE.
assert_refused() {
  local name="$1" msg="$2" out ec
  shift 2
  TOTAL_MUTATIONS=$((TOTAL_MUTATIONS + 1))
  out="$("$@" 2>&1)" && ec=0 || ec=$?
  if [ "$ec" -ne 0 ] && [[ "$out" == *"$msg"* ]]; then
    PROVEN_MUTATIONS=$((PROVEN_MUTATIONS + 1))
    printf 'MUTATION PROVEN [%s]: refused with "%s" (exit %d)\n' "$name" "$msg" "$ec"
  else
    printf 'MUTATION VOID [%s]: exit %d without "%s"\n' "$name" "$ec" "$msg"
  fi
}

control="$(fresh control)"
if pack "$control" >/dev/null && "$VERIFY" --quiet "$control" >/dev/null 2>&1; then
  echo "CONTROL: untampered evidence packages and verifies"
else
  echo "CONTROL FAILED: untampered evidence was refused; no mutation can be proven"
  echo "VERDICT: FAIL" >&2
  exit 1
fi

tampered="$(fresh tampered)"
pack "$tampered" >/dev/null
printf ' ' >>"$tampered/step4-ebpf-observation.json"
assert_refused "Tampered artifact" "step4-ebpf-observation.json: FAILED" "$VERIFY" "$tampered"

legacy="$(fresh legacy)"
echo 'X-Tenant-ID: kurasi' >>"$legacy/step3-provocation-act.log"
assert_refused "Legacy tenant vector" "legacy tenant 'kurasi'" pack "$legacy"

thawed="$(fresh thawed)"
sed -i 's/^frozen 1$/frozen 0/' "$thawed/step5-cgroup-freeze.txt"
assert_refused "Thawed pod" "PRIMARY FORENSIC PROOF INVALID" pack "$thawed"

catalog_root="$WORK/no-catalog"
mkdir -p "$catalog_root"
assert_refused "Missing manifest catalog" "FAIL Cold-start manifest catalog ready" \
  env REPO_ROOT="$catalog_root" bash "$REPO_ROOT/scripts/verify-teardown-prereqs.sh" --dry-run --out "$catalog_root/r.json"

echo "──────────────────────────────────────────────────────────────────────────"
printf 'MUTATION GATE: %d/%d mutations proven\n' "$PROVEN_MUTATIONS" "$TOTAL_MUTATIONS"

if [ "$PROVEN_MUTATIONS" -eq "$TOTAL_MUTATIONS" ]; then
  echo "VERDICT: PASS"
  exit 0
fi
echo "VERDICT: FAIL" >&2
exit 1
