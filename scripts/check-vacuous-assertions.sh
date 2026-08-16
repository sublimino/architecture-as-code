#!/usr/bin/env bash
# check-vacuous-assertions.sh — find checks that cannot fail.
#
#   check-vacuous-assertions.sh              # the whole tree
#   check-vacuous-assertions.sh test d2-k8s-afm/test
#
# Exit codes are the point of this script, so they are stated first:
#
#   0  SCANNED CLEAN    a non-empty set of files was read, every rule ran over
#                       it, and nothing matched. A positive result, not an
#                       absence of evidence.
#   1  FINDINGS         at least one assertion in the tree cannot fail, or the
#                       allowlist no longer describes reality.
#   2  CANNOT SCAN      the question was not answered — no such path, no awk,
#                       or the file set was EMPTY.
#
# ─── Why 2 exists, and why it is not 0 ──────────────────────────────────────
#
# A scanner that finds nothing because it read nothing reports the same "0" as a
# scanner that read 74 files and cleared them. That collapse is the exact defect
# this script hunts, so it must not contain it: an empty file set is exit 2,
# loudly worded, and can never be mistaken for a pass by a human skimming output
# or by a Makefile checking $?. Same contract as scripts/check-deployed-staleness.sh,
# which was written after the same shape bit this repo in a different place.
#
# ─── VERIFY AND FAIL, NEVER REPAIR ──────────────────────────────────────────
#
# This script does not write to any file it scans. A guard in this repo has
# already shipped that auto-fixed what it detected: CI went green, the detector
# passed, and the broken component stayed broken because nothing ever went red.
# Reporting and exiting non-zero is the entire contract.
#
# ─── What went wrong, that this exists to catch ─────────────────────────────
#
# Three shipped defects, all of them a check that reads as coverage and cannot
# fail:
#
#   readyExpr: status.observedGeneration >= 0
#       Gated FIVE Flux dependencies. Trivially true the instant the object
#       exists — observedGeneration is a non-negative counter. It was already
#       named as an anti-pattern in d2-osramp-fleet/AGENTS.md and shipped five
#       times anyway, which is the argument for this file existing at all:
#       documentation without an enforcing test is a suggestion.
#
#   kubectl wait --for=condition=ready deployment/openbao
#       A Deployment has no `Ready` condition. It has Available, Progressing and
#       ReplicaFailure. So this times out against a perfectly healthy workload —
#       it blocked a demo against a 1/1 Available=True OpenBao that had been up
#       seventeen hours. `Available` is the correct condition. Note that
#       `kubectl wait` on a POD does have Ready, so the rule keys on the
#       resource kind and not on the string.
#
#   [ "$status" -ne 0 ]   as the sole assertion of an auth-rejection test
#       The container is distroless, so the `kubectl exec … wget` under test
#       always failed with "executable not found". The test passed identically
#       whether the authorisation it claimed to prove existed or not. Four
#       sibling tests failed VISIBLY for that reason and were fixed. This one
#       passed. The passing one was the dangerous one.
#
# ─── The rules ──────────────────────────────────────────────────────────────
#
#   VAC001  a `>= 0` comparison on a monotonic counter inside a readiness
#           expression (readyExpr / CEL). Non-negative by definition.
#   VAC002  `--for=condition=ready` against a kind that has no Ready condition
#           (Deployment, StatefulSet, DaemonSet, ReplicaSet, Job, CronJob).
#   VAC003  a bats @test whose assertions are ALL negative-status checks
#           (`[ "$status" -ne 0 ]`) and which asserts nothing about WHY.
#   VAC004  a tautological assertion: same operand both sides, a literal
#           non-empty string, `-ge 0` on a count, or `|| true` swallowing it.
#   VAC005  a bats @test with no assertion and no failable command at all.
#   VAC006  a bats `run` whose $status and $output are never examined. `run`
#           captures the exit code precisely so it CANNOT fail the test.
#
# ─── What this does NOT check, stated so nobody has to discover it ──────────
#
# Heredoc bodies are skipped by every rule. A heredoc in this tree is almost
# always a fixture or a deliberately-broken probe script — test/ci-lock.bats
# writes a trap probe, test/supercred-image-visibility.bats writes a fake
# kubectl, and test/vacuous-assertions.bats writes violations on purpose in
# order to prove these rules go red. A linter that flags its own fixtures is a
# linter that gets an allowlist entry per fixture and then gets switched off.
#
# The cost is real and is the honest limitation of this file: a tautology inside
# a GENERATED script is not seen. Markdown is skipped for the same reason —
# AGENTS.md and docs/deploying-a-backend-service.md quote these anti-patterns in
# order to warn about them.
#
# More generally: a pass here means these six shapes are absent, and says
# nothing about a seventh way a check can be hollow. The success message says so
# rather than claiming the tree's assertions are sound.
#
# ─── The allowlist ──────────────────────────────────────────────────────────
#
# scripts/vacuous-assertions.allow, one `RULE | path | anchor | reason` per
# line. Three staleness conditions, all of them exit 1:
#
#   * the path does not exist
#   * the anchor text is no longer in that file
#   * the entry suppresses nothing
#
# An anchor is a text snippet rather than a line number on purpose. A line
# number rots on the next edit ANYWHERE above it, which trains people to
# renumber the allowlist without rereading the entry; anchoring on the text
# fails when the line is genuinely gone and survives when it merely moved. An
# unused entry is the sharpest of the three: it reads as "reviewed and accepted"
# while describing nothing, and it silently pre-approves whatever reoccupies
# that name later.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Both injectable so the BATS suite can drive the whole script against a
# fixture tree, per this repo's local-fake convention (see
# test/kind-load-verified.bats, test/supervise-port-forward.bats). Every rule
# here has to be shown going RED, and the only honest way to show that is to
# feed it a violation — which must not mean editing the real tree.
REPO_ROOT="${VACUOUS_REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
ALLOWLIST="${VACUOUS_ALLOWLIST:-${SCRIPT_DIR}/vacuous-assertions.allow}"

