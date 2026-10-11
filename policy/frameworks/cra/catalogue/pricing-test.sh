#!/bin/sh
# Every check in the cra, dora and nis2 packs must either be priced or be
# explicitly declared unpriced in unpriced.tsv.
#
# WHY THIS EXISTS
#
# fair.Simulate multiplies a loss magnitude by a frequency drawn from
# freqTriple and short-circuits an all-zero frequency to a zero result. So a
# check with a riskTriple and no freqTriple prices at exactly 0.00 and
# contributes nothing to a scan total while still reporting as failed. Across
# the estate that silently zeroed 64 of 127 checks. The defence is not to
# invent frequencies -- a made-up number looks like evidence and is worse than
# a zero -- but to make the zero impossible to ship silently.
#
# WHAT IT ENFORCES
#
#   1. PRICED OR DECLARED -- a check with no frequency triple must have a row
#                            in unpriced.tsv saying so.
#   2. NO STALE DECLARATION -- a declared-unpriced check that has since been
#                            calibrated fails, so the declaration cannot
#                            outlive the gap it documents.
#   3. NO PHANTOM          -- a declaration naming a check that no longer
#                            exists fails, so a renamed check cannot keep an
#                            inherited exemption.
#
# Current state: cra/v1.0's three checks are all priced, so unpriced.tsv holds
# only the two placeholder checks, whose all-zero triples are correct rather
# than missing. Calibrating a triple is a principal decision and is never done
# here.
#
# Usage: ./pricing-test.sh    (exit 0 = pass, 1 = failures, 2 = harness problem)
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FRAMEWORKS=$(dirname "$(dirname "$HERE")")
DECL="$HERE/unpriced.tsv"

command -v jq >/dev/null 2>&1 || { echo "pricing-test: jq is required" >&2; exit 2; }
[ -r "$DECL" ] || { echo "pricing-test: missing $DECL" >&2; exit 2; }

RECORDS=$(mktemp "${TMPDIR:-/tmp}/pricing-rec.XXXXXX")
trap 'rm -f "$RECORDS"' EXIT INT TERM

for PACK in cra dora nis2; do
	VERSIONS=$(find "$FRAMEWORKS/$PACK" -mindepth 2 -maxdepth 2 -name framework.json \
		-exec dirname {} \; | LC_ALL=C sort)
	[ -n "$VERSIONS" ] || { echo "pricing-test: no framework.json under $PACK" >&2; exit 2; }
	for VDIR in $VERSIONS; do
		VER=$(basename "$VDIR")
		# pack/version, check id, 1 if a non-zero frequency triple is present,
		# 1 if the check or its framework is a placeholder.
		jq -r --arg pv "$PACK/$VER" '
			(.status // "") as $fwstatus
			| .controlSets[].controls[].checks[]
			| [ $pv, .id,
			    ( if ((.freqTriple.min // 0) > 0 or (.freqTriple.mode // 0) > 0
			          or (.freqTriple.max // 0) > 0) then "1" else "0" end ),
			    ( if ($fwstatus == "placeholder" or (.status // "") == "placeholder")
			      then "1" else "0" end ) ]
			| @tsv
		' "$VDIR/framework.json" >>"$RECORDS"
	done
done

awk -F'\t' -v decl="$DECL" '
function fail(msg) { problems[++np] = msg }

BEGIN {
	while ((getline line < decl) > 0) {
		if (line ~ /^#/ || line == "") continue
		split(line, f, "\t")
		key = f[1] "\t" f[2]
		declared[key] = 1
		reason[key] = f[3]
		ndecl++
	}
	close(decl)
}

{
	pv = $1; id = $2; priced = ($3 == "1"); placeholder = ($4 == "1")
	key = pv "\t" id
	exists[key] = 1
	all++
	if (!priced) {
		unpriced++
		if (!(key in declared))
			fail(pv " check \"" id "\" has no frequency triple and prices at 0.00, and is NOT declared in unpriced.tsv -- a silent zero")
	} else {
		priced_n++
		if (key in declared)
			fail(pv " check \"" id "\" is declared unpriced but now carries a frequency triple -- stale declaration, remove the row and re-prove the figures")
	}
	if (placeholder) ph++
}

END {
	for (key in declared)
		if (!(key in exists)) {
			split(key, k, "\t")
			fail("unpriced.tsv declares " k[1] " check \"" k[2] "\" which does not exist -- phantom declaration")
		}
	if (np > 0) {
		print "pricing-test: FAIL (" np " problem(s))"
		for (i = 1; i <= np; i++) print "  - " problems[i]
		exit 1
	}
	printf "pricing-test: PASS -- %d check(s): %d priced, %d declared unpriced (%d of them placeholder), 0 silent zeros\n", \
		all, priced_n, unpriced, ph
}
' "$RECORDS"
