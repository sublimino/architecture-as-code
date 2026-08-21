#!/usr/bin/env bash
# worktree-bootstrap-mutation-proof.sh — prove the worktree-bootstrap guards can fail.
#
# A green suite is evidence of nothing until each guard has been shown to go RED
# for the right reason, against the REAL file, for a defect a person could
# plausibly introduce. test/terraform-worktree-bootstrap.bats is 35 assertions
# about a script and a Makefile macro; without this harness it is 35 assertions
# that might all be tautologies.
#
# The guards proven here are the ones that carry the actual value:
#
#   the manifest really drives the refusal        (not a hardcoded message)
#   provision refuses AS A WHOLE                  (no half-provisioned tree)
#   a newer destination is not clobbered          (no silent data loss)
#   the output class is never symlinked           (no write into the source checkout)
#   file mode survives the copy                   (no world-readable cosign key)
#   the Makefile actually calls the guard         (not decoration)
#   the gate is a no-op only OUTSIDE a worktree   (positive control)
#
# Restore is from a byte-for-byte backup taken here, NOT `git checkout`.
# `git checkout <path>` in a proof harness wipes in-progress edits elsewhere in
# the tree, and the resulting "the guard did not fire" reads exactly like a real
# finding.
#
# Offline: no terraform, no network, no credentials. Every fixture is a temp dir.
#
# Run: test/worktree-bootstrap-mutation-proof.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SCRIPT="scripts/gcp-tf/worktree-bootstrap.sh"
MAKEFILE="Makefile"
BATS_SUITE="test/terraform-worktree-bootstrap.bats"

BACKUP="$(mktemp -d)"

restore_all() {
  cp "$BACKUP/worktree-bootstrap.sh" "$SCRIPT"
  cp "$BACKUP/Makefile" "$MAKEFILE"
  chmod +x "$SCRIPT"
}

# The trap runs on SIGTERM and normal exit alike. It does NOT run on SIGKILL,
# so a -9 during a mutation leaves the tree modified — check `git status` if
# this harness is ever killed hard.
trap 'restore_all; rm -rf "$BACKUP"' EXIT

cp "$SCRIPT" "$BACKUP/worktree-bootstrap.sh"
cp "$MAKEFILE" "$BACKUP/Makefile"

PASS=0
FAIL=0

# A sed that cannot silently do nothing.
#
# A non-matching pattern no-ops while returning 0, so the mutation never lands,
# the suite stays green, and the harness reports "guard did not fire" — a false
# finding that looks exactly like a real one, and one that sends somebody to
# "fix" working code.
mutate() {
  local file="$1" expr="$2" before after
  before="$(md5sum "$file" | cut -d' ' -f1)"
  sed -i "$expr" "$file"
  after="$(md5sum "$file" | cut -d' ' -f1)"
  if [[ "$before" == "$after" ]]; then
    echo "HARNESS ERROR: mutation did not change ${file}: ${expr}" >&2
    echo "               The construct it targets has moved. Fix this harness," >&2
    echo "               do not assume the guard is fine." >&2
    exit 2
  fi
}

# Reports the NAMES of failing tests, not the `not ok <n>` numbers: inserting a
# test renumbers everything below it, and a harness that reports NOT PROVEN for
# a guard that fired perfectly well is worse than no harness.
#
# A non-zero bats is the EXPECTED outcome, and `set -o pipefail` promotes it to
# the pipeline's status, so `|| true` at the call site is what stops `set -e`
# from killing the harness on its own success.
failing_bats_tests() {
  bats "$BATS_SUITE" 2>&1 | sed -n 's/^not ok [0-9]* //p'
}

check_bats() {
  local label="$1" want="$2" got
  got="$(failing_bats_tests || true)"
  if [[ "$got" == *"$want"* ]]; then
    echo "  RED as expected — \"${want}\"  [${label}]"
    PASS=$((PASS + 1))
  else
    echo "  *** NOT PROVEN: expected \"${want}\" to fail. Failures were:" >&2
    printf '        %s\n' "${got:-<none>}" >&2
    FAIL=$((FAIL + 1))
  fi
  restore_all
}