log() { printf '\033[1;36m[vacuous]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[vacuous] ✓\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m[vacuous] ✗\033[0m %s\n' "$*" >&2; }
unk() { printf '\033[1;33m[vacuous] ?\033[0m %s\n' "$*" >&2; }

cannot_scan() {
	printf '\n'
	unk "CANNOT SCAN: $*"
	printf '           No claim is being made about this tree. This is NOT a pass.\n\n' >&2
	exit 2
}

command -v awk >/dev/null 2>&1 || cannot_scan "awk is not on PATH."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FINDINGS="${WORK}/findings.tsv" # rule \t file \t line \t anchor \t message \t evidence
: >"$FINDINGS"

# ── File discovery ──────────────────────────────────────────────────────────
#
# Vendored trees are excluded because their assertions are not ours to change:
# d2-osramp-apps/test/test_helper/bats-assert is upstream bats-assert, and its
# own suite deliberately contains degenerate cases as fixtures. Markdown is
# excluded because AGENTS.md and docs/deploying-a-backend-service.md QUOTE these
# anti-patterns in order to warn about them — flagging the warning is the
# false positive that makes a linter get switched off.

collect() {
	local root="$1"
	# `|| true` is safe ONLY because the next assertion (file count > 0) catches
	# an empty result. find exits non-zero when it hits an unreadable directory,
	# even with `-prune`, and under `set -e` that kills the whole script — which
	# the trap cleans up, producing zero-byte output and exit 1.
	# That is indistinguishable from "findings present", and is the same
	# confusion this script's own header warns about.
	find "$root" \
		\( -name .git -o -name node_modules -o -name test_helper -o -name vendor \
		-o -name .venv -o -name dist -o -name .terraform -o -name ci-reports \) -prune -o \
		-type f \( -name '*.bats' -o -name '*.sh' -o -name '*.bash' \
		-o -name '*.yaml' -o -name '*.yml' -o -name 'Makefile' -o -name '*.mk' \) \
		-print 2>/dev/null || true
}

