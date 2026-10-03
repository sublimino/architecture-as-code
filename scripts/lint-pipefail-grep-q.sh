#!/usr/bin/env bash
# lint-pipefail-grep-q.sh — every reader that exits early (`| grep -q`, `| rg
# -q`, `| grep -m N`, `| grep -l`, `| head`, a sed `q`, an awk `exit`, `| read`)
# under pipefail must be rewritten or carry a stated reason it cannot race. The
# name predates the extension to readers other than grep -q; it is kept because
# test/pipefail-grep-q-lint.bats and SLDC_OFFLINE_BATS name it.
#
#   lint-pipefail-grep-q.sh                  # scripts test d2-* Makefile
#   lint-pipefail-grep-q.sh path...          # only these files/directories
#   lint-pipefail-grep-q.sh --list [path...] # every site: MARKED, UNMARKED or
#                                            # EXEMPT:<why>, with its reader kind
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
# ─── The data readers (head, grep -m, sed q, awk exit, read) ──────────────
#
# Their OUTPUT is the answer and is right even when the producer is SIGPIPEd;
# only the 141 is wrong. So a data-reader site matters exactly where that status
# is read: under errexit (`x="$(cmd | head -1)"` kills the script at random), by
# an `||` fallback (`$(v | head -1 || echo 0.0.0)` APPENDS the fallback to a
# good value), by an `if`/`&&`, or as a function return value. Sites where
# nothing can read it are exempt in the rule, not by marker, and --list says
# why: `|| true`, inside <( ), inside a $( ) used as an argument, `local x=$()`,
# or an assignment / bare statement with errexit off that nothing tests.
# grep -q and grep -l are never exempt: their status IS the answer.
#
# ─── The fix, and the marker ───────────────────────────────────────────────
#
#   grep -q PAT <<<"$(producer)"      # read in full, then match: no race
#   producer | sed -n 1,Np            # head -N that reads everything, so the
#                                     # producer's own status still counts
#   awk '!f && COND { ...; f = 1 }'   # awk 'COND { ...; exit }' minus the exit
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
		# Code contexts on the stack: "A" a $( ) that is the value of an
		# assignment, "G" a $( ) that is an argument, "<" a <( ) or >( ), "(" a
		# plain paren inside one of those. SNAP[i] is the stack at each code-level
		# `|` on the current line, which is what decides whether a data reader
		# status is even read (see exempt()).
		function sub_tag(out,   t) {
			t = out; sub(/[ \t]+$/, "", t)
			# `$$(` in a Makefile recipe is the shell `$(`.
			return (t ~ /=\$?$/) ? "A" : "G"
		}
		function unquote(s,   out, i, c, n, k) {
			out = ""; n = length(s); delete SNAP
			for (i = 1; i <= n; i++) {
				c = substr(s, i, 1); k = top()
				if (k == "'"'"'") { if (c == "'"'"'") pop(); out = out " "; continue }
				if (k == "\"") {
					if (c == "\\") { out = out "  "; i++; continue }
					if (c == "\"") { pop(); out = out " "; continue }
					if (c == "$" && substr(s, i + 1, 1) == "(") { push(sub_tag(out)); out = out "$("; i++; continue }
					out = out " "; continue
				}
				# code: top level or inside $( ) / <( )
				if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;]/)) break
				if (c == "\\" && i == n) { out = out "\\"; continue }
				if (c == "\\") { out = out "  "; i++; continue }
				if (c == "'"'"'" || c == "\"") { push(c); out = out " "; continue }
				if (c == "$" && substr(s, i + 1, 1) == "(") { push(sub_tag(out)); out = out "$("; i++; continue }
				if ((c == "<" || c == ">") && substr(s, i + 1, 1) == "(") { push("<"); out = out c "("; i++; continue }
				if (c == "(" && k ~ /^[(AG<]$/) { push("("); out = out c; continue }
				if (c == ")" && k ~ /^[(AG<]$/) { pop(); out = out c; continue }
				if (c == "|") SNAP[i] = S
				out = out c
			}
			return out
		}
		# Why a DATA reader (head, grep -m, sed q, awk exit, read: its output
		# is the answer, not its status) needs no rewrite here, or "". head
		# prints the right lines even when the producer is SIGPIPEd; only the
		# 141 is wrong, so the site matters only where that status is read.
		#   discarded   the statement ends `|| true` / `|| :`
		#   procsubst   inside <( ): no one reads its status
		#   argument    inside a $( ) that is an argument: the outer command
		#               status is the one that counts
		#   local       `local/declare/readonly/export x=$(...)`: the builtin
		#               status masks the substitution
		#   unchecked   an assignment, errexit off, nothing tests it on the line
		# grep -q and grep -l are never exempt: their status IS the answer.
		function exempt(kind, u, pos, line_t,   st, k, tail) {
			if (kind == "grep-q" || kind == "grep-l") return ""
			tail = substr(u, pos)
			if (tail ~ /\|\|[ \t]*(true|:)([ \t;)]|$)/) return "discarded"
			st = SNAP[pos]; k = substr(st, length(st), 1)
			if (st ~ /</) return "procsubst"
			# `$(v | head -1 || echo fallback)` READS the 141: the fallback runs
			# and its output is appended to the value. Not exempt.
			tail = substr(tail, 1, index(tail ")", ")") - 1)
			if (tail ~ /(\|\||&&)/) return ""
			if (k == "G") return "argument"
			if (k == "A") {
				if (substr(u, 1, pos) ~ /(^|[;{( \t])(local|declare|readonly|export|typeset)[ \t]+(-[A-Za-z]+[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=[ \t]*\$\(/) return "local"
				if (!EE && line_t !~ /^(if|elif|while|until)[ \t]/ && u !~ /(\|\||&&)/) return "unchecked"
			}
			# A bare statement, errexit off, nothing on the line tests it, and it
			# is not a function last statement (whose status is the return
			# value) nor followed by a read of $? / PIPESTATUS.
			if (st == "" && !EE && line_t !~ /^(if|elif|while|until|\||&&)[ \t]/ && u !~ /(\|\||&&)/ && !LASTCHK) return "unchecked"
			return ""
		}
		# Is the statement on line i the last of a function, or followed by a
		# read of its status?
		function status_read_after(i,   j, t) {
			for (j = i + 1; j <= NR; j++) {
				t = trim(L[j])
				if (t == "" || t ~ /^#/) continue
				return (t ~ /^\}/ || t ~ /(\$\?|PIPESTATUS)/)
			}
			return 1
		}
		# The first early-exit reader piped into on this line, or "". `u` is
		# the line with quoted text blanked (same length as `raw`), so commands
		# and flags are read from `u` while a sed/awk program, which is always
		# quoted, is read from the same span of `raw`.
		#   grep-q  grep/rg -q, --quiet, --silent: exits at the first match
		#   grep-m  grep/rg -m N, --max-count: exits after N matches
		#   grep-l  grep/rg -l, --files-with-matches: exits at the first match
		#   head    exits after its N lines or bytes
		#   sed-q   a sed program with a q/Q command
		#   awk-exit an awk program that calls exit
		#   read    reads one line and ends
		# The `[^|]` keeps the second bar of `||` (a file-reading fallback, no
		# producer) from reading as a pipe.
		function reader_kind(u, raw,   rest, off, seg, name, p, tl, e, n, au, ar, ae) {
			rest = u; off = 0
			while (match(rest, /(^|[^|])\|[ \t]*(command[ \t]+)?(grep|egrep|fgrep|rg|head|sed|awk|gawk|mawk|read)([ \t]|$)/)) {
				seg = substr(rest, RSTART, RLENGTH)
				RPOS = off + RSTART - 1 + index(seg, "|")
				name = seg; sub(/^[^|]*\|[ \t]*(command[ \t]+)?/, "", name); sub(/[ \t]+$/, "", name)
				p = off + RSTART + RLENGTH
				tl = substr(u, p); e = match(tl, /[|;&)]/); n = e ? e - 1 : length(tl)
				au = " " substr(u, p, n) " "; ar = " " substr(raw, p, n) " "
				if (name ~ /^(grep|egrep|fgrep|rg)$/) {
					if (au ~ /[ \t](-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)[ \t]/) return "grep-q"
					if (au ~ /[ \t](-[A-Za-z]*m[0-9]*|--max-count)[ \t=0-9]/) return "grep-m"
					if (au ~ /[ \t](-[A-Za-z]*l[A-Za-z]*|--files-with-matches)[ \t]/) return "grep-l"
				} else if (name == "head") {
					# A negative count (all but the last N) reads everything.
					if (au !~ /[ \t](-n[ \t]*-|--lines=-|-c[ \t]*-|--bytes=-)[0-9]/) return "head"
				} else if (name == "read") {
					return "read"
				} else if (name == "sed") {
					if (ar ~ /[;\/{}0-9'"'"'" \t][qQ][0-9]*[;}'"'"'" \t]/) return "sed-q"
				} else {
					# exit inside END runs after all input is read: not early.
					ae = ar; gsub(/END[ \t]*\{[^}]*\}/, "", ae)
					if (ae ~ /[^A-Za-z_]exit[^A-Za-z_]/) return "awk-exit"
				}
				rest = substr(rest, RSTART + RLENGTH); off += RSTART + RLENGTH - 1
			}
			return ""
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
			# errexit: a bats test fails on any failing command, as if under -e.
			EE = (FNAME ~ /\.bats$/)
			if (mk) for (i = 1; i <= NR; i++) {
				t = trim(L[i]); if (t ~ /^#/) continue
				if (t ~ /^(SHELL|\.SHELLFLAGS)[ \t]*[:+?]?=/ && t ~ /pipefail/) pf = 1
				if (t ~ /^\.SHELLFLAGS[ \t]*[:+?]?=/ && t ~ /-[A-Za-z]*e/) EE = 1
			}
			for (i = 1; i <= NR; i++) {
				if (HD[i]) continue
				t = trim(L[i])
				in_string = (S ~ /["'"'"']/)
				u = unquote(L[i])
				if (!in_string && t ~ /^#/) continue
				if (!mk && u ~ /(^|[ \t;&|({])set[ \t]+-[A-Za-z]*o[ \t]+pipefail/) pf = 1
				if (!mk && (u ~ /(^|[ \t;&|({])set[ \t]+-[A-Za-z]*e[A-Za-z]*([ \t]|$)/ || u ~ /set[ \t]+-o[ \t]+errexit/)) EE = 1
				if (!mk && (u ~ /(^|[ \t;&|({])set[ \t]+\+[A-Za-z]*e/ || u ~ /set[ \t]+\+o[ \t]+errexit/)) EE = 0
				# A `-c` command string that enables pipefail and then pipes
				# into grep -q, all inside the one quoted string.
				line_pf = (L[i] ~ /-c[ \t]+["'"'"'][^"'"'"']*(set[ \t]+-[A-Za-z]*o[ \t]+pipefail|-o[ \t]+pipefail)[^"'"'"']*\|[ \t]*(grep|egrep|fgrep|rg)[ \t]/)
				kind = ""
				if (pf) kind = reader_kind(u, L[i])
				if (kind == "" && line_pf) kind = reader_kind(L[i], L[i])
				if (kind == "") continue
				LASTCHK = (u ~ /\\[ \t]*$/) ? 1 : status_read_after(i)
				ex = exempt(kind, u, RPOS, t)
				if (ex != "") st = "EXEMPT:" ex
				else st = marked(i) ? "MARKED" : "UNMARKED"
				if (LIST || st == "UNMARKED") printf "%s\t%s\t%d\t%s\t%s\n", st, FNAME, i, t, kind
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
	echo "lint-pipefail-grep-q: SCANNED CLEAN: ${n_files} files, no unmarked early-exit reader under pipefail"
	exit 0
fi
printf '%s\n' "$out" | awk -F'\t' '{ printf "%s:%s: %s\n", $2, $3, $4 }'
echo "lint-pipefail-grep-q: $(printf '%s\n' "$out" | wc -l | tr -d ' ') unmarked site(s) in ${n_files} files: rewrite (grep -q PAT <<<\"\$(producer)\"; head -N -> sed -n 1,Np; awk exit -> a first-match flag), or mark '# pipefail-safe: <reason>'" >&2
exit 1
