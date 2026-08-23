#!/usr/bin/env bash
#
# tailnet-remote-mutation-proof.sh — prove test/terraform-tailnet-remote.bats
# can actually go red.
#
# A green suite is evidence of nothing until something has been broken and the
# suite has noticed. This repo's whole reason for holding that line is written
# across its history: a green run that tested the wrong artifact, two suites
# partly measuring nothing behind comments claiming coverage, an adversarial
# suite dropped from collection that reported the exact known-good baseline.
#
# So: each mutation below breaks ONE guard in the REAL driver, runs the REAL
# suite, and requires it to fail. A mutation the suite does not notice is
# reported as a hole, and this script exits non-zero.
#
# ─── Restoration is from a byte copy, never from git ───────────────────────
#
# `git checkout -- <path>` is the obvious way to undo a mutation and it is the
# wrong one here: it would also discard any uncommitted work in the same file,
# and this repo has already lost in-progress edits to a proof harness that did
# exactly that. The original bytes are copied aside before the first mutation
# and copied back in an EXIT trap.
#
# ─── If this is ever SIGKILLed, the driver is left mutated ─────────────────
#
# The trap covers a normal exit, an error and SIGTERM/SIGINT. It cannot cover
# SIGKILL. A `git diff scripts/gcp-tf/demo-up.sh` showing a one-line change
# after a killed run is this script's leftovers, not a regression — restore it
# from the backup path printed below.

# SC2016: every mutation below is a sed expression containing shell syntax that
# must reach sed LITERALLY — `$code`, `$((missing + 1))` and friends are the
# text being matched in the driver, not values to expand here. Single quotes are
# the correct and only workable form.
# SC2329: `restore` is invoked by the EXIT/INT/TERM trap, which shellcheck
# cannot see.
# shellcheck disable=SC2016,SC2329

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"
SUITE="${REPO_ROOT}/test/terraform-tailnet-remote.bats"
BATS_BIN="${BATS_BIN:-bats}"

fail() {
  printf 'tailnet-remote-mutation-proof: %s\n' "$*" >&2
  exit 1
}

# Presence before behaviour. A proof harness pointed at files that do not exist
# reports whatever the shell does with a missing path.
[ -f "$DRIVER" ] || fail "no driver at ${DRIVER}"
[ -f "$SUITE" ] || fail "no suite at ${SUITE}"
command -v "$BATS_BIN" >/dev/null 2>&1 || fail "bats is not on PATH"

# ── The shared safety rail ──────────────────────────────────────────────────
#
# $DRIVER is shared with two other proofs, and on 2026-08-23 one of them was
# killed at a tool timeout and left it MUTATED. This harness then ran, took that
# mutated file as its own "pristine" copy, and put the mutation back on the way
# out — a clean-looking run over a sabotaged tree. The per-proof sentinel is what
# stops a leak from being invisible, and the refusal names the pid and whether
# it is still alive, which is the difference between "wait" and "inspect".
#
# Two things the hand-rolled backup here could not do. Its restore was
# `[ -s "$BACKUP" ] && cp ...`, which SILENTLY SKIPS when the backup has gone
# and silently installs a damaged one — the rail verifies the pristine copy's
# sha256 before trusting it. And it verified nothing afterwards, so a restore
# that dropped the mode was indistinguishable from one that worked.
#
# ms_guard_on_exit keeps the property the old trap was written for: the status
# is captured FIRST and re-raised, so a failing last command cannot rewrite the
# verdict. See test/helpers/mutation-sentinel.bash.
# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"

ms_guard_init tailnet-remote "$DRIVER"
trap ms_guard_on_exit EXIT INT TERM

printf 'tailnet-remote-mutation-proof: original driver saved under %s\n' "$MS_BACKUP_DIR"

# The suite must be GREEN before anything is broken. Without this a suite that
# was already failing would make every mutation below look detected, and the
# harness would certify a set of guards that were red for unrelated reasons.
printf '\n──── BASELINE: the suite must be green before any mutation ────\n'
if ! "$BATS_BIN" "$SUITE" >/dev/null 2>&1; then
  "$BATS_BIN" "$SUITE" 2>&1 | tail -30 >&2
  fail "the suite is RED before any mutation — nothing below would mean anything"
fi
printf 'baseline green.\n'

FAILURES=0
CHECKED=0

