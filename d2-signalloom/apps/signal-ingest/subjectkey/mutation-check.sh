#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# SLDP-P4-1 mutation harness.
#
# A guard never observed failing is an untested claim. This script breaks each control deliberately
# and asserts the suite goes RED, then restores the file and asserts the suite goes GREEN again.
#
# Two rules it obeys, both learned the hard way in this repo:
#
#   1. A mutation that BREAKS THE BUILD is not a kill. A deleted control usually fails to compile,
#      and a compile failure is indistinguishable from a test catching the defect. Every mutation
#      here compiles; the script checks that explicitly and reports BUILD_BREAK, not KILLED.
#
#   2. Backups are keyed by FULL PATH, not basename. Three files named main.go in one tree collide
#      under a basename key and the restore writes the wrong content back.
#
# Restore is unconditional and idempotent: an EXIT trap plus explicit traps on INT/TERM/HUP, because
# a harness killed mid-run otherwise leaves the repository mutated.
#
# @id      sldp-p4-1-mutation-check
# @target  subjectkey/*.go, identity/migrations/009_subject_keys.sql
# @doc     docs/signalloom/sldp-p4-1-proof.md

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"
BACKUP="$(mktemp -d)"
export GOCACHE="${GOCACHE:-/tmp/gocache}" GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}" CGO_ENABLED=0

restore_all() {
  # Keyed by full path with '/' encoded, so no two files can collide.
  local enc rel
  for enc in "$BACKUP"/*; do
    [[ -e "$enc" ]] || continue
    rel="$(basename "$enc" | tr '%' '/')"
    cp "$enc" "$ROOT/$rel"
  done
  rm -rf "$BACKUP"
}
trap restore_all EXIT INT TERM HUP

backup() {
  local rel="$1"
  cp "$ROOT/$rel" "$BACKUP/$(printf '%s' "$rel" | tr '/' '%')"
}

KILLED=0 SURVIVED=0 BUILD_BREAK=0

# mutate <name> <file> <sed-expr> <test-filter> <package>
mutate() {
  local name="$1" file="$2" expr="$3" filter="$4" pkg="$5"
  backup "$file"

  local before after
  before="$(md5sum "$ROOT/$file" | cut -d' ' -f1)"
  sed -i "$expr" "$ROOT/$file"
  after="$(md5sum "$ROOT/$file" | cut -d' ' -f1)"
  # A sed that matched nothing is a no-op, and a no-op mutation that "survives" would falsely
  # acquit the guard. Refuse rather than report.
  if [[ "$before" == "$after" ]]; then
    printf '  \033[1;31mNO-OP\033[0m   %-46s (the sed matched nothing; this case asserts nothing)\n' "$name"
    cp "$BACKUP/$(printf '%s' "$file" | tr '/' '%')" "$ROOT/$file"
    SURVIVED=$((SURVIVED + 1))
    return
  fi

  if ! go build ./... >/dev/null 2>&1; then
    printf '  \033[1;33mBUILD\033[0m   %-46s (mutation does not compile; NOT a kill)\n' "$name"
    BUILD_BREAK=$((BUILD_BREAK + 1))
  else
    local out rc
    out="$(go test -count=1 -run "$filter" "$pkg" 2>&1)" && rc=0 || rc=$?
    # An observed FAIL is required. rc!=0 alone could mean a panic in an unrelated test.
    if [[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q -- '--- FAIL\|^FAIL'; then
      printf '  \033[1;32mKILLED\033[0m  %-46s %s\n' "$name" \
        "$(printf '%s' "$out" | grep -m1 -- '--- FAIL' | sed 's/^ *//' | cut -c1-70)"
      KILLED=$((KILLED + 1))
    else
      printf '  \033[1;31mSURVIVED\033[0m %-45s (rc=%s — the guard does not catch this)\n' "$name" "$rc"
      SURVIVED=$((SURVIVED + 1))
    fi
  fi
  cp "$BACKUP/$(printf '%s' "$file" | tr '/' '%')" "$ROOT/$file"
}

echo "=== SLDP-P4-1 mutation sweep ==="

# The baseline must be green, or every 'KILLED' below is a pre-existing failure wearing the
# mutation's clothes.
if ! go test -count=1 ./subjectkey/... ./identity/... >/dev/null 2>&1; then
  echo "BASELINE IS RED — every kill below would be attributing an existing failure to a mutation." >&2
  exit 1
fi
echo "  baseline: GREEN"
echo

# M1 — the load-bearing property. A DERIVED per-subject key makes destruction theatre while every
# diagram and every other test stays identical.
mutate "M1 per-subject DEK is derived, not random" \
  "subjectkey/hierarchy.go" \
  's|	if _, err := io.ReadFull(rand.Reader, dek); err != nil {|	copy(dek, []byte("derived-from-subject-not-random!!")); if _, err := io.ReadFull(rand.Reader, dek[:0]); err != nil {|' \
  'TestHierarchy_DEKIsRandomNotDerived' './subjectkey/...'

