#!/usr/bin/env bash
# four-lane-loop-mutation-proof.sh — prove the four-lane loop's guards can fail.
#
# test/terraform-four-lane-loop.bats is 40 assertions about a harness that
# destroys and rebuilds four estates N times. A green suite is evidence of
# nothing until each guard has been shown to go RED for the right reason,
# against the REAL file, for a defect a person could plausibly introduce — and
# for this harness "plausibly" is not hypothetical: the PIPESTATUS index and the
# `yes yes` spelling are each one character away from a silent inversion, and
# the header comment shipped with the WRONG index written into it.
#
# The guards proven here are the ones carrying the actual value:
#
#   the preflight really delegates             (not a second copy of the manifest)
#   the caller's stricter required-set is real (REQUIRE_ALSO is not decoration)
#   the preflight fails CLOSED                 (a missing delegate is not a pass)
#   `check`, not `gate`                        (gate is a no-op in a main checkout)
#   every lane's exit code is recorded         (a silent lane is not a green lane)
#   a non-zero lane exit is not lost
#   the destroy answers "yes", not "y"
#   PIPESTATUS[1] is `make`, not `yes`         (pipefail turns a success into 141)
#   a gcloud error is not an empty estate
#   capacity gates the create, rather than warning and creating anyway
#   the verdict comes from summary.json
#
# Restore is from a byte-for-byte backup taken here, NOT `git checkout`.
# `git checkout <path>` in a proof harness wipes in-progress edits elsewhere in
# the tree, and the resulting "the guard did not fire" reads exactly like a real
# finding.
#
# ─── SAFETY: the one mutation this harness deliberately does NOT perform ────
#
# scripts/gcp-tf/four-lane-loop.sh guards its driver with
# `[[ "${BASH_SOURCE[0]}" == "${0}" ]]`, and the whole suite depends on it: the
# tests reach the harness's functions by SOURCING the real file. The mutation
# that falsifies "sourcing the script runs no phase at all" is to make that
# condition always true — at which point every `source` in the suite runs
# `make gcp-tf-destroy` against live GCP infrastructure. That experiment is not
# worth its result, so it is not run, and that test is reported at the end as
# structurally proven and behaviourally UNPROVEN rather than quietly counted.
#
# Offline: no terraform, no gcloud, no network, no credentials. Every fixture is
# a temp dir and every external command the suite touches is stubbed on PATH.
#
# Run: test/four-lane-loop-mutation-proof.sh

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LOOP="scripts/gcp-tf/four-lane-loop.sh"
DELEGATE="scripts/gcp-tf/worktree-bootstrap.sh"
BATS_SUITE="test/terraform-four-lane-loop.bats"
DELEGATE_SUITE="test/terraform-worktree-bootstrap.bats"

# ── The shared safety rail ──────────────────────────────────────────────────
#
# The comment that used to sit here said the trap "does NOT run on SIGKILL, so
# a -9 during a mutation leaves the tree modified — check `git status`". That
# was accurate and it was not enough: it asked a human to notice, and the whole
# failure mode is that nobody does. The helper leaves a marker that outlives a
# hard kill, REFUSES to start on top of one rather than repairing it, and
# verifies the restore on content AND mode.
#
# $DELEGATE is shared with test/worktree-bootstrap-mutation-proof.sh, so the
# per-proof sentinel name matters here: a shared marker would let one proof's
# restore clear the other's evidence.
# See test/helpers/mutation-sentinel.bash.
# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"

ms_guard_init four-lane-loop "$LOOP" "$DELEGATE"
trap ms_guard_on_exit EXIT

# The rail reapplies and then verifies the recorded mode, so the explicit
# `chmod +x` the old restore_all carried is redundant rather than dropped.
restore_all() { ms_guard_restore; }

PASS=0
FAIL=0

