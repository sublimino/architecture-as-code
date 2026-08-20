#!/usr/bin/env bash
# shellcheck disable=SC2016
# ci-lane-reaper-mutation-proof.sh — prove test/terraform-ci-lifecycle.bats can
# fail, one safety gate at a time.
#
# ─── Why this file exists and why it is the important one ───────────────────
#
# scripts/ci/gcp-tf-reaper.sh SUSPENDS other people's machines. Until
# 2026-08-20 the property keeping it away from a demo VM was the instance's
# FILENAME-shaped name, `sl-ci-N-runner`. That selector moved onto the `ci-lane`
# label when modules/ci-runner was absorbed into modules/compute.
#
# A reaper safety test that cannot fail is WORSE than no test, because it reads
# as assurance. So each gate is deleted from the REAL script in turn and the
# specific named test that covers it must go red. A mutation that fails nothing
# is a finding, not a nuisance.
#
# ─── The two shapes this harness is built to avoid ──────────────────────────
#
# 1. A `sed` whose pattern no longer matches exits 0 and changes nothing. The
#    mutation test then runs against CORRECT code and passes — a proof of the
#    opposite of what it claims. `mutate` compares hashes and aborts on a no-op.
#
# 2. "No demo VM was suspended" is satisfied by nothing being suspended at all,
#    which is also what a broken selector produces. Every expectation below
#    therefore names a test that carries a POSITIVE control in the same body
#    (assert_a_real_lane_was_reaped), so a mutation that merely breaks the
#    reaper cannot masquerade as the guard firing correctly. M0 checks exactly
#    that property of the harness itself.
#
# ─── Restoration ────────────────────────────────────────────────────────────
#
# From a byte-for-byte backup in an out-of-repo mktemp dir, NEVER `git checkout`
# — which silently reverts in-progress work elsewhere in the tree, and whose
# resulting "the guard did not fire" reads exactly like a real finding.
#
# Both CONTENT and MODE are verified on restore. An agent on this project found
# that `mv` from a tempfile restores bytes identically while silently dropping
# the executable bit, which turns the next run's `[ -x "$reaper" ]` into a
# failure nobody attributes to this harness.
#
# Run: test/ci-lane-reaper-mutation-proof.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

REAPER="scripts/ci/gcp-tf-reaper.sh"
SUITE="test/terraform-ci-lifecycle.bats"

# ─── The sentinel ───────────────────────────────────────────────────────────
#
# Uniquely named, matched by `*mutation-in-progress` in .gitignore. Its presence
# means a previous run died holding a mutation, so the tree cannot be trusted to
# be the real thing. REFUSE — never auto-repair. A harness that silently
# restores what it found would make the broken state invisible, which is the
# same defect as a guard that repairs what it detects (CONTRACT §6).
SENTINEL="$REPO_ROOT/.ci-lane-reaper-mutation-in-progress"

if [[ -e "$SENTINEL" ]]; then
  cat >&2 <<EOF
HARNESS REFUSING TO START.

  A sentinel from a previous run is present:
    $SENTINEL

  That run died while ${REAPER} was MUTATED, so the working tree may contain a
  deliberately broken reaper. This harness will not repair it for you: an
  auto-repair would make the broken state invisible and the next green run
  would be measuring code nobody has looked at.

  It records the backup it was restoring from. Inspect, restore by hand, then
  delete the sentinel:

$(sed 's/^/    /' "$SENTINEL" 2>/dev/null || echo "    <sentinel is unreadable>")
EOF
  exit 2
fi

[[ -f "$REAPER" ]] || {
  echo "HARNESS ERROR: $REAPER not found" >&2
  exit 2
}
[[ -f "$SUITE" ]] || {
  echo "HARNESS ERROR: $SUITE not found" >&2
  exit 2
}

BACKUP="$(mktemp -d)"
cp -p "$REAPER" "$BACKUP/reaper.sh"

# Both axes, recorded before anything is touched.
ORIG_HASH="$(sha256sum "$REAPER" | cut -d' ' -f1)"
ORIG_MODE="$(stat -c '%a' "$REAPER")"