echo "=== baseline: the suite must be green before any mutation ==="
if ! bats "$BATS_SUITE" >/dev/null 2>&1; then
  echo "HARNESS ERROR: ${BATS_SUITE} is not green before mutation" >&2
  bats "$BATS_SUITE" 2>&1 | tail -20 >&2
  exit 2
fi
echo "  GREEN"
echo ""

echo "=== mutations ==="

# ── The manifest is what drives the refusal ────────────────────────────────
#
# If the message were hardcoded rather than derived, downgrading deploy-sa to
# optional would change nothing and this would stay green.

echo "M1  deploy-sa is downgraded to optional in the manifest"
# `#` as the delimiter, not `|`: the manifest USES `|` as its field separator,
# so a pipe-delimited expression here is a syntax error at best and a silent
# mismatch at worst.
mutate "$SCRIPT" 's#^deploy/gcp/deploy-sa|input|yes|#deploy/gcp/deploy-sa|input|no|#'
check_bats "M1 manifest drives refusal" "check names deploy/gcp/deploy-sa, the file whose absence costs a full apply"

# ── provision refuses as a whole ───────────────────────────────────────────
#
# The half-provisioned tree is the exact state this command exists to prevent,
# because a tree with SOME of the state produces the same misdirected errors.

echo "M2  a blocked item is skipped instead of stopping the run"
mutate "$SCRIPT" 's|^  if \[ "${#blocked\[@\]}" -gt 0 \]; then$|  if false; then|'
check_bats "M2 all-or-nothing" "a blocked item stops the WHOLE provision — no half-provisioned tree"

# ── a newer destination is not silently clobbered ──────────────────────────

echo "M3  the newer-than-source case falls through to a plain overwrite"
mutate "$SCRIPT" 's|^        if \[ -n "\$FORCE" \]; then$|        if true; then|'
check_bats "M3 newer refusal" "provision refuses to clobber a destination that is NEWER than the source"

# ── the output class is never symlinked ────────────────────────────────────
#
# The consequence of getting this wrong is not a failed test, it is
# gcp-tf-handoff in a worktree truncating the MAIN checkout's hand-off through
# the link and repointing that lane at a different estate.

echo "M4  LINK=1 is applied uniformly, including to the regenerated files"
mutate "$SCRIPT" 's|  if \[ -n "\$LINK" \] \&\& \[ "\$class" = "input" \]; then|  if [ -n "$LINK" ]; then|'
check_bats "M4 output class never linked" "LINK=1 NEVER symlinks a hand-off: gcp-tf-handoff would write the source checkout"

# The behavioural half of the same defect: not "is it a symlink" but "does a
# write reach the source checkout". M4 could in principle be satisfied by a
# cosmetic change; this one cannot.
echo "M5  the same defect, observed as a write escaping into the source checkout"
mutate "$SCRIPT" 's|  if \[ -n "\$LINK" \] \&\& \[ "\$class" = "input" \]; then|  if [ -n "$LINK" ]; then|'
check_bats "M5 write containment" "writing through a provisioned hand-off does not reach the source checkout"

# ── file mode survives ─────────────────────────────────────────────────────

# ── `cp -p` is load-bearing — but not for the reason one first assumes ─────
#
# The first draft of this mutation targeted the MODE test and came back NOT
# PROVEN, which was the harness working correctly. Plain `cp` onto a fresh
# destination produces (source mode & ~umask); for an 0600 key under any normal
# umask that is still 0600, so dropping `-p` does not change the mode and the
# mode test cannot detect it. The mode assertion is kept as an invariant, and
# is honestly documented in the suite as not mutation-proven.
#
# What `-p` actually protects is mtime, and mtime is what every staleness
# decision in this tool is made of. Without it each copied file is stamped
# `now`, so it is NEWER than its own source, and the next time a source file
# legitimately changes the tool refuses to update the destination — citing a
# local modification it manufactured itself on the previous run.
echo "M6  cp loses -p, so every copy is stamped newer than its own source"
mutate "$SCRIPT" 's|if \[ -d "\$src" \]; then cp -Rp "\$src" "\$dst"; else cp -p "\$src" "\$dst"; fi|if [ -d "$src" ]; then cp -R "$src" "$dst"; else cp "$src" "$dst"; fi|'
check_bats "M6 mtime preserved" "provision preserves mtime, which the newer-than comparison depends on"