declare -a ROOTS=()
if [ "$#" -eq 0 ]; then
	ROOTS=("$REPO_ROOT")
else
	for arg in "$@"; do
		if [ -d "$arg" ]; then
			ROOTS+=("$(cd "$arg" && pwd)")
		elif [ -f "$arg" ]; then
			ROOTS+=("$arg")
		else
			cannot_scan "no such path: $arg"
		fi
	done
fi

ALL="${WORK}/files.txt"
: >"$ALL"
for root in "${ROOTS[@]}"; do
	if [ -f "$root" ]; then
		printf '%s\n' "$root" >>"$ALL"
	else
		collect "$root" >>"$ALL"
	fi
done
sort -u "$ALL" -o "$ALL"

FILE_COUNT="$(wc -l <"$ALL" | tr -d ' ')"
# The mechanism-presence check. A glob that matched nothing would make every
# rule below pass over an empty universe and report a clean tree — which is
# precisely the bug being hunted, one level up.
if [ "$FILE_COUNT" -eq 0 ]; then
	cannot_scan "the file set is EMPTY — nothing was scanned (roots: ${ROOTS[*]})."
fi

rel() { printf '%s' "${1#"${REPO_ROOT}"/}"; }

emit() { # rule file line anchor message evidence
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$(rel "$2")" "$3" "$4" "$5" "$6" >>"$FINDINGS"
}

bats_files() { grep -E '\.bats$' "$ALL" || true; }
yaml_files() { grep -E '\.(yaml|yml)$' "$ALL" || true; }
shell_files() { grep -E '(\.sh|\.bash|\.bats|\.mk|/Makefile)$' "$ALL" || true; }

# ── VAC001: `>= 0` on a counter inside a readiness expression ───────────────
#
# Both shapes: the inline `readyExpr: status.observedGeneration >= 0` and the
# block form (`readyExpr: |`) where the expression is on following lines. The
# block form is the one that shipped five times, and a line-oriented grep for
# `readyExpr.*>= 0` misses it entirely.
scan_ready_expr() {
	local f
	while read -r f; do
		[ -n "$f" ] || continue
		awk -v FNAME="$f" '
			function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
			{
				line = $0
				indent = match(line, /[^ \t]/) - 1
				if (inblock && indent <= blockindent && trim(line) != "") inblock = 0
				if (line ~ /readyExpr[ \t]*:[ \t]*[|>]/) { inblock = 1; blockindent = indent; next }
				# Inline form, and any CEL expression line inside a block.
				if (inblock || line ~ /readyExpr[ \t]*:/) {
					if (line ~ /(observedGeneration|generation|replicas|count|[Rr]eady[A-Za-z]*)[ \t]*>=[ \t]*0/ ||
					    line ~ />=[ \t]*0([^0-9.]|$)/) {
						printf "%s\t%d\t%s\n", FNAME, NR, trim(line)
					}
				}
			}
		' "$f"
	done < <(yaml_files) | while IFS=$'\t' read -r file lineno text; do
		emit VAC001 "$file" "$lineno" "$text" \
			"readiness gated on a >= 0 comparison — a non-negative counter satisfies it the instant the object exists" \
			"$text"
	done
}