{
  printf 'reaper : %s\n' "$REPO_ROOT/$REAPER"
  printf 'backup : %s\n' "$BACKUP/reaper.sh"
  printf 'sha256 : %s\n' "$ORIG_HASH"
  printf 'mode   : %s\n' "$ORIG_MODE"
  printf 'started: %s\n' "$(date -Is)"
} >"$SENTINEL"

restore() {
  # `cp` onto the existing inode, not `mv` from the tempfile. mv replaces the
  # inode and carries the TEMPFILE's mode across — restoring the bytes exactly
  # while dropping the executable bit, which is how this failure was found.
  cp "$BACKUP/reaper.sh" "$REAPER"
  chmod "$ORIG_MODE" "$REAPER"
}

cleanup() {
  restore
  rm -f "$SENTINEL"
  rm -rf "$BACKUP"
}
trap cleanup EXIT

PASS=0
FAIL=0

# A sed that cannot silently do nothing.
mutate() {
  local expr="$1" before after
  before="$(sha256sum "$REAPER" | cut -d' ' -f1)"
  sed -i "$expr" "$REAPER"
  after="$(sha256sum "$REAPER" | cut -d' ' -f1)"
  if [[ "$before" == "$after" ]]; then
    echo "HARNESS ERROR: mutation did not change ${REAPER}: ${expr}" >&2
    exit 2
  fi
}

# Reports the NAMES of failing tests, never `not ok <n>` numbers. Inserting a
# test renumbers everything below it, and a harness that reports NOT PROVEN for
# a guard that fired perfectly well is worse than no harness — the natural
# response is to go and "fix" working code.
#
# `|| true` at the call site: a non-zero bats is the EXPECTED outcome here, and
# `set -o pipefail` would otherwise let `set -e` kill the harness on its first
# success.
failing_tests() {
  bats "$SUITE" 2>&1 | sed -n 's/^not ok [0-9]* //p'
}

check() {
  local label="$1" want="$2" got
  got="$(failing_tests || true)"
  if [[ "$got" == *"$want"* ]]; then
    echo "  RED as expected — \"${want}\"  [${label}]"
    PASS=$((PASS + 1))
  else
    echo "  *** NOT PROVEN: expected \"${want}\" to fail. Failures were:" >&2
    printf '        %s\n' "${got:-<none>}" >&2
    FAIL=$((FAIL + 1))
  fi
  restore
}

# The other half of a defence-in-depth proof: with the gates ABOVE a guard
# removed, the named test must STILL pass — which is what shows the guard below
# them is the thing now holding the line.
#
# Deliberately scoped to one named test rather than the whole suite. A compound
# mutation that isolates one gate necessarily lets other rows through, so
# demanding a wholly green suite here would be demanding something false.
check_still_green() {
  local label="$1" want="$2" got
  got="$(failing_tests || true)"
  if [[ "$got" == *"$want"* ]]; then
    echo "  *** NOT PROVEN: \"${want}\" went RED, so the guard under test is NOT" >&2
    echo "      what was holding the line. Failures were:" >&2
    printf '        %s\n' "${got:-<none>}" >&2
    FAIL=$((FAIL + 1))
  else
    echo "  STILL GREEN — \"${want}\"  [${label}]"
    PASS=$((PASS + 1))
  fi
  restore
}

# ─── Named single-gate mutations, so compounds are readable ─────────────────
#
# Each is used alone AND as part of a compound. Defined once so a compound and
# its single-gate counterpart can never drift apart, which is the failure mode
# that would let a "last line of defence" proof quietly test a different line.
del_gate2() { mutate 's#^    if ! printf .%s. "\$lane" | grep -Eq "\$LANE_LABEL_PATTERN"; then$#    if false; then#'; }
del_gate3() { mutate 's|^    if \[ "\${kind:-}" != "\$LANE_KIND" \]; then$|    if false; then|'; }
del_gate4() { mutate 's|^    if \[ "\${env:-}" != "\$lane" \]; then$|    if false; then|'; }
del_g5kind() { mutate 's|^  \[ "\$kind" = "\$DEMO_KIND" \] \&\& return 0$|  [ "$kind" = "@@never@@" ] \&\& return 0|'; }
del_g5env() { mutate 's#^  printf .%s. "\$env" | grep -Eq "\$DEMO_ENV_PATTERN" \&\& return 0$#  false \&\& return 0#'; }
del_g5name() { mutate 's|^    \*"\$DEMO_NAME_SUBSTRING"\*) return 0 ;;$|    "@@never@@") return 0 ;;|'; }

