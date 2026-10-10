#!/bin/sh
# Regenerate the division extracts for the three EU acts anchored by this
# catalogue: CRA, DORA and NIS2.
#
# WHY A LOCAL EXTRACT
#
# These three packs cite primary EU legislation. There is no OSCAL-style
# machine catalogue for an EU act, so the anchor is built from the publisher's
# own authenticated XHTML rendering: one row per numbered division (Article,
# Annex, Annex Part) with the division's heading exactly as published. The
# alternative -- asserting article numbers from memory -- is how the eu-ai-act
# pack ended up with four wrong Official Journal paragraph citations.
#
# WHERE THE TEXT COMES FROM
#
# The Cellar endpoint, NOT eur-lex.europa.eu. EUR-Lex's HTML endpoints answer
# a non-browser client with HTTP 202 and zero bytes, which looks like an empty
# document rather than a refusal. Cellar content-negotiates properly:
#
#   http://publications.europa.eu/resource/celex/<CELEX>
#     Accept:          application/xhtml+xml
#     Accept-Language: eng
#
# BOTH headers are required. Without Accept-Language the service answers 400
# with "Invalid content type CONTENT_STREAM for WORK [...] without language" --
# a 400 that reads like a bad request against the Accept header and is not.
#
# WHAT IS EXTRACTED
#
# The publisher's own semantic classes, not pattern-matching on prose:
#   oj-ti-art     the article number    ("Article 6")
#   oj-sti-art    the article heading   ("ICT risk management framework")
#   oj-doc-ti     annex number and heading, inside an eli-container id="anx_*"
#   oj-ti-grseq-1 an annex Part heading ("Part I Cybersecurity requirements...")
#
# Articles come in strict oj-ti-art / oj-sti-art pairs, so the pairing is
# mechanical. Counts are asserted below: a layout change that breaks the
# pairing fails loudly instead of silently emitting half a catalogue.
#
# Usage: ./extract.sh          (exit 0 = wrote all three, 2 = harness problem)
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

command -v curl >/dev/null 2>&1 || { echo "extract: curl is required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "extract: python3 is required" >&2; exit 2; }

# CELEX id, output basename, expected article count (asserted, so an upstream
# layout change cannot silently shrink the catalogue).
set -- \
	"32024R2847 eu-2024-2847-cra 71" \
	"32022R2554 eu-2022-2554-dora 64" \
	"32022L2555 eu-2022-2555-nis2 46"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/eu-acts.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

for SPEC in "$@"; do
	CELEX=$(echo "$SPEC" | cut -d' ' -f1)
	BASE=$(echo "$SPEC" | cut -d' ' -f2)
	WANT=$(echo "$SPEC" | cut -d' ' -f3)
	SRC="$WORK/$BASE.xhtml"

	echo "extract: fetching $CELEX"
	CODE=$(curl -sSL -o "$SRC" -w '%{http_code}' \
		-H 'Accept: application/xhtml+xml' \
		-H 'Accept-Language: eng' \
		"http://publications.europa.eu/resource/celex/$CELEX") || {
		echo "extract: fetch failed for $CELEX" >&2; exit 2; }
	[ "$CODE" = "200" ] || { echo "extract: $CELEX returned HTTP $CODE" >&2; exit 2; }

	python3 "$HERE/extract.py" "$SRC" "$CELEX" "$WANT" >"$HERE/$BASE.tsv" || exit 2
	echo "extract: wrote $BASE.tsv ($(grep -vc '^#' "$HERE/$BASE.tsv") divisions)"
done

echo "extract: done -- now run ./anchor-test.sh"
