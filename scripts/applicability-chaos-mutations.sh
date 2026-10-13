#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/applicability-chaos-mutations.sh: prove the applicability chaos suites
# can fail, one guard at a time.
#
# @doc   docs/policy-as-versioned-code/README.md
# @tests test/applicability-chaos.bats
#
# WHY THIS EXISTS. A chaos suite is the easiest kind of test to write
# vacuously: every case returns HTTP 200, every assertion is about a number
# nobody can re-derive by eye, and a suite that asserts nothing passes exactly
# like one that asserts everything. So each test in the two chaos suites is
# paired here with a MUTATION that breaks precisely the guard it names. The
# mutation must make that test — and only a test that genuinely depends on the
# guard — go red. A mutation that changes nothing is reported as VOID and fails
# this script, because it means the test it was paired with cannot fail.
#
# TWO ROWS ARE DELIBERATELY INVERTED, and they are the two tests whose names end
# _REPORTED_DEFECT. Those tests characterise behaviour we consider WRONG and did
# not change, because the fix is a change to the applicability semantics and
# therefore out of scope. Their "mutation" is the actual fix: applying it must
# turn them red. That is how a characterisation test earns its place — it proves
# the defect is still there, and it tells whoever fixes it, by going red, that
# the fix landed.
#
# RESTORATION IS FROM AN EXPLICIT COPY, never from git. A `git checkout -- .`
# would also discard any unrelated uncommitted work in the tree and would not
# restore an untracked file at all.
#
# Usage:
#   scripts/applicability-chaos-mutations.sh [--list]

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ENGINE="$REPO_ROOT/d2-signalloom/apps/policy-engine"

APP_GO="$ENGINE/frameworks/applicability.go"
COMPLIANCE_GO="$ENGINE/compliance.go"
BINDINGS_GO="$ENGINE/bindings.go"
CORPUS="$ENGINE/frameworks/testdata/chaos-date-corpus.tsv"

# Every file a mutation may touch. Backed up, restored and byte-compared as a
# set, so adding a mutation against a new file cannot forget the restore.
FILES=("$APP_GO" "$COMPLIANCE_GO" "$BINDINGS_GO" "$CORPUS")

