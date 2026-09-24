#!/usr/bin/env bash
# docs-rewrite-guard.sh — check that a style rewrite of a Markdown file kept
# every fact-bearing token. Offline. Needs only bash, awk, git, and diff.
#
# Usage:
#   scripts/docs-rewrite-guard.sh [-r REV] FILE...   # compare FILE with REV:FILE (default HEAD)
#
# A rewrite that splits sentences, removes semicolons, or replaces a banned
# word must not change what the page says. A word count cannot see a number
# that moved to another clause, or a heading that changed its anchor. This
# script compares the multiset of fact-bearing tokens before and after:
#
#   fence     every line inside a fenced code block, byte for byte
#   code      every inline code span
#   link      every link target
#   url       every bare URL
#   number    every number in prose
#   heading   every heading (a changed heading changes its anchor)
#
# Exit status: 0 when every file kept its tokens, 1 when a token changed,
# 2 on usage error. Each changed token is printed as "< old" or "> new".
#
# The guard proves that tokens survived. It cannot see a clause that lost its
# condition or a pronoun that now points at a different noun. Read the split
# sentences.

set -o errexit -o pipefail

REV=HEAD
if [[ "${1:-}" == -r ]]; then
  REV="${2:?usage: docs-rewrite-guard.sh [-r REV] FILE...}"
  shift 2
fi
[[ $# -gt 0 ]] || { echo "usage: docs-rewrite-guard.sh [-r REV] FILE..." >&2; exit 2; }

cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)"

# tokens — read Markdown on stdin, print "kind<TAB>value" lines, sorted.
tokens() {
  LC_ALL=C awk -v OFS='\t' '
    /^[ \t]*(```|~~~)/ { fence = !fence; print "fence", $0; next }
    fence { print "fence", $0; next }
    /^#{1,6} / { s = $0; sub(/^#+ +/, "", s); print "heading", s }
    {
      t = $0
      while (match(t, /`[^`]+`/)) { print "code", substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH) }
      t = $0
      while (match(t, /\]\([^)]*\)/)) { print "link", substr(t, RSTART + 2, RLENGTH - 3); t = substr(t, RSTART + RLENGTH) }
      t = $0
      gsub(/`[^`]*`/, "", t)
      gsub(/\]\([^)]*\)/, "]()", t)
      while (match(t, /https?:\/\/[^ )>\]]+/)) { print "url", substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH) }
      # Each loop above consumes t up to its last match, so start again from
      # the whole line before the number pass.
      t = $0
      gsub(/`[^`]*`/, "", t)
      gsub(/\]\([^)]*\)/, "]()", t)
      gsub(/https?:\/\/[^ )>\]]+/, "", t)
      while (match(t, /[0-9][0-9.,:%x-]*[0-9%]|[0-9]/)) { print "number", substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH) }
    }
  ' | sort
}

fail=0
for f in "$@"; do
  [[ -f "$f" ]] || { echo "docs-rewrite-guard: no such file: $f" >&2; exit 2; }
  before="$(git show "$REV:$f" | tokens)"
  after="$(tokens <"$f")"
  changed="$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -E '^[<>]' || true)"
  if [[ -n "$changed" ]]; then
    echo "$f: fact-bearing tokens changed since $REV"
    printf '%s\n' "$changed"
    fail=1
  else
    echo "$f: tokens kept"
  fi
done
exit $fail