echo "=== baseline: the suite must be green before any mutation ==="
if ! bats "$SUITE" >/dev/null 2>&1; then
  echo "HARNESS ERROR: suite is not green before mutation" >&2
  bats "$SUITE" 2>&1 | tail -20 >&2
  exit 2
fi
echo "  GREEN"
echo ""

echo "=== mutations ==="

# ─── A note on sed delimiters, because this is where it goes quietly wrong ──
#
# An unescaped `|` or `/` inside a sed expression whose DELIMITER is that
# character is a syntax error, and a pattern that merely no longer matches exits
# 0 and changes nothing. Both present as "the guard did not fire", which is
# indistinguishable from a genuine finding.
#
# Two defences, and neither is optional:
#   * `mutate` compares sha256 BEFORE and AFTER and aborts on a no-op. Nothing
#     here infers application from sed's exit status.
#   * Expressions targeting a line containing `|` use `#` as the delimiter; the
#     one targeting a line containing `#` uses `|`. Marked per mutation below.
#
# `printf '%s'` appears in two target lines and cannot be written inside this
# file's single-quoted sed arguments, so those patterns use `.%s.` — the dots
# match the quote characters. That is a deliberate narrowing, not sloppiness:
# the surrounding text is anchored at both ends, so it cannot match another line.

# ─── M0: the harness's own control ──────────────────────────────────────────
#
# Force the DRY_RUN branch, so the reaper suspends NOTHING while still walking
# every gate. Every "a demo VM was not suspended" assertion in the suite is
# trivially satisfied by this — so if the suite stayed green here, every
# mutation below would be measuring nothing and this whole file would be
# theatre. The positive control inside each test (assert_a_real_lane_was_reaped)
# is what must catch it. Delimiter: `|`.
echo "M0  the reaper suspends nothing at all (the vacuous-pass control)"
mutate 's|^  if \[ "\$DRY_RUN" = "1" \]; then$|  if true; then|'
check "M0 positive control" "a demo VM is NEVER suspended, and a real CI lane IS"

# ─── M1: gate 1 falls back to a name match ──────────────────────────────────
#
# THE regression this whole change exists to prevent. An absent ci-lane label
# stops being a refusal and the script infers a lane from the name instead —
# the exact coupling that was removed, reintroduced in the code path that runs
# when the label mechanism is broken. Delimiter: `|` (replacement contains `#`).
echo "M1  gate 1 falls back to a name match when the ci-lane label is absent"
mutate 's|^    if \[ -z "\${lane:-}" \]; then$|    if [ -z "${lane:-}" ] \&\& [ "${name\#sl-ci-}" = "$name" ]; then|'
check "M1 no name fallback" "the selector is the ci-lane LABEL and refuses on its absence"

# ─── M2: gate 2 stops checking the label VALUE ──────────────────────────────
#
# The expectation here was originally the broad demo test, and it was WRONG —
# the first run of this harness reported NOT PROVEN and the harness was right.
# With gate 2 gone, sl-demo-1-vm is still refused by gate 3 (kind = demo). That
# is defence in depth working exactly as designed, and it means gate 2's UNIQUE
# contribution is not demo protection at all: it is rejecting a ci-lane value
# that is not a lane key. The fixture's `xci-6` row is the only one that
# isolates it. Recorded because the wrong expectation looked entirely reasonable.
echo "M2  gate 2 accepts any ci-lane value, including a malformed one"
del_gate2
check "M2 gate 2 label value" "GATE 2 a ci-lane value that merely CONTAINS a lane key is refused"