# prove <label> <sed-expression>
#
# Applies the mutation, PROVES it applied (a sed that matches nothing exits 0
# and changes nothing, which would make the check that follows vacuous — this
# repo has shipped exactly that), runs the suite, and requires red.
prove() {
  local label="$1" expr="$2" before after
  CHECKED=$((CHECKED + 1))

  ms_guard_restore
  # Armed by hand, and BEFORE the write. This deliberately does NOT use ms_sed:
  # ms_sed ABORTS on a no-op, and this harness reports a no-op as a HOLE and
  # carries on, so one dead pattern cannot hide the verdict on every mutation
  # after it. The sentinel is what ms_sed would have provided; the no-op policy
  # below is this harness's own and is left exactly as it was.
  ms_guard_arm "${label}"
  before="$(md5sum <"$DRIVER")"
  sed -i "$expr" "$DRIVER"
  after="$(md5sum <"$DRIVER")"

  if [ "$before" = "$after" ]; then
    printf '  NO-OP   %s\n' "$label" >&2
    printf '          the expression matched nothing, so the suite was never tested\n' >&2
    printf '          against this mutation. Reported as a HOLE rather than a pass.\n' >&2
    FAILURES=$((FAILURES + 1))
    return 0
  fi

  if "$BATS_BIN" "$SUITE" >/dev/null 2>&1; then
    printf '  HOLE    %s\n' "$label" >&2
    printf '          the driver was broken and the suite still passed.\n' >&2
    FAILURES=$((FAILURES + 1))
  else
    printf '  CAUGHT  %s\n' "$label"
  fi
}

printf '\n──── MUTATIONS ────\n'

# The zero-check guard: a run that measures nothing must not pass.
prove "zero-check guard accepts an empty run" \
  's/^  if \[ "\$TS_TEST_TOTAL" -eq 0 \]; then/  if false; then/'

# The serve gate: any status accepted means a 502 lane reads as healthy.
prove "health gate accepts any HTTP status" \
  's/elif \[ "\$code" = "200" \]; then/elif true; then/'

# The issuer check: the assertion the on-VM suite cannot make at all.
prove "Dex issuer check always passes" \
  's/if \[ "\$got_issuer" = "\$want_issuer" \]; then/if true; then/'

# The token's own claim, which is a separate statement from discovery.
prove "minted token issuer check always passes" \
  's/if \[ "\$iss" = "\$want_issuer" \]; then/if true; then/'

# The anonymous probe: without it an OPEN api certifies as healthy.
prove "anonymous API rejection is not required" \
  's/elif \[ "\$anon" = "401" \] || \[ "\$anon" = "403" \]; then/elif true; then/'

# The authenticated probe: without it a dead /api backend certifies as healthy.
prove "authenticated API success is not required" \
  's/elif \[ "\$auth" = "200" \]; then/elif true; then/'

# The unaskable check must be recorded as failed, never dropped. Dropping it
# shrinks the denominator until the suite passes by measuring less.
prove "an unaskable check is silently dropped instead of failed" \
  's/^    ts_check fail "API answers an authenticated caller" "no token/    ts_check ok "API answers an authenticated caller" "no token/'

# The both-surfaces property: a missing surface must not be countable as a pass.
prove "a missing surface receipt is not counted" \
  's/^      missing=\$((missing + 1))/      :/'

# The staleness bound on a receipt.
prove "a stale receipt still vouches for the lane" \
  's/^      stale=\$((stale + 1))/      :/'

# The seam. Without the on-vm receipt the verdict can never pass, which is as
# useless as one that always does.
prove "the on-VM lane files no receipt" \
  '/write_surface_receipt on-vm/d'

# ── Fence instrumentation ──────────────────────────────────────────────────
#
# These guard a signal rather than a verdict, and they are mutated for exactly
# that reason: an unmeasured fence fails silently, by never reporting anything,
# which is the failure mode least likely to be noticed by a human reading a
# green run.

prove "checks report no elapsed time against their fence" \
  "s/printf -v budget '\\[%d\\.%03ds\\/%ss %d%%\\]'/printf -v budget '%.0s%.0s%.0s%.0s'/"

prove "the per-check budget is never recorded in the receipt" \
  's/--argjson ms "\$ms" --argjson pct "\$pct"/--argjson ms 0 --argjson pct 0/'

prove "a check at 100% of its budget never warns" \
  's/^  if \[ "\$pct" -ge "\$TS_TEST_WARN_PERCENT" \]; then/  if false; then/'

prove "the timing line is dropped from the verdict" \
  "/    TIMING: %d/d"

printf '\n──── RESULT ────\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 'ALL %d MUTATIONS CAUGHT — every guard in the remote surface can go red.\n' "$CHECKED"
  exit 0
fi

printf '%d of %d mutations were NOT caught.\n' "$FAILURES" "$CHECKED" >&2
printf 'Those guards are decoration: the code can be broken without the suite noticing.\n' >&2
exit 1