# NAME|FILE|TEST_REGEX|PACKAGE|FIND|REPLACE
# FIND must appear EXACTLY ONCE in FILE; the harness refuses otherwise, because
# a pattern that matched twice mutates something the row does not name.
MUTATIONS=(
"absence-sentinel|$APP_GO|TestChaosDate_YearOneIsADateNotAnAbsence|./frameworks|return !d.set|return d.t.IsZero()"
"absence-sentinel-validator|$APP_GO|TestChaosDate_ValidatorSeesYearOneAsADate|./frameworks|return !d.set|return d.t.IsZero()"
"absence-sentinel-response|$APP_GO|TestChaosDeterminism_GatedFlagAndUngatedListAreNeverBothTrue|.|return !d.set|return d.t.IsZero()"
"loose-layout|$APP_GO|TestChaosDate_ParsesToTheDeclaredDayOrNotAtAll|./frameworks|const dateLayout = \"2006-01-02\"|const dateLayout = \"2006-1-2\""
"lenient-whitespace|$APP_GO|TestChaosDate_ParsesToTheDeclaredDayOrNotAtAll|./frameworks|\tif s != strings.TrimSpace(s) {\n\t\treturn Date{}, fmt.Errorf(\"date %q has surrounding whitespace; want YYYY-MM-DD\", s)\n\t}|\ts = strings.TrimSpace(s)"
"non-canonical-string|$APP_GO|TestChaosDate_AcceptedInputsRoundTripExactly|./frameworks|func (d Date) String() string { return d.t.Format(dateLayout) }|func (d Date) String() string { return d.t.Format(\"2006-1-2\") }"
"zone-dependent-parse|$APP_GO|TestChaosDate_IndifferentToServerTimezone|./frameworks|t, err := time.ParseInLocation(dateLayout, s, time.UTC)|t, err := time.ParseInLocation(dateLayout, s, time.Local)\n\tt = t.UTC()"
"zone-dependent-source|$APP_GO|TestChaosDeterminism_NoClockReadInTheApplicabilitySource|.|t, err := time.ParseInLocation(dateLayout, s, time.UTC)|t, err := time.ParseInLocation(dateLayout, s, time.Local)\n\tt = t.UTC()"
"inforcefrom-exclusive|$APP_GO|TestChaosWindow_HalfOpenBoundaryHoldsAtEveryResolutionLevel|.|func (d Date) OnOrAfter(other Date) bool { return !d.t.Before(other.t) }|func (d Date) OnOrAfter(other Date) bool { return d.t.After(other.t) }"
"supersededfrom-exclusive|$APP_GO|TestChaosWindow_SupersededWithNoSuccessorRetiresTheCheckButKeepsItsFigure|.|if d, err := ParseDate(a.SupersededFrom); err == nil && asOf.OnOrAfter(d) {|if d, err := ParseDate(a.SupersededFrom); err == nil && asOf.t.After(d.t) {"
"inverted-window-accepted|$APP_GO|TestChaosWindow_DegenerateAndInvertedWindowsNeverServeAVerdict|.|if !inForce.IsZero() && !d.t.After(inForce.t) {|if !inForce.IsZero() && d.t.After(inForce.t) && false {"
"resolution-order-least-specific-wins|$APP_GO|TestChaosResolve_LooserChildWindowWinsWholeOverATighterParent|.|[]*Applicability{chk.Applicability, ctrl.Applicability, cs.Applicability}|[]*Applicability{cs.Applicability, ctrl.Applicability, chk.Applicability}"
"gated-exposure-counted|$COMPLIANCE_GO|TestChaosExposure_SummaryTotalEqualsTheSumOfItsOwnCountedRows|.|\t\t\t\tsummary.NotInForce++\n\t\t\t\tcontinue|\t\t\t\tsummary.NotInForce++"
"gated-row-dropped-from-denominator|$COMPLIANCE_GO|TestChaosExposure_EveryCheckGatedIsExactlyZeroAndTotalControlsStaysHonest|.|\t\t\t\tsummary.NotInForce++\n\t\t\t\tcontinue|\t\t\t\tsummary.NotInForce++\n\t\t\t\tsummary.TotalControls--\n\t\t\t\tcontinue"
"gate-reason-dropped|$BINDINGS_GO|TestChaosExposure_NotInForceRowsCarryAReasonInTheErrorFieldAndStillCostNothing|.|return VerdictNotInForce, \"the obligation does not apply on the assessmentDate\"|return VerdictNotInForce, \"\""
"nondeterministic-seed|$COMPLIANCE_GO|TestChaosDeterminism_SameRequestTwiceIdenticalExceptTheScanTimestamp|.|seed := checkSeed(cwc.Check.ID)|seed := checkSeed(cwc.Check.ID) + uint64(time.Now().UnixNano())"
"absent-date-becomes-today|$COMPLIANCE_GO|TestChaosDeterminism_AbsentAssessmentDateGatesNothingAndSaysSoTwice|.|\tvar asOf frameworks.Date\n\tif req.AssessmentDate != \"\" {|\tvar asOf frameworks.Date\n\tif req.AssessmentDate == \"\" {\n\t\treq.AssessmentDate = time.Now().UTC().Format(\"2006-01-02\")\n\t}\n\tif req.AssessmentDate != \"\" {"
"window-echo-dropped|$COMPLIANCE_GO|TestChaosReplay_EditingAWindowFlipsStoredVerdictsWithNoVersionChange|.|\t\t\t\tApplicability:     window,|\t\t\t\tApplicability:     nil,"
"date-echo-dropped|$COMPLIANCE_GO|TestChaosReplay_TheResponseAlwaysEchoesTheDateItActuallyCompared|.|\t\t\t\tAssessmentDate:    req.AssessmentDate,|\t\t\t\tAssessmentDate:    \"\","
# The corpus is test data, and it is mutated too: a raw control byte in it is
# invisible to Go and silently degrades every shell-side assertion about the
# file into a "binary file matches" message.
"corpus-raw-control-byte|$CORPUS|TestChaosDate_CorpusIsPlainText|./frameworks|\"0001-12-31\"\t0001-12-31|\"0001-12-31\"\t0001-12-31\n\"2027-12-11\u0000\"\treject"
# --- INVERTED ROWS: the mutation is the FIX, and the characterisation test
# --- must go red when it is applied. See the header.
"FIX-reject-dateless-window|$APP_GO|TestChaosResolve_DatelessChildWindowVoidsTheParent_REPORTED_DEFECT|.|\tif a.Basis == BasisTranspositionDeadline|\tif !hasDate && strings.TrimSpace(a.Jurisdiction) == \"\" {\n\t\treturn fmt.Errorf(\"%s applicability declares neither date nor jurisdiction: a window with no dates is indistinguishable from no window and silently voids the one above it\", where)\n\t}\n\tif a.Basis == BasisTranspositionDeadline"
"FIX-require-jurisdiction-for-directives|$APP_GO|TestChaosResolve_TranspositionWindowWithNoJurisdictionLoadsAndGates_REPORTED_DEFECT|.|\tif a.Basis == BasisTranspositionDeadline && strings.TrimSpace(a.Note) == \"\" {|\tif a.Basis == BasisTranspositionDeadline && strings.TrimSpace(a.Jurisdiction) == \"\" {\n\t\treturn fmt.Errorf(\"%s applicability basis is %s with no jurisdiction: a directive has no single in-force date\", where, BasisTranspositionDeadline)\n\t}\n\tif a.Basis == BasisTranspositionDeadline && strings.TrimSpace(a.Note) == \"\" {"
)

if [ "${1:-}" = "--list" ]; then
  for m in "${MUTATIONS[@]}"; do printf '%s\n' "${m%%|*}"; done
  exit 0