# A sed that cannot silently do nothing.
#
# A non-matching pattern no-ops while returning 0, so the mutation never lands,
# the suite stays green, and the harness reports "guard did not fire" — a false
# finding that looks exactly like a real one, and one that sends somebody to
# "fix" working code.
#
# ms_sed keeps that refusal verbatim and adds two things: it tells a sed SYNTAX
# ERROR apart from a pattern that no longer matches, and it ARMS the sentinel
# before touching the file so no call site can forget.
mutate() { ms_sed "$1" "$2"; }

# Reports the NAMES of failing tests, not the `not ok <n>` numbers: inserting a
# test renumbers everything below it, and a harness that reports NOT PROVEN for
# a guard that fired perfectly well is worse than no harness.
#
# A non-zero bats is the EXPECTED outcome here, and `set -o pipefail` promotes it
# to the pipeline's status, so `|| true` at the call site is what stops `set -e`
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

echo "=== baseline: both suites must be green before any mutation ==="
for s in "$BATS_SUITE" "$DELEGATE_SUITE"; do
  if ! bats "$s" >/dev/null 2>&1; then
    echo "HARNESS ERROR: ${s} is not green before mutation" >&2
    bats "$s" 2>&1 | tail -20 >&2
    exit 2
  fi
  echo "  GREEN  ${s}"
done
echo ""

echo "=== mutations ==="

# ── The reconciliation is real: the preflight DELEGATES ────────────────────
#
# If the delegation were decorative — the call removed while the comments stayed
# — nothing else in the preflight would notice, because the loop no longer
# carries its own copy of the checks.

echo "M1  the delegate is never invoked (the preflight becomes a no-op)"
mutate "$LOOP" 's#"\$WORKTREE_SCRIPT" check#true#'
check_bats "M1 preflight delegates" "preflight refuses a tree missing deploy/gcp/deploy-sa and names it"

echo "M2  the preflight calls \`gate\`, which is a NO-OP outside a linked worktree"
mutate "$LOOP" 's#"\$WORKTREE_SCRIPT" check#"$WORKTREE_SCRIPT" gate#'
check_bats "M2 check not gate" "the preflight calls check, not gate — gate is a no-op outside a worktree"

# ── REQUIRE_ALSO is load-bearing, not decoration ───────────────────────────
#
# This is the mechanism the whole reconciliation rests on: the loop's stricter
# required-set travels to the delegate as a parameter instead of as a second
# implementation. If it were being dropped on the floor, the manifest-only
# checks would still pass and the reconciliation would look successful.

echo "M3  REQUIRE_ALSO is dropped, so the caller's stricter required-set vanishes"
mutate "$LOOP" 's#REQUIRE_ALSO="\$(printf#REQUIRE_ALSO_IGNORED="$(printf#'
check_bats "M3 REQUIRE_ALSO is real" "preflight refuses a tree missing the lane tfvars it exports as GCP_TF_VAR_FILE"

echo "M4  the same defect, seen on the signing key rather than on the tfvars"
mutate "$LOOP" 's#REQUIRE_ALSO="\$(printf#REQUIRE_ALSO_IGNORED="$(printf#'
check_bats "M4 REQUIRE_ALSO covers .keys" "preflight refuses a tree missing .keys/cosign.key and names it"

echo "M5  the tfvars requirement is hardcoded instead of following GCP_TF_VAR_FILE"
mutate "$LOOP" 's#local var_file_rel="deploy/gcp/\$(basename "\$GCP_TF_VAR_FILE")"#local var_file_rel="deploy/gcp/sl-port-over-sandbox.tfvars"#'
check_bats "M5 tfvars follows the export" "the lane-tfvars requirement FOLLOWS GCP_TF_VAR_FILE rather than repeating it"

echo "M6  the delegate prefixes absolute REQUIRE_ALSO entries with REPO_ROOT"
# KUBESEC_AFM_ROOT is a separate clone, not a file under the repo. Prefixing it
# produces a path that exists nowhere — so the check fails for everything and
# passes for nothing, which is the worst of both.
mutate "$DELEGATE" 's#      /\*) abs="\$rel" ;;#      /*) abs="${REPO_ROOT}/${rel}" ;;#'
check_bats "M6 absolute entries" "preflight passes on a complete tree"

