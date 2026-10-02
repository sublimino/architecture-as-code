#!/usr/bin/env bash
# lint-pipefail-grep-q.sh — every early-exit `| grep -q` / `| rg -q` under
# pipefail must be rewritten or carry a stated reason it cannot race.
#
#   lint-pipefail-grep-q.sh                  # scripts test d2-* Makefile
#   lint-pipefail-grep-q.sh path...          # only these files/directories
#   lint-pipefail-grep-q.sh --list [path...] # every site, MARKED or UNMARKED
#
# Exit codes, stated first because they are the contract:
#
#   0  SCANNED CLEAN   a non-empty file set was read and every site under
#                      pipefail carries a `# pipefail-safe: <reason>` marker.
#   1  FINDINGS        at least one unmarked site.
#   2  CANNOT SCAN     no such path, or the file set was EMPTY. An empty scan is
#                      never a pass.
#
# ─── The defect class ──────────────────────────────────────────────────────
#
# `producer | grep -q PAT` under `set -o pipefail`: grep -q exits at its first
# match, the producer is SIGPIPEd (or gets EPIPE, where SIGPIPE is ignored) if
# it is still writing, and pipefail makes that the pipeline's status. A MATCH
# reads as NO MATCH. It is a scheduling race, so it hides on an idle machine:
# scripts/cluster-clean-teardown.sh lost osramp this way in 65 of 228 runs
# under CPU load, skipped the delete, and still reported PASS.
#
# check-vacuous-assertions.sh VAC008 already flags the subset whose status is a
# verdict (an abort or refusal). That teardown was outside it: its branch chose
# "delete" or "skip", neither of which refuses, which VAC008 documents as a
# wrong branch that self-corrects. Skipping a destructive action and then
# certifying the result does not self-correct, so this guard covers EVERY site.
#
# ─── What counts as "under pipefail" ───────────────────────────────────────
#
#   * a shell file, from the first unquoted `set -o pipefail` / `set -…o
#     pipefail` line onward;
#   * a Makefile whose SHELL or .SHELLFLAGS carries pipefail (every recipe);
#   * a line that itself enables pipefail (`bash -c 'set -o pipefail; … | grep
#     -q …'`), which is the one case a quoted pipeline is code, not data;
#   * a file SOURCED by a file that enables pipefail at top level, from line 1:
#     sourcing inherits the shell options (matched by basename, conservatively).
#
# Quoted spans and heredoc bodies are blanked first: a pipeline quoted as data
# (a remote command string, a mutation's substitution text, a fixture script
# written by a heredoc) is not a pipeline of this file. Same reasoning, and the
# same blanking, as VAC008.
#
# ─── The fix, and the marker ───────────────────────────────────────────────
#
#   grep -q PAT <<<"$(producer)"      # read in full, then match: no race
#
# A site that genuinely cannot race (the producer is a builtin writing one
# short, bounded value in a single write) may instead carry, on the same line
# or the line above:
#
#   # pipefail-safe: <why the producer cannot write after the match>
#
# An empty reason is not a marker. This script never edits what it scans.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

list=0
if [ "${1:-}" = "--list" ]; then list=1; shift; fi
if [ "$#" -eq 0 ]; then
	set -- scripts test d2-* Makefile
fi

files="$(mktemp)"
trap 'rm -f "$files"' EXIT
for p in "$@"; do
	if [ ! -e "$p" ]; then
		echo "lint-pipefail-grep-q: CANNOT SCAN: no such path: $p" >&2
		exit 2
	fi
	find "$p" \( -name node_modules -o -name .git -o -name vendor \) -prune -o -type f -print
done | grep -E '(\.sh|\.bash|\.bats|\.mk|/Makefile|^Makefile)$' | sort -u >"$files" || true
if [ ! -s "$files" ]; then
	echo "lint-pipefail-grep-q: CANNOT SCAN: the file set is EMPTY for: $*" >&2
	exit 2
fi

# Basenames of files that top-level-pipefail files source. Sourcing inherits
# the caller's options, so those files run under pipefail from their line 1.
sourced="$(
	while IFS= read -r f; do
		grep -Eq '^[[:space:]]*set[[:space:]]+-[A-Za-z]*o[[:space:]]+pipefail' "$f" || continue
		# Every *.sh / *.bash name on a source line: the path is usually built
		# from "$(dirname ...)" or a variable, so only its last component is
		# reliable.
		grep -E '^[[:space:]]*(source|\.)[[:space:]]' "$f" | grep -Eo '[A-Za-z0-9_.-]+\.(sh|bash)' || true
	done <"$files" | sort -u
)"

