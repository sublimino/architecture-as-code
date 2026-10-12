#!/bin/sh

# Usage: ./pricing-counts-test.sh            (exit 0 = blocks match the packs, 1 = drift, 2 = harness problem)
#        ./pricing-counts-test.sh --update   (rewrite every block from the packs, then re-check)
#
# WHY THIS EXISTS
#
# Every pack page states how many of its checks are priced and how many are
# not. An unpriced check contributes exactly GBP 0.00 to every total however
# often it fails, so the ratio is the single most load-bearing number on the
# page: a reader who takes "134 checks" for "134 priced checks" reads a scan
# total as 2.2x the coverage it has. A hand-typed count is wrong the first time
# a check lands and silently wrong thereafter, which is the same failure mode
# that let 73 checks price at zero without anyone noticing.
#
# So the counts are not typed. They live in a generated block between
# <!-- pricing-counts:begin --> and <!-- pricing-counts:end --> markers, this
# script rewrites them from framework.json, and a plain run fails if what is on
# the page differs from what the packs say by one character.
#
# A check is PRICED if any of freqTriple.{min,mode,max} exceeds zero. An absent
# freqTriple decodes to the zero value, so absent and all-zero are one state --
# the same rule as nist-800-53/catalogue/pricing-test.sh, which this follows.
# That sibling test asks whether an unpriced check is DECLARED. This one asks
# whether the documentation tells the truth about how many there are. Both are
# needed: a declaration file keeps the silence deliberate, a counts block keeps
# the page honest.
#
# This script does NOT invent frequency triples and must never be "fixed" by
# doing so. Calibration is the principal's call. See the calibration statement
# in policy/frameworks/README.md.
#
# WHAT IT ENFORCES
#
#   1. DRIFT        — a block whose numbers no longer match framework.json.
#   2. MISSING      — a pack page with no counts block at all.
#   3. UNPLACED     — a pack with version directories but no page to write to.
#
# Plain sh + jq + awk, so it runs wherever the repository is checked out, with
# no Go toolchain. Wired in as `make policy-pricing-counts`.

set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODE=check

case "${1:-}" in
	"") ;;
	--update) MODE=update ;;
	-h|--help) sed -n '3,4p' "$0"; exit 0 ;;
	*) echo "pricing-counts: unknown argument: $1" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "pricing-counts: jq is required" >&2; exit 2; }

BEGIN_MARK='<!-- pricing-counts:begin -->'
END_MARK='<!-- pricing-counts:end -->'

TMP=$(mktemp "${TMPDIR:-/tmp}/pricing-counts.XXXXXX")
BLOCK=$(mktemp "${TMPDIR:-/tmp}/pricing-block.XXXXXX")
TOTALS=$(mktemp "${TMPDIR:-/tmp}/pricing-totals.XXXXXX")
trap 'rm -f "$TMP" "$BLOCK" "$TOTALS"' EXIT INT TERM

RC=0
: >"$TOTALS"