# ─── M3: gate 3 deleted ─────────────────────────────────────────────────────
#
# The gate that replaced the name shape. Delimiter: `|`.
echo "M3  gate 3 deleted (the kind label is no longer required to be ci)"
del_gate3
check "M3 gate 3 kind label" "GATE 3 an ABSENT kind label is a refusal, not a default"

# ─── M4: gate 3 fails OPEN on an absent label ───────────────────────────────
#
# The subtler half, and the one a reviewer would wave through. Rewritten as
# "refuse if kind == demo", which reads as equivalent and is not: an ABSENT kind
# label now passes. That is the state a stale five-column listing produces.
# Delimiter: `|`.
echo "M4  gate 3 rewritten as a demo denylist, so an ABSENT kind label passes"
mutate 's|^    if \[ "\${kind:-}" != "\$LANE_KIND" \]; then$|    if [ "${kind:-}" = "$DEMO_KIND" ]; then|'
check "M4 gate 3 fails closed" "GATE 3 an ABSENT kind label is a refusal, not a default"

# ─── M5: gate 4 deleted ─────────────────────────────────────────────────────
echo "M5  gate 4 deleted (environment need not agree with ci-lane)"
del_gate4
check "M5 gate 4 cross-check" "GATE 4 an environment label disagreeing with ci-lane is refused"

# ─── M6: gate 5's demo NAME marker deleted ──────────────────────────────────
#
# sl-demo-3-vm forges kind = ci AND environment = ci-3, so gates 1-4 all pass on
# it and only the name substring stops it. This is the one gate-5 marker that is
# reachable as a SOLE decider, which is why it needs no compound.
echo "M6  gate 5's demo NAME marker deleted (kind/environment markers kept)"
del_g5name
check "M6 gate 5 name marker" "GATE 5 a demo VM with fully forged ci labels is still refused"

# ═══ M7 / M8: the gate-5 markers that are NOT reachable as sole deciders ════
#
# THE FIRST RUN OF THIS HARNESS REPORTED BOTH OF THESE AS "NOT PROVEN", AND IT
# WAS RIGHT TO. Deleting either one on its own fails nothing, because gates 3
# and 4 refuse the same rows first. Per CONTRACT §7b that is a finding, so here
# is the finding, stated plainly rather than papered over:
#
#   gate 5's KIND marker can only decide an outcome if gate 3 is gone.
#   gate 5's ENVIRONMENT marker can NEVER decide an outcome on its own at all.
#     For it to be the last gate standing, `environment` must start with `demo-`
#     AND equal the ci-lane label (or gate 4 refuses first) AND the ci-lane label
#     must match ^ci-N$ (or gate 2 refuses first). Those three cannot hold at
#     once. It is unreachable-as-sole-decider by construction.
#
# The available responses were: delete them as dead code, or prove the property
# they actually have. They are NOT dead code — they are the layer that survives
# someone "simplifying" the label checks above them, which is the specific edit
# this file exists to make expensive. So what is proven is the honest claim:
#
#   with every gate above it removed, THIS marker alone still refuses the demo
#   VM — and removing it too lets the demo VM through.
#
# Both halves are asserted. The first half is what makes the second meaningful:
# without it, a compound mutation that broke the reaper entirely would produce
# the same red and prove nothing.

echo "M7a gates 3+4 and the other two demo markers removed — the KIND marker alone"
del_gate3
del_gate4
del_g5env
del_g5name
check_still_green "M7a kind marker holds the line" "GATE 3+4+5 a demo VM carrying a VALID ci-lane label is refused"

echo "M7b ...and now the KIND marker goes too"
del_gate3
del_gate4
del_g5env
del_g5name
del_g5kind
check "M7b kind marker is load-bearing" "GATE 3+4+5 a demo VM carrying a VALID ci-lane label is refused"

echo "M8a gates 2+3+4 and the other two demo markers removed — the ENV marker alone"
del_gate2
del_gate3
del_gate4
del_g5kind
del_g5name
check_still_green "M8a env marker holds the line" "the LIVE demo sl-demo-1-vm is never suspended"

echo "M8b ...and now the ENV marker goes too"
del_gate2
del_gate3
del_gate4
del_g5kind
del_g5name
del_g5env
check "M8b env marker is load-bearing" "the LIVE demo sl-demo-1-vm is never suspended"