# ── the Makefile really calls the guard ────────────────────────────────────
#
# A macro that is defined and never invoked is decoration, and this repo has
# shipped that shape before.

echo "M7  the guard is removed from gcp-tf-up"
mutate "$MAKEFILE" 's|^\t\$(gcp_tf_require_worktree_state)$||'
check_bats "M7 guard is wired in" "gcp-tf-up invokes the worktree-state guard"

# ── the gate's no-op is scoped, not universal ──────────────────────────────
#
# THE POSITIVE CONTROL. "gate is a NO-OP outside a linked worktree" is satisfied
# by a gate that returns 0 everywhere — i.e. by a guard that never fires at all.
# Without this mutation that test is worth nothing, and neither is M7: the
# Makefile would be calling something inert.

echo "M8  gate returns 0 unconditionally (the guard becomes inert everywhere)"
mutate "$SCRIPT" 's#^      is_linked_worktree || exit 0$#      exit 0#'
check_bats "M8 positive control" "gate refuses in a real linked worktree that is missing the state"

# ── the AFM severity split is real ─────────────────────────────────────────

echo "M9  KUBESEC_AFM_ROOT is promoted to a hard failure unconditionally"
mutate "$SCRIPT" 's|^    if \[ -n "${REQUIRE_AFM:-}" \]; then$|    if true; then|'
check_bats "M9 AFM is a warning by default" "an unresolvable KUBESEC_AFM_ROOT is reported but does not fail check"

# ── the guard fails CLOSED when its own script is absent ───────────────────
#
# This is not hypothetical. The first version of the macro wrapped the whole
# guard in `[ -x $(GCP_TF_WORKTREE_SCRIPT) ]`, and in a fresh worktree where the
# script had not yet been committed, `make gcp-tf-up` walked straight past it
# into terraform init — the precise failure the guard was written to prevent,
# reintroduced by the guard's own defensive check.
echo "M10 the guard skips itself when its script is missing (fails open)"
# No `$` anchor: the line ends in a make line-continuation backslash, not at
# `then`. Anchoring there matched nothing, and the harness correctly refused
# rather than reporting the guard as unproven.
mutate "$MAKEFILE" 's#if \[ ! -x .\$(GCP_TF_WORKTREE_SCRIPT). \]; then#if false; then#'
check_bats "M10 fail closed" "gcp-tf-up REFUSES when the guard script is missing, rather than skipping it"

echo ""
echo "=== restored: the suite must be green again ==="
if ! bats "$BATS_SUITE" >/dev/null 2>&1; then
  echo "HARNESS ERROR: ${BATS_SUITE} did not return to green after restore" >&2
  bats "$BATS_SUITE" 2>&1 | tail -20 >&2
  exit 2
fi
echo "  GREEN"

# The harness must leave no trace. A proof that mutates the tree and does not
# put it back is indistinguishable, to the next reader, from a broken branch.
#
# Compared against the BACKUP, not against HEAD. An earlier draft used
# `git status --porcelain` and reported failure on a correct run: on a branch
# where this work is not yet committed, the script is untracked (`??`) and the
# Makefile is legitimately modified (` M`) before the harness even starts. That
# check was measuring "does the branch differ from HEAD", which is not the
# harness's business. The invariant it actually owns is "what I found is what I
# left", and cmp against the backup states exactly that — correct whether the
# work is committed, staged, or dirty.
restore_failed=0
cmp -s "$BACKUP/worktree-bootstrap.sh" "$SCRIPT" || restore_failed=1
cmp -s "$BACKUP/Makefile" "$MAKEFILE" || restore_failed=1
if [ "$restore_failed" -ne 0 ]; then
  echo "HARNESS ERROR: a mutated file was not restored to its pre-run content" >&2
  diff "$BACKUP/worktree-bootstrap.sh" "$SCRIPT" | head -20 >&2 || true
  diff "$BACKUP/Makefile" "$MAKEFILE" | head -20 >&2 || true
  exit 2
fi
echo "  every mutated file matches its pre-run content"
echo ""

echo "=== ${PASS} proven, ${FAIL} not proven ==="
[[ "$FAIL" -eq 0 ]]