# counts_for VDIR -- one tab-separated row:
# pack id, version, checks, priced, unpriced, placeholder.
counts_for() {
	jq -r '
		[ .controlSets[].controls[].checks[] ] as $c
		| [ .id,
		    .version,
		    ($c | length),
		    ($c | map(select((.freqTriple.min // 0) > 0 or (.freqTriple.mode // 0) > 0 or (.freqTriple.max // 0) > 0)) | length),
		    ($c | map(select(((.freqTriple.min // 0) > 0 or (.freqTriple.mode // 0) > 0 or (.freqTriple.max // 0) > 0) | not)) | length),
		    ($c | map(select(.status == "placeholder")) | length)
		  ] | @tsv
	' "$1/framework.json"
}

# render_block ROWS_FILE TOTAL_LABEL NAME_MODE -- write the block body to $BLOCK.
# It must redirect into $BLOCK and never to stdout. An early revision printed to
# stdout, so $BLOCK stayed empty, splice() wrote nothing, and the comparison then
# matched empty against empty and reported PASS with every block unwritten.
# NAME_MODE is "version" for a pack page or "pack" for the estate page.
render_block() {
	awk -F'\t' -v label="$2" -v mode="$3" '
	BEGIN {
		print "| " (mode == "pack" ? "Pack and version" : "Version") \
		      " | Checks | Priced | Unpriced | Placeholder |"
		print "| :--- | ---: | ---: | ---: | ---: |"
	}
	{
		name = (mode == "pack" ? $1 "@" $2 : $2)
		printf "| `%s` | %d | %d | %d | %d |\n", name, $3, $4, $5, $6
		t3 += $3; t4 += $4; t5 += $5; t6 += $6
	}
	END {
		printf "| **%s** | **%d** | **%d** | **%d** | **%d** |\n", label, t3, t4, t5, t6
		printf "\nAn unpriced check contributes GBP 0.00 to every total however often it\n"
		printf "fails. Of %d check(s) on this page, %d are priced and %d are not.\n", t3, t4, t5
		printf "Written by `policy/frameworks/pricing-counts-test.sh`. Do not edit by hand.\n"
	}
	' "$1"
}

# splice FILE -- replace the marked region of FILE with $BLOCK.
splice() {
	awk -v blockfile="$BLOCK" -v b="$BEGIN_MARK" -v e="$END_MARK" '
	$0 == b { print; inblock = 1; while ((getline l < blockfile) > 0) print l; close(blockfile); next }
	$0 == e { inblock = 0; print; next }
	!inblock { print }
	' "$1" >"$TMP"
	cat "$TMP" >"$1"
}

for PACK in "$HERE"/*/; do
	PACK=${PACK%/}
	[ -d "$PACK" ] || continue
	VERSIONS=$(find "$PACK" -mindepth 2 -maxdepth 2 -name framework.json -exec dirname {} \; | LC_ALL=C sort)
	[ -n "$VERSIONS" ] || continue

	ROWS=$(mktemp "${TMPDIR:-/tmp}/pricing-rows.XXXXXX")
	for VDIR in $VERSIONS; do counts_for "$VDIR" >>"$ROWS"; done
	cat "$ROWS" >>"$TOTALS"

	# The page is the pack README when there is one, else the only version's README.
	PAGE="$PACK/README.md"
	if [ ! -f "$PAGE" ]; then
		PAGE=""
		for VDIR in $VERSIONS; do
			[ -f "$VDIR/README.md" ] && PAGE="$VDIR/README.md"
		done
	fi
	if [ -z "$PAGE" ]; then
		echo "pricing-counts: FAIL ${PACK#"$HERE"/}: pack has version directories but no README.md to carry its counts block (UNPLACED)" >&2
		RC=1
		rm -f "$ROWS"
		continue
	fi
	if ! grep -qF "$BEGIN_MARK" "$PAGE" || ! grep -qF "$END_MARK" "$PAGE"; then
		echo "pricing-counts: FAIL ${PAGE#"$HERE"/}: no pricing-counts block (MISSING). Add the two markers, then run --update." >&2
		RC=1
		rm -f "$ROWS"
		continue
	fi

	render_block "$ROWS" "Pack total" version >"$BLOCK"
	rm -f "$ROWS"
	[ -s "$BLOCK" ] || { echo "pricing-counts: rendered an empty block for ${PACK#"$HERE"/}" >&2; exit 2; }
	[ "$MODE" = update ] && splice "$PAGE"

	# Compare what is between the markers with what was just rendered.
	ONPAGE=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0==b{f=1;next} $0==e{f=0} f' "$PAGE")
	if [ "$ONPAGE" != "$(cat "$BLOCK")" ]; then
		echo "pricing-counts: FAIL ${PAGE#"$HERE"/}: counts block does not match framework.json (DRIFT). Run: $0 --update" >&2
		RC=1
	fi
done

# The estate block on the index page.
PAGE="$HERE/README.md"
render_block "$TOTALS" "Estate total" pack >"$BLOCK"
[ -s "$BLOCK" ] || { echo "pricing-counts: rendered an empty estate block" >&2; exit 2; }
[ "$MODE" = update ] && splice "$PAGE"
ONPAGE=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0==b{f=1;next} $0==e{f=0} f' "$PAGE")
if [ "$ONPAGE" != "$(cat "$BLOCK")" ]; then
	echo "pricing-counts: FAIL README.md: estate counts block does not match the packs (DRIFT). Run: $0 --update" >&2
	RC=1
fi

if [ "$RC" -eq 0 ]; then
	awk -F'\t' '{t3+=$3; t4+=$4; t5+=$5} END { printf "pricing-counts: PASS -- %d check(s) across the estate: %d priced, %d unpriced. Every block matches its framework.json.\n", t3, t4, t5 }' "$TOTALS"
else
	echo "pricing-counts: FAILED" >&2
fi
exit "$RC"