# ── The preflight fails CLOSED ─────────────────────────────────────────────
#
# Not hypothetical in this repo: the worktree-bootstrap guard shipped a first
# draft that skipped itself when its own script was absent, and a fresh worktree
# sailed straight past it into terraform.

echo "M7  a missing delegate is skipped rather than refused (fails open)"
mutate "$LOOP" 's#if \[ ! -x "\$WORKTREE_SCRIPT" \]; then#if false; then#'
check_bats "M7 fail closed" "preflight REFUSES when the delegate is missing, rather than skipping it"

# ── Every lane's exit code is recorded ─────────────────────────────────────
#
# THE central claim of this harness. A lane that recorded nothing is not the
# same as a lane that recorded success, and the previous implementation could
# not tell them apart — it computed `grep -cv '=0$' file || echo 0`, which on an
# empty file yields "0\n0" and turns the next arithmetic into a syntax error.

echo "M8  a results file short of a lane is accepted"
# `|` as the delimiter, not `#`: the construct being matched contains `${#LANES[@]}`,
# and a `#` delimiter turns that into `unknown option to \`s'`.
mutate "$LOOP" 's|if \[ "${recorded:-0}" -ne "${#LANES\[@\]}" \]; then|if false; then|'
check_bats "M8 every lane recorded" "a lane that records NOTHING is refused, not read as success"

echo "M9  the same defect, seen on a results file that is entirely empty"
# `|` as the delimiter, not `#`: the construct being matched contains `${#LANES[@]}`,
# and a `#` delimiter turns that into `unknown option to \`s'`.
mutate "$LOOP" 's|if \[ "${recorded:-0}" -ne "${#LANES\[@\]}" \]; then|if false; then|'
check_bats "M9 empty results file" "an empty results file does not read as success either"

echo "M10 a non-zero lane exit no longer makes the phase fail"
mutate "$LOOP" 's#\[ "${bad:-0}" -gt 0 \] && return 1#[ "${bad:-0}" -gt 9999 ] \&\& return 1#'
check_bats "M10 failures propagate" "a non-zero lane exit is not lost: fan_out reports failure"

# ── The destroy pipeline ───────────────────────────────────────────────────

echo "M11 \`yes yes\` degrades to a bare \`yes\`, which emits \"y\""
# terraform answers "Destroy cancelled" to anything but exactly "yes" — a
# destroy that appears to run, does nothing, and leaves the estate standing for
# the next create to deadlock against.
mutate "$LOOP" 's#yes yes | make gcp-tf-destroy#yes | make gcp-tf-destroy#'
check_bats "M11 the confirmation is \"yes\"" 'the destroy answers "yes", not "y"'

echo "M12 the PIPESTATUS index is \"corrected\" to [0], which is \`yes\`"
# This is the mutation the shipped header comment was actively inviting: it read
# "Hence \${PIPESTATUS[0]}" while the code correctly used [1]. Under pipefail,
# `yes` dies of SIGPIPE with 141 the moment terraform stops reading, so [0]
# turns every SUCCESSFUL destroy into a failure.
mutate "$LOOP" 's#PIPESTATUS\[1\]#PIPESTATUS[0]#'
check_bats "M12 PIPESTATUS index" 'the PIPESTATUS index selects make, not `yes`'

echo "M13 the same index defect, seen as a successful destroy reported as failed"
mutate "$LOOP" 's#PIPESTATUS\[1\]#PIPESTATUS[0]#'
check_bats "M13 SIGPIPE is not a failure" "a successful destroy is not reported as a failure by SIGPIPE"

# ── Capacity ───────────────────────────────────────────────────────────────

