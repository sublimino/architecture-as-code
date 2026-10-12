#!/bin/sh
# Anchor every legal citation in the cra, dora and nis2 packs to the publisher's
# own text of the act it cites.
#
# WHY THIS EXISTS
#
# Before this test these three packs carried NO citations at all. That is worse
# than a wrong citation, not better: there was nothing to check, so a control
# could claim whatever an auditor inferred from its name and no gate could
# disagree. The sibling eu-ai-act pack, which did carry citations, was found to
# have four wrong Official Journal paragraph references -- which is the
# measurable version of the same risk.
#
# WHAT IT ENFORCES
#
#   1. EXISTENCE  -- every division a pack cites (Article N, Annex X,
#                    Annex X Part Y) resolves in that act's extract. Catches a
#                    fabricated or renumbered article: DORA has 64 articles, so
#                    "Article 71" is real in the CRA and fiction in DORA.
#   2. ACT        -- each pack is anchored against its OWN act. A CRA citation
#                    cannot be satisfied by a DORA article of the same number,
#                    which is the failure mode a single merged catalogue would
#                    hide (all three acts have an Article 6 and an Article 13).
#   3. TITLE      -- every row of the pack README's "Verified citations" table
#                    states the division's heading, and that heading must match
#                    the extract EXACTLY. This is where drift shows up: calling
#                    NIS2 Article 21 "Cybersecurity Risk Management" rather
#                    than "Cybersecurity risk-management measures" is a
#                    different scope, and it is how the nist-800-53 pack's IA-2
#                    mismapping was found.
#   4. CLOSURE    -- the data and the table agree in both directions. Every
#                    CITES division appears in the README table (no claim the
#                    table does not account for) and every README row is cited
#                    by some control (no stale row describing a citation that
#                    has been removed).
#
# What it deliberately does NOT enforce:
#
#   - Point and sub-point numbers. "Annex I Part II point (1)" anchors as far
#     as "Annex I Part II"; the extract has no row for a point. The points
#     quoted in the README were read from the act by hand and are cited
#     verbatim there so a reviewer can check them against the quoted text.
#   - Whether a mapping is semantically defensible. That is a judgement and
#     lives in each pack's README under "Evidence or proxy", not in a test.
#
# Usage: ./anchor-test.sh     (exit 0 = pass, 1 = failures, 2 = harness problem)
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FRAMEWORKS=$(dirname "$(dirname "$HERE")")

command -v jq >/dev/null 2>&1 || { echo "anchor-test: jq is required" >&2; exit 2; }

# pack:extract. Each pack is anchored only against its own act.
PACKS='cra:eu-2024-2847-cra dora:eu-2022-2554-dora nis2:eu-2022-2555-nis2'

RC=0
TOTAL=0
TITLES=0