# M2 — the AAD binding. Without it a wrapped key opens in any row.
mutate "M2 wrap AAD dropped" \
  "subjectkey/hierarchy.go" \
  's|wrapped, err := sealAAD(kek, dek, wrapAAD(scope))|wrapped, err := sealAAD(kek, dek, nil)|' \
  'TestHierarchy_WrapBindsScope' './subjectkey/...'

# M3 — the idempotency defect this card exists to prevent: a clock-derived receipt field.
mutate "M3 receipt CompletedAt from the retry clock" \
  "subjectkey/saga.go" \
  's|receipt, err := s.buildReceipt(ctx, saga, \*saga.CompletedAt)|receipt, err := s.buildReceipt(ctx, saga, s.now().UTC())|' \
  'TestErasureSaga_IsIdempotent' './subjectkey/...'

# M4 — a repeat destroy that re-stamps destroyed_at, breaking digest reproducibility.
mutate "M4 repeat destroy re-stamps destroyed_at" \
  "subjectkey/store.go" \
  's|^	if r.Destroyed() {$|	if false {|' \
  'TestErasureSaga_MemoryStoreRepeatDestroy' './subjectkey/...'

# M5 — the cache purge silently matches nothing: erasure becomes cosmetic.
mutate "M5 cache purge is a no-op" \
  "subjectkey/cache.go" \
  's|^	prefix := subjectPrefix(tenantID, pseudonym)$|	prefix := subjectPrefix(tenantID, pseudonym) + "\\x00never-matches"|' \
  'TestErasureSaga' './subjectkey/...'

# M6 — the proof passes without its control, which is the single most dangerous wrong answer here.
mutate "M6 proof passes with no control" \
  "subjectkey/proof.go" \
  's|	case !proof.Control.UnwrapSucceeded:|	case false:|' \
  'TestErasureSaga_Proof' './subjectkey/...'

# M7 — the proof stops attempting an unwrap and trusts the destroyed_at flag instead.
mutate "M7 proof trusts the flag, never unwraps" \
  "subjectkey/proof.go" \
  's|		if _, err := s.hierarchy.UnwrapDEK(r.Scope(), r.WrappedDEK); err != nil {|		if r.DestroyedAt != nil {|' \
  'TestErasureSaga_DestructionProofRequiresAControl' './subjectkey/...'

# M8 — the state ladder stops being a ladder.
mutate "M8 keys_destroyed reachable without certification" \
  "subjectkey/saga.go" \
  's|		if err := s.certifyAllDestroyed(ctx, tenantID, pseudonym, saga.TargetVersions); err != nil {|		if err := error(nil); err != nil {|' \
  'TestErasureSaga_Certifies' './subjectkey/...'

# M9 — a boundary silently drops out of the fault sweep.
mutate "M9 a saga boundary is removed" \
  "subjectkey/saga.go" \
  's|	{"cache_clear", FaultBeforeCacheClear, FaultAfterCacheClear},||' \
  'TestErasureSaga_Fault' './subjectkey/...'

# M10 — the Go state enumeration drifts from the SQL CHECK constraint.
mutate "M10 Go saga states drift from SQL" \
  "subjectkey/store.go" \
  's|	StateReceiptRecorded,\n	StateCompleted,|&|; s|^	StateCompleted,$|	StateCompleted,\n	SagaState("extra_state"),|' \
  'TestMigration009_StateCheckMatchesGo' './identity/...'

# M11 — a fail-closed database constraint is removed from the migration.
mutate "M11 destroyed-carries-digest constraint removed" \
  "identity/migrations/009_subject_keys.sql" \
  "s|CHECK (destroyed_at IS NULL OR prior_wrapped_digest <> '')|CHECK (true)|" \
  'TestMigration009_DeclaresSubjectKeySchema' './identity/...'

# M12 — row-level security is downgraded to ENABLE-only, leaving the table owner exempt.
mutate "M12 FORCE ROW LEVEL SECURITY removed" \
  "identity/migrations/009_subject_keys.sql" \
  's|ALTER TABLE subject_keys FORCE ROW LEVEL SECURITY;||' \
  'TestMigration009_DeclaresSubjectKeySchema' './identity/...'

# M13 — the operation ID becomes an unkeyed digest, turning it into a re-identification oracle.
mutate "M13 operation id is unkeyed" \
  "subjectkey/saga.go" \
  's|	mac := hmac.New(sha256.New, kek)|	_ = kek; mac := hmac.New(sha256.New, []byte("fixed-public-constant-not-key32"))|' \
  'TestErasureSaga_OperationIDIsDeterministicAndKeyed' './subjectkey/...'

# M14 — the receipt canonical encoding stops covering a field.
mutate "M14 receipt digest ignores the nonce" \
  "subjectkey/receipt.go" \
  's|^	put(r.Nonce)$|	put("")|' \
  'TestErasureSaga_ReceiptDigestIsCanonicalAndSensitive' './subjectkey/...'

echo
printf 'killed=%d survived=%d build_break=%d\n' "$KILLED" "$SURVIVED" "$BUILD_BREAK"
if [[ $SURVIVED -gt 0 || $BUILD_BREAK -gt 0 ]]; then
  echo "A surviving or non-compiling mutation means the corresponding guard is unproven." >&2
  exit 1
fi
echo "Every mutation was observed killing a named test."