scan() {
	awk -v FNAME="$1" -v INHERITED="$2" -v LIST="$list" '
		function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
		# The quoting context is a STACK that persists ACROSS lines: a multi-line
		# "..." handed to `bash -c` or ssh is data, and its continuation lines
		# blank too; a $( ) inside "..." is code again, with its own quotes, so a
		# double quote passed to tr inside such a $( ) does not leave a phantom
		# string open (scenario.sh:261 did, before this). Characters
		# whose innermost context is a quote are blanked; code is kept. An
		# unquoted `#` after whitespace starts a comment, so an apostrophe in
		# prose cannot open a string.
		function top() { return substr(S, length(S), 1) }
		function push(c) { S = S c }
		function pop() { S = substr(S, 1, length(S) - 1) }
		function unquote(s,   out, i, c, n, k) {
			out = ""; n = length(s)
			for (i = 1; i <= n; i++) {
				c = substr(s, i, 1); k = top()
				if (k == "'"'"'") { if (c == "'"'"'") pop(); out = out " "; continue }
				if (k == "\"") {
					if (c == "\\") { out = out "  "; i++; continue }
					if (c == "\"") { pop(); out = out " "; continue }
					if (c == "$" && substr(s, i + 1, 1) == "(") { push("("); out = out "$("; i++; continue }
					out = out " "; continue
				}
				# code: top level or inside $( )
				if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;]/)) break
				if (c == "\\" && i == n) { out = out "\\"; continue }
				if (c == "\\") { out = out "  "; i++; continue }
				if (c == "'"'"'" || c == "\"") { push(c); out = out " "; continue }
				if (c == "$" && substr(s, i + 1, 1) == "(") { push("("); out = out "$("; i++; continue }
				if (c == "(" && k == "(") { push("("); out = out c; continue }
				if (c == ")" && k == "(") { pop(); out = out c; continue }
				out = out c
			}
			return out
		}
		function marked(i,   m) {
			m = "#[ \t]*pipefail-safe:[ \t]*[^ \t]"
			if (L[i] ~ m) return 1
			return (i > 1 && trim(L[i - 1]) ~ ("^" m))
		}
		{ L[NR] = $0 }
		END {
			hd = ""
			for (i = 1; i <= NR; i++) {
				t = trim(L[i])
				if (hd != "") { HD[i] = 1; if (t == hd) hd = ""; continue }
				if (match(t, /<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/)) {
					h = substr(t, RSTART, RLENGTH); sub(/<<-?[ \t]*/, "", h); gsub(/["'"'"']/, "", h)
					hd = h
				}
			}
			pf = INHERITED
			mk = (FNAME ~ /(Makefile|\.mk)$/)
			if (mk) for (i = 1; i <= NR; i++) {
				t = trim(L[i]); if (t ~ /^#/) continue
				if (t ~ /^(SHELL|\.SHELLFLAGS)[ \t]*[:+?]?=/ && t ~ /pipefail/) pf = 1
			}
			reader = "(^|[^|])\\|[ \t]*(command[ \t]+)?(grep|egrep|fgrep|rg)[ \t]+([^|;&]*[ \t])?(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)([ \t]|$)"
			for (i = 1; i <= NR; i++) {
				if (HD[i]) continue
				t = trim(L[i])
				in_string = (S ~ /["'"'"']/)
				u = unquote(L[i])
				if (!in_string && t ~ /^#/) continue
				if (!mk && u ~ /(^|[ \t;&|({])set[ \t]+-[A-Za-z]*o[ \t]+pipefail/) pf = 1
				# A `-c` command string that enables pipefail and then pipes
				# into grep -q, all inside the one quoted string.
				line_pf = (L[i] ~ /-c[ \t]+["'"'"'][^"'"'"']*(set[ \t]+-[A-Za-z]*o[ \t]+pipefail|-o[ \t]+pipefail)[^"'"'"']*\|[ \t]*(grep|egrep|fgrep|rg)[ \t]/)
				hit = 0
				if (pf && u ~ reader) hit = 1
				else if (line_pf && L[i] ~ reader) hit = 1
				if (!hit) continue
				st = marked(i) ? "MARKED" : "UNMARKED"
				if (LIST || st == "UNMARKED") printf "%s\t%s\t%d\t%s\n", st, FNAME, i, t
			}
		}
	' "$1"
}

out="$(
	while IFS= read -r f; do
		inherited=0
		if ! grep -Eq '^[[:space:]]*set[[:space:]]+-[A-Za-z]*o[[:space:]]+pipefail' "$f" &&
			grep -qxF -- "$(basename "$f")" <<<"$sourced"; then
			inherited=1
		fi
		scan "$f" "$inherited"
	done <"$files"
)"

n_files="$(wc -l <"$files" | tr -d ' ')"
if [ "$list" = 1 ]; then
	[ -z "$out" ] || printf '%s\n' "$out"
	exit 0
fi
if [ -z "$out" ]; then
	echo "lint-pipefail-grep-q: SCANNED CLEAN: ${n_files} files, no unmarked early-exit grep under pipefail"
	exit 0
fi
printf '%s\n' "$out" | awk -F'\t' '{ printf "%s:%s: %s\n", $2, $3, $4 }'
echo "lint-pipefail-grep-q: $(printf '%s\n' "$out" | wc -l | tr -d ' ') unmarked site(s) in ${n_files} files: rewrite as grep -q PAT <<<\"\$(producer)\", or mark '# pipefail-safe: <reason>'" >&2
exit 1
