#!/usr/bin/env bash
# afm-delivery-mutation-proof.sh — prove the AFM delivery guards can fail.
#
# A green suite is evidence of nothing until each guard has been shown to go RED
# for the right reason. This repo has shipped guards that were pure decoration:
# a `! grep` that is dead under `set -e`, a `[ "$status" -ne 0 ]` that reads a
# MISSING FILE as "pattern absent", a mechanism assertion that passed vacuously
# because its own discovery returned empty.
#
# The guard this file exists for was the worst of that family, because it was
# not merely inert — it was ANTI-correlated with the truth.
# test/acceptance/smoke.spec.ts asserted that the RBAC Analysis page contains
# the text "KubeSec-AFM", which renders in the page's description paragraph AND
# again inside the "KubeSec-AFM platform is not reachable" error banner. It was
# satisfied twice over in exactly the broken state it existed to catch, and it
# was green on four lanes while every one of them served a 502 on /afm/.
#
# So: introduce each defect into the real file, confirm the EXPECTED test goes
# red, restore, confirm green again.
#
# Restore is from a byte-for-byte backup taken here, NOT `git checkout`.
# `git checkout <dir>` in a proof harness wipes in-progress edits elsewhere in
# the tree, and the resulting "the guard did not fire" reads exactly like a real
# finding.
#
# Run: test/afm-delivery-mutation-proof.sh

# Mutations are single-quoted sed expressions SO THAT `$` stays literal — these
# patterns match shell and make variables in the source files, they do not
# expand them. Double-quoting as SC2016 suggests would expand
# `$AFM_IMAGE_ARCHIVE` against this harness's own environment, produce a pattern
# matching nothing, and `mutate` would abort the run.
# shellcheck disable=SC2016

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

AFM_SH="scripts/k8s-afm.sh"
MAKEFILE="Makefile"
BACKENDS="scripts/check-backends.sh"
PIPELINE="scripts/ci/vm-pipeline.sh"

SUITE_AFM="test/k8s-afm-preflight.bats"
SUITE_BACKENDS="d2-signalloom/test/dashboard-backends.bats"

# Unique to THIS harness, per the contract in .gitignore. A shared sentinel is
# worse than none: another harness's restore would delete this one's marker, so
# the next run would read a leaked mutation as a genuine regression and the
# refusal that exists to catch it would never fire.
SENTINEL="test/.afm-delivery-mutation-in-progress"

if [ -e "$SENTINEL" ]; then
  cat >&2 <<EOF
REFUSING TO START: $SENTINEL exists.

A previous run of this harness was killed while a REAL file was deliberately
broken, so the repository is very likely still mutated. Traps do not survive
SIGKILL, which is what a tool timeout escalates to.

This harness does NOT repair, on purpose: a guard that silently fixes the thing
it is measuring makes the next run green and hides the damage. Inspect and
restore by hand, then delete the sentinel:

    git diff -- $AFM_SH $MAKEFILE $BACKENDS $PIPELINE
    git checkout -- <whichever of those is mutated>
    rm $SENTINEL
EOF
  exit 2
fi

BACKUP="$(mktemp -d)"
: > "$SENTINEL"
trap 'restore_all; rm -f "$SENTINEL"; rm -rf "$BACKUP"' EXIT

for f in "$AFM_SH" "$MAKEFILE" "$BACKENDS" "$PIPELINE"; do
  mkdir -p "$BACKUP/$(dirname "$f")"
  cp "$f" "$BACKUP/$f"
done

restore_all() {
  local f
  for f in "$AFM_SH" "$MAKEFILE" "$BACKENDS" "$PIPELINE"; do
    [ -f "$BACKUP/$f" ] && cp "$BACKUP/$f" "$f"
  done
  return 0
}

PASS=0
FAIL=0

# A sed that cannot silently do nothing.
#
# A non-matching pattern no-ops while returning 0, so the mutation never lands,
# the suite stays green, and the harness reports "guard did not fire" — a false
# finding that looks exactly like a real one.
mutate() {
  local file="$1" expr="$2" before after
  before="$(md5sum "$file" | cut -d' ' -f1)"
  sed -i "$expr" "$file"
  after="$(md5sum "$file" | cut -d' ' -f1)"
  if [[ "$before" == "$after" ]]; then
    echo "HARNESS ERROR: mutation did not change ${file}: ${expr}" >&2
    exit 2
  fi
}

# Reports the NAMES of the tests that failed, not the `not ok <n>` numbers.
# Inserting a test in the middle of a suite renumbers everything below it, so
# number-keyed expectations silently start pointing at the wrong test — and a
# harness that reports NOT PROVEN for a guard that fired perfectly well is worse
# than no harness, because the natural response is to "fix" working code.
#
# A non-zero bats is the EXPECTED outcome, and `set -o pipefail` promotes it to
# the pipeline's status — so without `|| true` at the call site, `set -e` kills
# the harness on its first SUCCESS.
failing_tests() {
  bats "$1" 2>&1 | sed -n 's/^not ok [0-9]* //p'
}