fi

BACKUP="$(mktemp -d)"
cleanup() {
  # Explicit copies back, in every exit path including a signal.
  for f in "${FILES[@]}"; do
    [ -f "$BACKUP/$(basename "$f")" ] && cp "$BACKUP/$(basename "$f")" "$f"
  done
  rm -rf "$BACKUP"
}
trap cleanup EXIT INT TERM
for f in "${FILES[@]}"; do cp "$f" "$BACKUP/$(basename "$f")"; done

# apply FILE FIND REPLACE — exactly-once replacement, refusing ambiguity.
apply() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, find, repl = sys.argv[1], sys.argv[2].encode().decode('unicode_escape'), sys.argv[3].encode().decode('unicode_escape')
src = open(path).read()
n = src.count(find)
if n != 1:
    sys.stderr.write("pattern occurs %d times, want exactly 1: %r\n" % (n, find))
    sys.exit(3)
open(path, 'w').write(src.replace(find, repl))
PY
}

TOTAL=0
PROVEN=0
VOID=()

printf '════ applicability chaos: mutation proof ════\n'

# CONTROL. A harness whose tests are red before any mutation proves nothing at
# all, so the pristine tree is asserted green first.
if ! (cd "$ENGINE" && go test . ./frameworks -run 'TestChaos' -count=1 >/dev/null 2>&1); then
  printf 'CONTROL FAILED: the pristine tree is already red, so no mutation below means anything.\n' >&2
  cd "$ENGINE" && go test . ./frameworks -run 'TestChaos' -count=1 2>&1 | tail -30 >&2
  exit 1
fi
printf 'CONTROL: pristine tree green across both chaos suites\n'

for row in "${MUTATIONS[@]}"; do
  IFS='|' read -r name file test pkg find repl <<<"$row"
  TOTAL=$((TOTAL + 1))
  cleanup_one() { cp "$BACKUP/$(basename "$file")" "$file"; }

  if ! apply "$file" "$find" "$repl" 2>/tmp/chaos-mutate-err; then
    printf 'MUTATION VOID [%s]: could not apply — %s\n' "$name" "$(cat /tmp/chaos-mutate-err)"
    VOID+=("$name (unapplied)")
    cleanup_one
    continue
  fi

  # THE BUILD GATE, and it is not optional. `go test` exits non-zero for a
  # COMPILE failure exactly as it does for a failed assertion, so without this
  # a mutation that merely broke the build would be scored as proof that an
  # assertion depends on the guard. It is not proof of anything: nothing ran.
  # A mutation must produce a tree that still compiles, and only then is a red
  # test evidence.
  if ! build="$(cd "$ENGINE" && go build ./... && go vet "$pkg" 2>&1)"; then
    printf 'MUTATION VOID   [%-38s] BUILD BROKEN — nothing ran, so a red test would prove nothing\n' "$name"
    printf '%s\n' "$build" | tail -5
    VOID+=("$name (build broken)")
    cleanup_one
    continue
  fi

  out="$(cd "$ENGINE" && go test "$pkg" -run "^${test}\$" -count=1 2>&1)" && ec=0 || ec=$?
  # A mutation whose test went red because the test BINARY failed to build is
  # the same non-evidence one hop later (a mutated signature breaking a test
  # file compiles fine under `go build`, which ignores _test.go).
  if grep -q 'build failed\|cannot use\|undefined:\|too many arguments' <<<"$out"; then
    printf 'MUTATION VOID   [%-38s] TEST BINARY FAILED TO BUILD — not evidence\n' "$name"
    printf '%s\n' "$out" | tail -5
    VOID+=("$name (test build broken)")
    cleanup_one
    continue
  fi
  cleanup_one

  if [ "$ec" -ne 0 ]; then
    PROVEN=$((PROVEN + 1))
    printf 'MUTATION PROVEN [%-38s] %s went red\n' "$name" "$test"
  else
    printf 'MUTATION VOID   [%-38s] %s STAYED GREEN — the test does not depend on the guard it names\n' "$name" "$test"
    printf '%s\n' "$out" | tail -5
    VOID+=("$name")
  fi
done

printf '════ %d/%d mutations proven ════\n' "$PROVEN" "$TOTAL"
if [ "${#VOID[@]}" -gt 0 ]; then
  printf 'VOID: %s\n' "${VOID[*]}" >&2
  exit 1
fi

# The tree must be byte-identical to how it was found. A mutation harness that
# leaves a mutation behind is the worst possible outcome: it ships a defect
# under a green bar.
for f in "${FILES[@]}"; do
  if ! cmp -s "$f" "$BACKUP/$(basename "$f")"; then
    printf 'RESTORE FAILED: %s differs from the copy taken before mutation\n' "$f" >&2
    exit 1
  fi
done
printf 'RESTORE: all %d mutated files byte-identical to the pre-mutation copies\n' "${#FILES[@]}"