for SPEC in $PACKS; do
	PACK=${SPEC%%:*}
	BASE=${SPEC#*:}
	TSV="$HERE/$BASE.tsv"
	README="$FRAMEWORKS/$PACK/README.md"

	[ -r "$TSV" ] || { echo "anchor-test: missing extract $TSV (run ./extract.sh)" >&2; exit 2; }
	[ -r "$README" ] || { echo "anchor-test: missing $README" >&2; exit 2; }

	VERSIONS=$(find "$FRAMEWORKS/$PACK" -mindepth 2 -maxdepth 2 -name framework.json \
		-exec dirname {} \; | LC_ALL=C sort)
	[ -n "$VERSIONS" ] || { echo "anchor-test: no framework.json under $PACK" >&2; exit 2; }

	CITES=$(mktemp "${TMPDIR:-/tmp}/anchor-cites.XXXXXX")
	for VDIR in $VERSIONS; do
		VER=$(basename "$VDIR")
		# One record per description that carries a CITES tail: where, text.
		jq -r --arg ver "$VER" '
			[ { w: "framework", d: (.description // "") } ]
			+ [ .controlSets[] | { w: ("controlSet " + .id), d: (.description // "") } ]
			+ [ .controlSets[].controls[] | { w: ("control " + .id), d: (.description // "") } ]
			+ [ .controlSets[].controls[].checks[] | { w: ("check " + .id), d: (.description // "") } ]
			| .[] | select(.d | test("CITES:"))
			| [$ver + " " + .w, (.d | sub(".*CITES:"; ""))] | @tsv
		' "$VDIR/framework.json" >>"$CITES"
	done

	OUT=$(awk -F'\t' -v tsv="$TSV" -v readme="$README" -v pack="$PACK" '
	function fail(msg) { problems[++np] = msg }

	BEGIN {
		while ((getline line < tsv) > 0) {
			if (line ~ /^#/ || line == "") continue
			split(line, f, "\t")
			title[f[1]] = f[2]
			ndiv++
		}
		close(tsv)
		if (ndiv == 0) { print "anchor-test: " pack ": extract is empty" > "/dev/stderr"; exit 2 }

		# Rule 3: the README table. Rows look like
		#   | <control> | <citation> | <heading> | <verdict> |
		# We key on the citation column and the heading column.
		inTable = 0
		while ((getline line < readme) > 0) {
			if (line ~ /^#+ +Verified citations/) { inTable = 1; continue }
			if (inTable && line ~ /^#/) { inTable = 0; continue }
			if (!inTable || line !~ /^\|/) continue
			if (line ~ /^\|[ -:|]*\|$/) continue          # separator row
			n = split(line, col, "|")
			if (n < 5) continue
			cite = col[3]; head = col[4]
			gsub(/^[ \t]+|[ \t]+$/, "", cite)
			gsub(/^[ \t]+|[ \t]+$/, "", head)
			if (cite == "" || cite == "Citation" || head == "Heading as published") continue
			gsub(/^`|`$/, "", cite)
			div = normalise(cite)
			if (div == "") continue
			rowSeen[div] = 1
			nrows++
			if (!(div in title)) {
				fail(pack ": README table cites " div " which is NOT IN " tsv " -- fabricated or renumbered")
			} else {
				# The heading column may quote the heading; compare unquoted.
				h = head
				gsub(/^[“"'"'"']|[”"'"'"']$/, "", h)
				if (h != title[div])
					fail(pack ": README heading drift for " div "\n      README:  " h "\n      act:     " title[div])
				else
					titlesok++
			}
		}
		close(readme)
		if (nrows == 0) fail(pack ": README.md has no \"Verified citations\" table rows")
	}

	# "Annex I Part II point (1)" -> "Annex I Part II";  "Article 21(2)(d)" -> "Article 21"
	function normalise(c,   out) {
		out = c
		sub(/ +point +\(.*$/, "", out)
		gsub(/\([^)]*\)/, "", out)
		gsub(/^[ \t]+|[ \t]+$/, "", out)
		return out
	}

	{
		where = $1
		# Split the CITES tail on ";" -- each piece is one citation.
		k = split($2, pieces, ";")
		for (i = 1; i <= k; i++) {
			raw = pieces[i]
			gsub(/^[ \t]+|[ \t\.]+$/, "", raw)
			if (raw == "") continue
			div = normalise(raw)
			if (div !~ /^(Article [0-9]+|Annex [IVXLC]+( Part [IVXLC]+)?)$/) {
				fail(pack "/" where ": citation " raw " is not a recognised division form")
				continue
			}
			if (!(div in title)) {
				fail(pack "/" where ": cites " raw " -> " div " which is NOT IN " tsv " -- fabricated or renumbered")
				continue
			}
			cited[div] = cited[div] " " where
			total++
		}
	}

	END {
		# Rule 4, both directions.
		for (d in cited)
			if (!(d in rowSeen))
				fail(pack ": " d " is cited by" cited[d] " but has no row in the README table")
		for (d in rowSeen)
			if (!(d in cited))
				fail(pack ": README table has a row for " d " that no control cites -- stale row")

		if (np > 0) {
			print "FAIL " pack " " np
			for (i = 1; i <= np; i++) print "  - " problems[i]
			exit 0
		}
		printf "PASS %s %d %d %d\n", pack, total, ndiv, titlesok
	}
	' "$CITES")
	rm -f "$CITES"

	case "$OUT" in
	PASS*)
		set -- $OUT
		printf 'anchor-test: %-5s PASS -- %s citation(s) resolved against %s divisions, %s heading(s) matched exactly\n' \
			"$PACK" "$3" "$4" "$5"
		TOTAL=$((TOTAL + $3))
		TITLES=$((TITLES + $5))
		;;
	*)
		echo "anchor-test: $PACK FAIL"
		echo "$OUT" | sed '1d'
		RC=1
		;;
	esac
done

[ "$RC" -eq 0 ] || { echo "anchor-test: FAIL"; exit 1; }
echo "anchor-test: PASS -- $TOTAL citation(s) across 3 acts, $TITLES heading(s) matched exactly, 0 fabricated"
