#!/bin/sh
# Make unpriced checks impossible to ship silently.
#
# WHY THIS EXISTS
#
# fair.Simulate(risk, freq, seed) multiplies a loss magnitude by a frequency
# drawn from the check's freqTriple. A check that declares a riskTriple but no
# freqTriple therefore prices at exactly £0.00 however often it fails, and a
# scan of the pack reports zero total exposure with every control failing. All
# 11 checks in v1.0 and all 27 in v2.0 were in that state -- 38 of the 66
# silently-zero checks across the whole estate -- and nothing failed, because a
# field of zeros is indistinguishable from a deliberate decision not to price.
#
# This test removes that ambiguity. A check must either carry a frequency
# triple or be named in unpriced.tsv. One that is neither FAILS.
#
# It deliberately does NOT invent frequency triples. Calibrating how often a
# NIST 800-53 control fails per year is a principal decision; a number made up
# to turn a zero into a non-zero would be worse than the zero, because it would
# look like evidence. The remedy for a long unpriced.tsv is calibration, not
# fabrication.
#
# WHAT IT ENFORCES
#
#   1. UNDECLARED SILENCE — a check with an all-zero frequency triple that is
#      not declared in unpriced.tsv. This is the defect the file exists to stop.
#   2. STALE DECLARATION   — a check declared unpriced that has since acquired a
#      real frequency triple. Forces the declaration to be removed when the
#      check is calibrated, so the list cannot rot into a blanket exemption.
#   3. PHANTOM DECLARATION — a declaration naming a version or check that does
#      not exist, for instance left behind when a check was renamed.
#   4. UNKNOWN REASON CODE — a declaration whose third column is not in the
#      allow-list below. Added 2026-10-11 with penalty-path-not-technical. A
#      free-text reason code is a reason code nobody can count, and the whole
#      point of the file is that the unpriced population is auditable by
#      category rather than by reading every note.
#
# Usage: ./pricing-test.sh    (exit 0 = pass, 1 = failures, 2 = harness problem)
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PACK=$(dirname "$HERE")
DECL="$HERE/unpriced.tsv"

command -v jq >/dev/null 2>&1 || { echo "pricing-test: jq is required" >&2; exit 2; }
[ -r "$DECL" ] || { echo "pricing-test: missing declaration file $DECL" >&2; exit 2; }

VERSIONS=$(find "$PACK" -mindepth 2 -maxdepth 2 -name framework.json -exec dirname {} \; | LC_ALL=C sort)
[ -n "$VERSIONS" ] || { echo "pricing-test: no version directories with framework.json under $PACK" >&2; exit 2; }

CHECKS=$(mktemp "${TMPDIR:-/tmp}/pricing-chk.XXXXXX")
trap 'rm -f "$CHECKS"' EXIT INT TERM

for VDIR in $VERSIONS; do
	VER=$(basename "$VDIR")
	# version, check id, priced?  A triple is "priced" if any of min/mode/max
	# exceeds zero; an absent freqTriple decodes to the zero value, which is
	# exactly the case this test is about, so absent and all-zero are one state.
	jq -r --arg ver "$VER" '
		.controlSets[].controls[].checks[]
		| [ $ver,
		    .id,
		    (if ((.freqTriple.min // 0) > 0 or (.freqTriple.mode // 0) > 0 or (.freqTriple.max // 0) > 0)
		     then "priced" else "zero" end),
		    ((.freqTriple.min // 0)|tostring) + "/" + ((.freqTriple.mode // 0)|tostring) + "/" + ((.freqTriple.max // 0)|tostring)
		  ] | @tsv
	' "$VDIR/framework.json" >>"$CHECKS"
done

awk -F'\t' -v decl="$DECL" '
function fail(msg) { problems[++np] = msg }

BEGIN {
	# The reason-code allow-list. Keep it in step with the REASON CODES block
	# in unpriced.tsv. A new code is a deliberate decision about a new kind of
	# unpriced check, so it is added here and documented there together.
	allowed["no-calibrated-frequency"] = 1
	allowed["placeholder-not-evaluated"] = 1
	allowed["penalty-path-not-technical"] = 1

	while ((getline line < decl) > 0) {
		if (line ~ /^#/ || line == "") continue
		split(line, d, "\t")
		if (d[1] == "" || d[2] == "") continue
		declared[d[1] "\t" d[2]] = 1
		if (!(d[3] in allowed))
			fail(d[1] "/" d[2] ": reason code \"" d[3] "\" is not in the allow-list. Add it to the allow-list in this script and to the REASON CODES block in unpriced.tsv, or use an existing code.")
		ndecl++
	}
	close(decl)
}

{
	ver = $1; id = $2; state = $3; triple = $4
	key = ver "\t" id
	exists[key] = 1
	total++

	if (state == "zero") {
		if (key in declared) { ok_unpriced++ }
		else fail(ver "/" id ": frequency triple is " triple " so this check prices at GBP 0.00 however often it fails, and it is NOT declared in unpriced.tsv. Either calibrate a freqTriple or declare it unpriced.")
	} else {
		priced++
		if (key in declared)
			fail(ver "/" id ": declared unpriced in unpriced.tsv but now carries a real frequency triple " triple ". Remove the declaration.")
	}
}

END {
	for (k in declared)
		if (!(k in exists)) {
			split(k, p, "\t")
			fail(p[1] "/" p[2] ": declared unpriced but no such check exists in that version. Stale declaration.")
		}

	if (np > 0) {
		print "pricing-test: FAIL (" np " problem(s))"
		for (i = 1; i <= np; i++) print "  - " problems[i]
		exit 1
	}
	printf "pricing-test: PASS -- %d check(s): %d priced, %d declared unpriced (%d declaration(s) read)\n", total, priced, ok_unpriced, ndecl
}
' "$CHECKS"
