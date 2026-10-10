#!/bin/sh
# Anchor every control reference in the nist-800-53 pack to the published NIST
# OSCAL catalogue.
#
# WHY THIS EXISTS
#
# Before this test the pack's control identifiers had never been checked against
# NIST. Nothing stopped a plausible-looking identifier from being invented, and
# a fabricated control ID is the defect a customer repeats to an auditor. CIS
# §5 recommendations are prose and cannot be machine-anchored; SP 800-53 is
# published as OSCAL JSON, so for this pack the anchor is mechanical and there
# is no excuse for drift.
#
# WHAT IT ENFORCES (per version directory, for every control)
#
#   1. EXISTENCE  — every NIST identifier the pack references resolves in the
#                   catalogue extract. Catches a fabricated control, and
#                   catches an enhancement number that does not exist
#                   (AC-6(1) is real, AC-6(47) is not).
#   2. TITLE      — where the pack states a title alongside an identifier
#                   (v2.1 names controls "<ID> <Title>"), the title matches
#                   the catalogue exactly. Catches silent drift, e.g. calling
#                   IA-2 "Identification and Authentication" when the
#                   catalogue says "Identification and Authentication
#                   (Organizational Users)" — a different control scope.
#   3. FAMILY     — the identifier's family matches the control set it is filed
#                   under, so an SC control cannot be filed under AC.
#
# What it deliberately does NOT enforce: whether the mapping is semantically
# defensible. That is a judgement, recorded in FINDINGS.md, not a test.
#
# Usage: ./anchor-test.sh     (exit 0 = pass, 1 = failures, 2 = harness problem)
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PACK=$(dirname "$HERE")
TSV="$HERE/nist-sp-800-53-rev5-ids.tsv"

command -v jq >/dev/null 2>&1 || { echo "anchor-test: jq is required" >&2; exit 2; }
[ -r "$TSV" ] || { echo "anchor-test: missing catalogue extract $TSV (run ./extract.sh)" >&2; exit 2; }

VERSIONS=$(find "$PACK" -mindepth 2 -maxdepth 2 -name framework.json -exec dirname {} \; | LC_ALL=C sort)
[ -n "$VERSIONS" ] || { echo "anchor-test: no version directories with framework.json under $PACK" >&2; exit 2; }

RECORDS=$(mktemp "${TMPDIR:-/tmp}/anchor-rec.XXXXXX")
trap 'rm -f "$RECORDS"' EXIT INT TERM

for VDIR in $VERSIONS; do
	VER=$(basename "$VDIR")
	# One record per control: version, control-set id, control id, control
	# name, control description. Tabs separate; the schema forbids tabs in
	# these fields and jq would emit them escaped anyway.
	jq -r --arg ver "$VER" '
		.controlSets[] as $cs
		| $cs.controls[]
		| [$ver, $cs.id, .id, (.name // ""), (.description // "")]
		| @tsv
	' "$VDIR/framework.json" >>"$RECORDS"
done

awk -F'\t' -v tsv="$TSV" '
function fail(msg) { problems[++np] = msg }

BEGIN {
	# Load the catalogue extract: title by uppercase dotted ID, and the set
	# of legitimate control families. Deriving families from the catalogue
	# (rather than hardcoding a list) means a future NIST family is picked
	# up by regenerating the extract, and keeps token extraction from
	# mistaking a string like "AES-256" for a control reference.
	while ((getline line < tsv) > 0) {
		if (line ~ /^#/ || line == "") continue
		split(line, f, "\t")
		title[f[1]] = f[2]
		split(f[1], p, "-")
		family[p[1]] = 1
	}
	close(tsv)
	if (length(title) == 0) { print "anchor-test: catalogue extract is empty" > "/dev/stderr"; exit 2 }
}

# Normalise the parenthesised enhancement form the pack writes (AC-6(1)) to
# the dotted form OSCAL keys on (AC-6.1).
function normalise(tok,   out) {
	out = tok
	gsub(/\(/, ".", out)
	gsub(/\)/, "", out)
	return out
}

# Pull every control reference out of a string. A candidate is two letters, a
# hyphen, digits, optionally a parenthesised enhancement number; it must not be
# preceded by a letter (so "AES-256" yields nothing), and its family must be a
# real NIST family.
function refs(s, found,   rest, tok, pre, fam, n) {
	n = 0
	rest = s
	while (match(rest, /[A-Z][A-Z]-[0-9]+(\([0-9]+\))?/)) {
		tok = substr(rest, RSTART, RLENGTH)
		pre = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : " "
		rest = substr(rest, RSTART + RLENGTH)
		if (pre ~ /[A-Za-z]/) continue
		split(tok, q, "-")
		fam = q[1]
		if (!(fam in family)) continue
		found[++n] = tok
	}
	return n
}

{
	ver = $1; set = $2; cid = $3; cname = $4; cdesc = $5
	where = ver "/" set "/" cid

	# The family this control set declares, from its id prefix
	# ("ac-access-control" -> "AC").
	split(set, sp, "-")
	setfam = toupper(sp[1])

	# Rule 1 + 3: every reference in the control id and description.
	delete found
	n = refs(cid " " cdesc, found)
	if (n == 0) fail(where ": no NIST control reference found in control id or description")
	for (i = 1; i <= n; i++) {
		tok = found[i]
		key = normalise(tok)
		if (!(key in title))
			fail(where ": references " tok " (" key ") which is NOT IN THE CATALOGUE -- fabricated or withdrawn")
		split(key, q, "-")
		if (setfam in family && q[1] != setfam)
			fail(where ": references " tok " but is filed under control set " set " (family " setfam ")")
		seen[key] = seen[key] " " where
		total++
	}

	# Rule 2: a title claim is a control name of the form "<ID> <Title>".
	if (match(cname, /^[A-Z][A-Z]-[0-9]+(\([0-9]+\))?[ ]/)) {
		tok = substr(cname, 1, RLENGTH - 1)
		key = normalise(tok)
		claimed = substr(cname, RLENGTH + 1)
		if (!(key in title)) {
			fail(where ": claims a title for " tok " which is NOT IN THE CATALOGUE")
		} else if (claimed != title[key]) {
			fail(where ": title drift for " tok "\n      pack:      " claimed "\n      catalogue: " title[key])
		} else {
			titlesok++
		}
	}
}

END {
	if (np > 0) {
		print "anchor-test: FAIL (" np " problem(s))"
		for (i = 1; i <= np; i++) print "  - " problems[i]
		exit 1
	}
	printf "anchor-test: PASS -- %d control reference(s) resolved against %d catalogue controls, %d title(s) matched exactly\n", total, length(title), titlesok
}
' "$RECORDS"