# ── VAC002: --for=condition=ready on a kind with no Ready condition ─────────
#
# A Pod HAS a Ready condition, so the string alone is not the defect. These six
# kinds do not: Deployment/StatefulSet/DaemonSet/ReplicaSet have their own
# condition vocabularies (Available, Progressing, ReplicaFailure), and Job and
# CronJob report Complete/Failed/Suspended. `kubectl wait` on a condition a kind
# never sets does not error — it waits out the whole timeout and then fails,
# which reads as "the workload is unhealthy" when the workload is fine.
scan_wait_condition() {
	local f
	while read -r f; do
		[ -n "$f" ] || continue
		awk -v FNAME="$f" '
			function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
			# See the note on heredocs above scan_bats_bodies: a heredoc body is
			# data, and in this tree it is very often a deliberately-broken probe
			# script or a lint fixture.
			heredoc != "" { if (trim($0) == heredoc) heredoc = ""; next }
			{ t = trim($0) }
			match(t, /<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/) {
				h = substr(t, RSTART, RLENGTH); sub(/<<-?[ \t]*/, "", h); gsub(/["'"'"']/, "", h)
				heredoc = h
			}
			{
				if (t ~ /^#/) next                     # a comment explaining the trap is not a use
				low = tolower(t)
				if (low !~ /--for=condition=ready([ \t"'"'"']|$)/) next
				# The flag is only a defect as an argument to a `wait` invocation.
				# Without this the rule matched its own diagnostic message in this
				# file — prose that QUOTES the flag is not a use of it, and a
				# linter that flags the text describing the bug is a linter people
				# learn to ignore.
				if (low !~ /(^|[ \t;&|(])wait([ \t]|$)/) next
				if (low !~ /(deployment|deploy|statefulset|sts|daemonset|replicaset|cronjob|job)s?[\/ ]/) next
				# `kubectl wait --for=condition=ready pod/x` is correct: a Pod HAS a
				# Ready condition. Only flag when a conditionless kind is the target.
				printf "%d\t%s\t%s\n", NR, t, FNAME
			}
		' "$f"
	done < <(shell_files) | while IFS=$'\t' read -r lineno text file; do
		emit VAC002 "$file" "$lineno" "$text" \
			"--for=condition=ready on a kind that has no Ready condition (a Deployment reports Available/Progressing/ReplicaFailure)" \
			"$text"
	done
}

# ── VAC004: tautological assertions ─────────────────────────────────────────
#
# Line-oriented because each of these is decidable from the line alone. The
# `|| true` case is the subtlest and the most common: it turns a real assertion
# into a statement of intent, and it is invisible in a diff that adds it to the
# end of an existing line.
scan_tautologies() {
	local f
	while read -r f; do
		[ -n "$f" ] || continue
		awk -v FNAME="$f" '
			function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
			heredoc != "" { if (trim($0) == heredoc) heredoc = ""; next }
			{ t = trim($0) }
			match(t, /<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/) {
				h = substr(t, RSTART, RLENGTH); sub(/<<-?[ \t]*/, "", h); gsub(/["'"'"']/, "", h)
				heredoc = h
			}
			{
				if (t ~ /^#/) next
				why = ""
				# [ "$x" = "$x" ] — same operand both sides.
				if (match(t, /\[+[ \t]*"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?[ \t]*[=!]=?[ \t]*"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?[ \t]*\]+/)) {
					s = substr(t, RSTART, RLENGTH)
					n = split(s, parts, /[ \t]*[=!]=?[ \t]*/)
					if (n == 2) {
						l = parts[1]; r = parts[2]
						gsub(/[\[\]"${} \t]/, "", l); gsub(/[\[\]"${} \t]/, "", r)
						if (l != "" && l == r) why = "both sides of the comparison are the same operand"
					}
				}
				# [ -n "literal" ] / [ -n "$(echo literal)" ] — non-empty by construction.
				if (why == "" && t ~ /\[+[ \t]*-n[ \t]+"[^"$`]+"[ \t]*\]+/)
					why = "-n on a literal string is true by construction"
				if (why == "" && t ~ /\[+[ \t]*-n[ \t]+"?\$\(echo[ \t]+[^)$`]*\)"?[ \t]*\]+/)
					why = "-n on echo of a literal is true by construction"
				# -ge 0 on a status, $?, or a count.
				if (why == "" && t ~ /\[+[ \t]*"?\$(\?|\{?status\}?)"?[ \t]*-ge[ \t]*0[ \t]*\]+/)
					why = "-ge 0 on a non-negative value is always true"
				if (why == "" && t ~ /\[+[ \t]*"?\$\([^)]*(wc[ \t]+-l|grep[ \t]+-c)[^)]*\)"?[ \t]*-ge[ \t]*0[ \t]*\]+/)
					why = "-ge 0 on a count is always true (wc/grep -c never returns a negative)"
				# [ 1 -eq 1 ] and friends.
				if (why == "" && t ~ /\[+[ \t]*([0-9]+)[ \t]*-eq[ \t]*\1[ \t]*\]+/)
					why = "constant comparison is always true"
				if (why == "" && t ~ /^\[+[ \t]*(true|1)[ \t]*\]+[ \t]*$/)
					why = "a literal truthy word is not an assertion"
				# An assertion whose failure is swallowed.
				# The [ \t]* before || is load-bearing: without it the rule missed
				# `[ "$count" -eq 3 ] || true`, the canonical form, and matched only
				# the space-free `]||true` that nobody writes.
				if (why == "" && t ~ /^(\[+[ \t].*\]+|assert[a-z_]*[ \t].*|refute[a-z_]*[ \t].*|test[ \t]+.*)[ \t]*\|\|[ \t]*true[ \t]*$/)
					why = "|| true swallows the failure — the assertion cannot fail the run"
				if (why != "") printf "%d\t%s\t%s\t%s\n", NR, t, why, FNAME
			}
		' "$f"
	done < <(shell_files) | while IFS=$'\t' read -r lineno text why file; do
		emit VAC004 "$file" "$lineno" "$text" "tautology: $why" "$text"
	done
}

# ── VAC003 / VAC005 / VAC006: bats test bodies ─────────────────────────────
#
# Body-scoped, so this is a small state machine rather than a grep. It must
# understand three things a line-oriented pass gets wrong:
#
#   heredocs      a heredoc body is data, not code, and routinely contains
#                 text that looks like an assertion.
#   continuations a line ending in \ | && || ( , continues the previous
#                 command; classifying it separately double-counts.
#   `run`         `run cmd` ALWAYS returns 0 — that is its entire purpose. So a
#                 body of nothing but `run` lines cannot fail, and this is not
#                 a hypothetical: it is how a distroless `kubectl exec` test
#                 claimed to prove authorisation for months.
#
# The classification is deliberately conservative: anything that could plausibly
# fail (a bare command, a command substitution, a pipeline) counts as a real
# check, so the rules under-report rather than cry wolf. A linter that has to be
# argued with gets switched off, and then the tree has neither the linter nor
# the argument.
scan_bats_bodies() {
	local f
	while read -r f; do
		[ -n "$f" ] || continue
		awk -v FNAME="$f" '
			function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
			function report(rule, msg, ev) {
				printf "%s\t%d\t%s\t%s\t%s\t%s\n", rule, tline, thead, msg, ev, FNAME
			}
			BEGIN { intest = 0; heredoc = "" }

			# Heredoc bodies are data. Skip to the terminator before anything else.
			heredoc != "" {
				if (trim($0) == heredoc) heredoc = ""
				next
			}

			{ raw = $0; t = trim(raw) }

			# Opening a heredoc. <<EOF, <<-EOF, <<"EOF", <<'"'"'EOF'"'"'
			match(t, /<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/) {
				h = substr(t, RSTART, RLENGTH)
				sub(/<<-?[ \t]*/, "", h)
				gsub(/["'"'"']/, "", h)
				heredoc = h
			}

			!intest && t ~ /^@test[ \t]/ {
				intest = 1; tline = NR; thead = t
				nassert = 0; nneg = 0; nfailable = 0
				hasrun = 0; hasobs = 0; skipped = 0
				negev = ""; runev = ""
				cont = 0
				next
			}

			intest && raw ~ /^}[ \t]*$/ {
				if (!skipped) {
					if (nassert > 0 && nassert == nneg && nfailable == 0)
						report("VAC003", "the only assertion is a negative status check — it passes for ANY failure, including the command not existing", negev)
					else if (nassert == 0 && nfailable == 0)
						report("VAC005", "the test body contains no assertion and no command that can fail — it passes unconditionally", "(empty of checks)")
					else if (hasrun && !hasobs)
						report("VAC006", "run captures the exit code and never fails the test, and neither $status nor $output is examined", runev)
				}
				intest = 0
				next
			}

			intest {
				prevcont = cont
				cont = (raw ~ /(\\|\||&&|\|\||,|\()[ \t]*$/) ? 1 : 0
				if (prevcont) next
				if (t == "" || t ~ /^#/) next

				if (t ~ /(^|[ \t;])skip([ \t]|$|;)/) { skipped = 1; next }

				if (t ~ /\$\{?status\}?|\$\{?output\}?|\$\{?lines\[|assert_success|assert_failure|assert_output|refute_output|assert_line|refute_line|assert_equal/) hasobs = 1

				if (t ~ /^run[ \t]/) { hasrun = 1; if (runev == "") runev = t; next }

				# Negative-status assertion: passes for every failure reason.
				#
				# Anchored to the WHOLE line. Unanchored it also matched
				# `[ "$output" = "0" ] || [ "$status" -ne 0 ]`, which examines the
				# output and is therefore not the defect — a status check used as
				# one disjunct of a real assertion is fine. Only a line that
				# consists of nothing but the negative-status test is hollow.
				isneg = 0
				if (t ~ /^\[+[ \t]*"?\$\{?status\}?"?[ \t]*(-ne|!=|-gt)[ \t]*"?0"?[ \t]*\]+$/) isneg = 1
				if (t ~ /^assert_failure[ \t]*$/) isneg = 1

				isassert = 0
				if (t ~ /^\[+[ \t]/) isassert = 1
				if (t ~ /^!([ \t]|$)/) isassert = 1
				if (t ~ /^(assert|refute)[a-z_]*([ \t]|$)/) isassert = 1
				if (t ~ /^test[ \t]/) isassert = 1
				if (t ~ /^false[ \t]*$/) isassert = 1
				if (t ~ /^return[ \t]+[1-9]/) isassert = 1

				if (isassert) {
					nassert++
					if (isneg) { nneg++; if (negev == "") negev = t }
					next
				}

				# Everything the shell cannot fail on. Anything else is a real
				# command whose non-zero exit fails the bats test, so it counts
				# as a check even though it is not written as an assertion.
				if (t ~ /^(echo|printf|:|local|declare|export|unset|shift|continue|break|else|fi|done|esac|do|then|\{|\}|\)|;;)([ \t]|$)/ &&
				    t !~ /\$\(|`/) next
				if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/ && t !~ /\$\(|`/) next
				if (t ~ /^(if|for|while|case|elif)[ \t]/) next   # the body lines are classified on their own
				if (t ~ /^(set|setup|teardown)[ \t]/) next

				nfailable++
			}
		' "$f"
	done < <(bats_files) | while IFS=$'\t' read -r rule lineno head msg ev file; do
		emit "$rule" "$file" "$lineno" "$head" "$msg" "$ev"
	done
}

scan_ready_expr
scan_wait_condition
scan_tautologies
scan_bats_bodies

# ── Allowlist ───────────────────────────────────────────────────────────────

SUPPRESSED=0
STALE=0

apply_allowlist() {
	[ -f "$ALLOWLIST" ] || return 0

	local lineno=0 rule path anchor reason line
	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$((lineno + 1))
		case "$line" in '' | '#'*) continue ;; esac

		IFS='|' read -r rule path anchor reason <<<"$line"
		rule="$(printf '%s' "${rule:-}" | sed 's/^[ \t]*//;s/[ \t]*$//')"
		path="$(printf '%s' "${path:-}" | sed 's/^[ \t]*//;s/[ \t]*$//')"
		anchor="$(printf '%s' "${anchor:-}" | sed 's/^[ \t]*//;s/[ \t]*$//')"
		reason="$(printf '%s' "${reason:-}" | sed 's/^[ \t]*//;s/[ \t]*$//')"

		if [ -z "$rule" ] || [ -z "$path" ] || [ -z "$anchor" ] || [ -z "$reason" ]; then
			bad "allowlist:${lineno}: malformed entry — need 'RULE | path | anchor | reason'"
			printf '           got: %s\n' "$line" >&2
			STALE=1
			continue
		fi

		if [ ! -f "${REPO_ROOT}/${path}" ]; then
			bad "allowlist:${lineno}: ${path} no longer exists."
			printf '           A stale exception reads as reviewed-and-accepted while describing\n' >&2
			printf '           nothing, and pre-approves whatever takes that name next.\n' >&2
			STALE=1
			continue
		fi

		if ! grep -qF -- "$anchor" "${REPO_ROOT}/${path}"; then
			bad "allowlist:${lineno}: the anchored line is gone from ${path}."
			printf '           anchor: %s\n' "$anchor" >&2
			printf '           Re-read the exception and delete it, or re-anchor it deliberately.\n' >&2
			STALE=1
			continue
		fi

		local before after
		before="$(wc -l <"$FINDINGS")"
		# Drop only rows of this rule+file whose anchor text matches. Matching on
		# rule alone would let one entry silently pre-approve every future finding
		# of that shape in the file, which is the failure the entry-per-line
		# format exists to prevent.
		awk -F'\t' -v R="$rule" -v P="$path" -v A="$anchor" '
			$1 == R && $2 == P && (index($4, A) > 0 || index($6, A) > 0) { next } { print }
		' "$FINDINGS" >"${WORK}/f.tmp"
		mv "${WORK}/f.tmp" "$FINDINGS"
		after="$(wc -l <"$FINDINGS")"

		if [ "$before" -eq "$after" ]; then
			bad "allowlist:${lineno}: entry suppresses nothing (${rule} in ${path})."
			printf '           anchor: %s\n' "$anchor" >&2
			printf '           An exception for a finding that no longer occurs is dead pre-approval.\n' >&2
			printf '           Delete it — the code it excused has been fixed.\n' >&2
			STALE=1
		else
			SUPPRESSED=$((SUPPRESSED + before - after))
			log "allowed: ${rule} ${path} — ${reason}"
		fi
	done <"$ALLOWLIST"
}

apply_allowlist

# ── Report ──────────────────────────────────────────────────────────────────

COUNT="$(wc -l <"$FINDINGS" | tr -d ' ')"

printf '\n── can any of these checks actually fail? ──\n\n'
printf '   scanned %s files (%s bats, %s yaml) under: %s\n\n' \
	"$FILE_COUNT" "$(bats_files | wc -l | tr -d ' ')" "$(yaml_files | wc -l | tr -d ' ')" "${ROOTS[*]}"

if [ "$COUNT" -gt 0 ]; then
	sort -t$'\t' -k1,1 -k2,2 -k3,3n "$FINDINGS" | while IFS=$'\t' read -r rule file lineno anchor message evidence; do
		bad "${rule}  ${file}:${lineno}"
		printf '           %s\n' "$message" >&2
		printf '           > %s\n' "$evidence" >&2
		if [ "$anchor" != "$evidence" ]; then
			printf '           in: %s\n' "$anchor" >&2
		fi
		printf '\n' >&2
	done
fi

if [ "$STALE" -ne 0 ]; then
	bad "the allowlist no longer describes this tree."
	printf '\n' >&2
	exit 1
fi

if [ "$COUNT" -gt 0 ]; then
	bad "${COUNT} vacuous assertion(s). Each one reads as coverage and cannot fail."
	printf '           Fix them, or add a line to %s with a stated reason.\n' "$(rel "$ALLOWLIST")" >&2
	printf '           Nothing was modified by this script.\n\n' >&2
	exit 1
fi

# Name what was checked. "All clear" over a rule set of six reads as a general
# guarantee about the tree's assertions, which this is not: it says these six
# shapes are absent, and nothing about any other way a check can be hollow.
ok "no VAC001-VAC006 findings in ${FILE_COUNT} files (${SUPPRESSED} allowlisted)."
printf '           (six shapes are checked; a check can still be hollow in a seventh way.)\n\n'
