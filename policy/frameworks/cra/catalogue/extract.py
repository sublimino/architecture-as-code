#!/usr/bin/env python3
"""Extract numbered divisions and their published headings from a Cellar XHTML
rendering of an EU act.

Invoked by extract.sh; not meant to be run directly. Emits TSV on stdout:

    <division id>\t<heading exactly as published>

Division ids are the forms a citation uses: "Article 6", "Annex I",
"Annex I Part II". Headings are the publisher's own, normalised only for
whitespace (the source uses NO-BREAK SPACE inside "Article 6" and
"ANNEX I", which no human writing a citation would type).

The extraction keys on the publisher's semantic CSS classes rather than on
prose patterns, so it does not guess:

    oj-ti-art      article number
    oj-sti-art     article heading
    oj-doc-ti      annex number, then annex heading (inside eli-container anx_*)
    oj-ti-grseq-1  annex Part heading

Exits 2 if the article count does not match the caller's expectation, so an
upstream layout change fails loudly instead of emitting a short catalogue.
"""
import html
import re
import sys


def clean(s: str) -> str:
    """Strip nested markup, unescape entities, normalise all whitespace."""
    s = re.sub(r"(?s)<[^>]+>", "", s)
    s = html.unescape(s)
    # NO-BREAK SPACE (U+00A0) is used inside "Article 6" and "ANNEX I".
    s = s.replace(" ", " ")
    return re.sub(r"\s+", " ", s).strip()


def tagged(src: str):
    """Yield (class, text) for every interesting <p> in document order."""
    for m in re.finditer(
        r'<p[^>]*class="(oj-ti-art|oj-sti-art|oj-doc-ti|oj-ti-grseq-1)"[^>]*>(.*?)</p>',
        src,
        re.S,
    ):
        yield m.group(1), clean(m.group(2))


def main() -> int:
    path, celex, want_articles = sys.argv[1], sys.argv[2], int(sys.argv[3])
    src = open(path, encoding="utf-8", errors="replace").read()

    # Annex containers are marked with eli-container id="anx_<ROMAN>"; record
    # each container's span so an oj-doc-ti can be attributed to its annex.
    annex_at = [
        (m.start(), m.group(1))
        for m in re.finditer(r'<div class="eli-container" id="anx_([IVXLC]+)"', src)
    ]

    def annex_for(offset: int):
        found = None
        for start, roman in annex_at:
            if start <= offset:
                found = roman
            else:
                break
        return found

    rows, articles = [], 0
    pending_article = None
    # Track, per annex, how many oj-doc-ti we have seen: the first is the annex
    # number, the second is its heading.
    doc_ti_seen: dict[str, int] = {}

    for m in re.finditer(
        r'<p[^>]*class="(oj-ti-art|oj-sti-art|oj-doc-ti|oj-ti-grseq-1)"[^>]*>(.*?)</p>',
        src,
        re.S,
    ):
        cls, text = m.group(1), clean(m.group(2))
        if cls == "oj-ti-art":
            pending_article = text
        elif cls == "oj-sti-art":
            if pending_article is None:
                print(
                    f"extract: {celex}: an article heading preceded its number",
                    file=sys.stderr,
                )
                return 2
            rows.append((pending_article, text))
            articles += 1
            pending_article = None
        else:
            roman = annex_for(m.start())
            if roman is None:
                continue  # an oj-doc-ti outside any annex: the act's own title
            if cls == "oj-doc-ti":
                n = doc_ti_seen.get(roman, 0)
                doc_ti_seen[roman] = n + 1
                if n == 1:  # second one is the annex heading
                    rows.append((f"Annex {roman}", text))
            elif cls == "oj-ti-grseq-1":
                part = re.match(r"Part ([IVXLC]+)\s+(.*)$", text)
                if part:
                    rows.append(
                        (f"Annex {roman} Part {part.group(1)}", part.group(2).strip())
                    )

    if pending_article is not None:
        print(f"extract: {celex}: article {pending_article} has no heading", file=sys.stderr)
        return 2
    if articles != want_articles:
        print(
            f"extract: {celex}: found {articles} articles, expected {want_articles} "
            "-- upstream layout changed, re-verify before trusting this extract",
            file=sys.stderr,
        )
        return 2

    print(f"# CELEX {celex} -- divisions and published headings")
    print(f"# source: http://publications.europa.eu/resource/celex/{celex}")
    print("# regenerate with ./extract.sh -- do not hand-edit")
    for div, title in rows:
        if "\t" in div or "\t" in title:
            print(f"extract: {celex}: tab in {div!r}", file=sys.stderr)
            return 2
        print(f"{div}\t{title}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