echo "M14 a gcloud error is treated as an empty estate"
# The defect the guard was carrying before this branch: `gcloud 2>/dev/null |
# wc -l` reports 0 for an expired credential exactly as it does for an empty
# project, so four applies get launched into an estate that is still standing.
mutate "$LOOP" 's#if \[ "\$rc" -ne 0 \]; then#if false; then#'
check_bats "M14 an error is not empty" "a FAILING gcloud is not read as an empty estate"

echo "M15 capacity is downgraded from a gate back to a warning"
# The stated invariant is that teardown must FULLY complete before any create.
# Warning and then creating anyway is that invariant written down and not
# enforced, which is where it was.
mutate "$LOOP" 's#if ! wait_for_capacity; then#if false; then#'
check_bats "M15 capacity gates the create" "capacity is verified free BEFORE any create — no create happens otherwise"

# ── The verdict is derived from the report ─────────────────────────────────

echo "M16 the per-lane report is never read"
mutate "$LOOP" 's#if \[ -r "\$s" \]; then#if false; then#'
check_bats "M16 verdict from summary.json" "the cycle verdict comes from summary.json, not from the driver exit code"

echo "M17 an unparseable report renders as a blank rather than as a verdict"
# jq failing leaves the verdict empty, and an empty verdict renders as a line
# with nothing after the lane name — which reads as "nothing to report".
mutate "$LOOP" 's#\[ -n "\$v" \] || v="UNREADABLE-VERDICT"#:#'
check_bats "M17 no blank verdicts" "an unparseable report is recorded as UNREADABLE-VERDICT, not as a blank"

# ── The suite can reach the functions at all ───────────────────────────────
#
# See the SAFETY note at the top: only the `if false` direction is mutated. The
# always-true direction is what would prove the behavioural companion test, and
# it makes every `source` in the suite run a live destroy.

echo "M18 the executed-not-sourced guard is removed"
mutate "$LOOP" 's#if \[\[ "${BASH_SOURCE\[0\]}" == "${0}" \]\]; then#if false; then#'
check_bats "M18 driver is guarded" "the driver is behind an executed-not-sourced guard"

echo ""
echo "=== restored: both suites must be green again ==="
for s in "$BATS_SUITE" "$DELEGATE_SUITE"; do
  if ! bats "$s" >/dev/null 2>&1; then
    echo "HARNESS ERROR: ${s} did not return to green after restore" >&2
    bats "$s" 2>&1 | tail -20 >&2
    exit 2
  fi
  echo "  GREEN  ${s}"
done

# The harness must leave no trace. A proof that mutates the tree and does not put
# it back is indistinguishable, to the next reader, from a broken branch.
#
# Compared against the BACKUP, not against HEAD: on a branch where this work is
# not yet committed the files are legitimately modified or untracked before the
# harness even starts, and `git status --porcelain` would report failure on a
# correct run. The invariant this harness owns is "what I found is what I left".
restore_failed=0
cmp -s "$BACKUP/four-lane-loop.sh" "$LOOP" || restore_failed=1
cmp -s "$BACKUP/worktree-bootstrap.sh" "$DELEGATE" || restore_failed=1
if [ "$restore_failed" -ne 0 ]; then
  echo "HARNESS ERROR: a mutated file was not restored to its pre-run content" >&2
  diff "$BACKUP/four-lane-loop.sh" "$LOOP" | head -20 >&2 || true
  diff "$BACKUP/worktree-bootstrap.sh" "$DELEGATE" | head -20 >&2 || true
  exit 2
fi
echo "  every mutated file matches its pre-run content"
echo ""

echo "=== NOT MUTATION-PROVEN, recorded rather than omitted ==="
echo "  \"sourcing the script runs no phase at all\" — the only mutation that"
echo "  falsifies it makes every \`source\` in the suite run \`make gcp-tf-destroy\`"
echo "  against live GCP. Structurally proven by M18; behaviourally unproven."
echo ""

echo "=== ${PASS} proven, ${FAIL} not proven ==="
[[ "$FAIL" -eq 0 ]]