# ─── M9: gate 6 deleted ─────────────────────────────────────────────────────
echo "M9  gate 6 deleted (the legacy signalloom-ci denylist)"
mutate 's|^    if is_protected "\$name"; then$|    if false; then|'
check "M9 gate 6 denylist" "GATE 6 the legacy signalloom-ci runners are NEVER suspended"

# ─── M10: the ci-lane label pattern loses its anchors ───────────────────────
#
# Unanchored, `ci-[1-9][0-9]*` matches INSIDE a longer token, so the fixture's
# `ci-lane = xci-6` row is admitted — and that row's environment agrees, its
# kind is ci and its name carries no demo marker, so nothing else stops it.
# This repo has already shipped the unanchored version of this bug: DEMO_ENV
# matching inside SL_DEMO_ENV.
#
# The replacement is an UNQUOTED assignment on purpose: neither word splitting
# nor globbing applies to the right-hand side of an assignment, so `[1-9]` stays
# literal, and it lets the expression avoid nesting single quotes. Delimiter:
# `#`; the pattern is `.*` because the original value contains quotes this
# file's single-quoted argument cannot carry.
echo "M10 the ci-lane label pattern is unanchored"
mutate 's#^readonly LANE_LABEL_PATTERN=.*#readonly LANE_LABEL_PATTERN=ci-[1-9][0-9]*#'
check "M10 anchored label pattern" "GATE 2 a ci-lane value that merely CONTAINS a lane key is refused"

# ─── M11: the field-shift defect, reintroduced ──────────────────────────────
#
# The two label columns are read in the wrong order, which is precisely what the
# tab separator used to do by itself: with `IFS=$'\t'` an empty kind column
# collapsed and every later field shifted left, so `kind` silently received the
# ENVIRONMENT value. The gate refused the row either way, so no green run could
# ever have shown it — which is why the message text is asserted and not merely
# the outcome. Delimiter: `#`.
echo "M11 the kind and environment columns are read in the wrong order"
mutate 's#read -r name zone lane ts status kind env; do$#read -r name zone lane ts status env kind; do#'
check "M11 columns read in order" "GATE 3 an ABSENT kind label is a refusal, not a default"

# ─── M12: the silent no-op report is removed ────────────────────────────────
#
# A zero left to speak for itself. This is the failure mode the whole selector
# change exists to make visible.
echo "M12 the empty-listing NOTE is removed (a zero is left to speak for itself)"
mutate 's|^  if \[ "\$seen" -eq 0 \]; then$|  if false; then|'
check "M12 loud no-op" "an empty listing is reported as inconclusive, not as success"

echo ""
echo "=== restored: the suite must be green again ==="
restore
if ! bats "$SUITE" >/dev/null 2>&1; then
  echo "HARNESS ERROR: suite is not green after restore" >&2
  exit 2
fi
echo "  GREEN"
echo ""

# ─── Restoration verified on BOTH axes, and reported ────────────────────────
FINAL_HASH="$(sha256sum "$REAPER" | cut -d' ' -f1)"
FINAL_MODE="$(stat -c '%a' "$REAPER")"

echo "=== restoration ==="
printf '  sha256 before : %s\n' "$ORIG_HASH"
printf '  sha256 after  : %s\n' "$FINAL_HASH"
printf '  mode   before : %s\n' "$ORIG_MODE"
printf '  mode   after  : %s\n' "$FINAL_MODE"

if [[ "$ORIG_HASH" != "$FINAL_HASH" ]]; then
  echo "  *** RESTORATION FAILED: content differs" >&2
  FAIL=$((FAIL + 1))
elif [[ "$ORIG_MODE" != "$FINAL_MODE" ]]; then
  echo "  *** RESTORATION FAILED: mode differs (the executable bit is the one that goes)" >&2
  FAIL=$((FAIL + 1))
else
  echo "  VERIFIED — content and mode both identical"
fi

echo ""
echo "proven: ${PASS}   NOT proven: ${FAIL}"
[[ "$FAIL" -eq 0 ]]