check() {
  local label="$1" suite="$2" want="$3" got
  got="$(failing_tests "$suite" || true)"
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
for s in "$SUITE_AFM" "$SUITE_BACKENDS"; do
  if ! bats "$s" >/dev/null 2>&1; then
    echo "HARNESS ERROR: $s is not green before mutation" >&2
    bats "$s" 2>&1 | tail -20 >&2
    exit 2
  fi
  echo "  GREEN  $s"
done
echo ""

echo "=== mutations ==="

# ── The delivery route itself ───────────────────────────────────────────────

echo "M1  the archive route is removed (source checkout becomes the only way again)"
mutate "$AFM_SH" 's|^have_afm_archive() { \[ -s "$AFM_IMAGE_ARCHIVE" \]; }|have_afm_archive() { false; }|'
check "M1 archive route exists" "$SUITE_AFM" "preflight passes on a delivered archive with NO source checkout"

echo "M2  archive presence checked with -f, so a zero-byte file counts as an image"
mutate "$AFM_SH" 's|^have_afm_archive() { \[ -s |have_afm_archive() { [ -f |'
check "M2 empty archive rejected" "$SUITE_AFM" "an EMPTY archive is not a usable archive"

echo "M3  the refusal stops naming the archive path (names only the source, as before)"
mutate "$AFM_SH" 's|^  2. delivered archive NOT FOUND at: $AFM_IMAGE_ARCHIVE$|  2. delivered archive NOT FOUND|'
check "M3 refusal names both routes" "$SUITE_AFM" "preflight names BOTH routes, and the variable that relocates each"

echo "M4  'save' no longer refuses without source (exits 0 having produced nothing)"
mutate "$AFM_SH" "/'save' builds the image and so needs the source checkout/,/^    }\$/{s/exit 1/exit 0/}"
check "M4 save refuses" "$SUITE_AFM" "save refuses without source and says an archive cannot substitute"

# ── The fail-closed contract ────────────────────────────────────────────────

# The trailing ` \` is part of the pattern. Omitting it is why the first draft
# of this harness aborted at M5: the expression matched nothing, `mutate`
# refused to continue, and without that refusal the suite would have stayed
# green and this file would have reported the guard as not firing.
echo "M5  fail-closed reverted to warn-and-continue (the pre-existing behaviour)"
mutate "$MAKEFILE" 's|^	elif \[ "$(AFM_REQUIRED)" = "0" \]; then \\$|	elif true; then \\|'
check "M5 AFM absence is fatal" "$SUITE_AFM" "the AFM deploy step FAILS the bring-up when no image can be obtained"

echo "M6  AFM_REQUIRED=0 stops being honoured (fail-closed with no way out)"
mutate "$MAKEFILE" 's|^	elif \[ "$(AFM_REQUIRED)" = "0" \]; then \\$|	elif false; then \\|'
check "M6 opt-out honoured" "$SUITE_AFM" "AFM_REQUIRED=0 still warns rather than failing"

# ── Lifecycle membership ────────────────────────────────────────────────────

echo "M7  the AFM deploy is dropped from demo-signalloom-up (the original bug)"
mutate "$MAKEFILE" 's|^	\$(MAKE) demo-signalloom-afm-up$|	@true|'
check "M7 lifecycle deploys AFM" "$SUITE_AFM" "the Signal Loom lifecycle deploys the AFM slice its RBAC page reads from"

echo "M8  the backend assertion is dropped from demo-signalloom-up"
mutate "$MAKEFILE" 's|^	\$(MAKE) check-backends$|	@true|'
check "M8 lifecycle checks backends" "$SUITE_AFM" "the lifecycle asserts every dashboard backend is actually reachable"

echo "M9  the backend assertion is dropped from the hand-copied CI pipeline"
mutate "$PIPELINE" 's|^if ! make check-backends; then$|if ! true; then|'
check "M9 CI checks backends" "$SUITE_BACKENDS" "BACKENDS the CI pipeline runs the backend check"

# ── The vacuous-pass defect in check-backends itself ────────────────────────
#
# This is the mutation that restores the REAL pre-existing defect, measured on
# the parent commit: with `|| true`, a run against no cluster exited 0 printing
# "All nginx upstreams are declared and reachable" immediately after printing
# "UNAVAILABLE no reachable cluster". Wiring that into a pipeline stage would
# have produced a gate that passes hardest when it is looking at nothing.
echo "M10 check-backends discards the no-cluster verdict again (|| true)"
mutate "$BACKENDS" 's|^  live)   check_static; check_live \|\| could_not_look=1 ;;$|  live)   check_static; check_live \|\| true ;;|'
check "M10 no-cluster is a failure" "$SUITE_BACKENDS" "BACKENDS live mode FAILS when there is no cluster to ask"

echo ""
echo "=== restored: both suites must be green again ==="
restore_all
for s in "$SUITE_AFM" "$SUITE_BACKENDS"; do
  if ! bats "$s" >/dev/null 2>&1; then
    echo "HARNESS ERROR: $s is not green after restore" >&2
    exit 2
  fi
  echo "  GREEN  $s"
done
echo ""
echo "proven: ${PASS}   NOT proven: ${FAIL}"
[[ "$FAIL" -eq 0 ]]
