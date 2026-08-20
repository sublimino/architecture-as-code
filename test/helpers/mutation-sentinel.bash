#!/usr/bin/env bash
# shellcheck shell=bash
#
# mutation-sentinel.bash — shared safety rail for test/*-mutation-proof.sh.
#
# ═══ Why this file exists ═══════════════════════════════════════════════════
#
# terraform/CONTRACT.md §7b requires a mutation proof to break the REAL file,
# not a fixture copy. That rule is correct — it replaced one that produced three
# dead assertions in a single day, every one of them inside a green suite with a
# passing fixture mutation.
#
# The cost of the rule is that every proof now shares one mutable working tree.
# `make gcp-tf-validate` chains the proofs with `&&`:
#
#     GCP_TF_PROOFS_RUN ?= $(foreach p,$(GCP_TF_PROOFS),bash $(p) &&) true
#
# so a proof that dies mid-mutation leaves a deliberately-broken file on disk,
# and every later proof in the chain — plus the NEXT gate run, and any teammate
# who pulls — starts against a tree nobody knows is dirty. Three proofs mutate
# `scripts/gcp-tf/demo-up.sh`, so this is not theoretical: it has already
# happened. A killed gate left
#
#     [ "${FORCE:-0}" != "1" ] || force=1      replaced by      :
#
# and the following run reported it as content lost in a merge. Half an hour to
# diagnose, because a functional line replaced by a no-op is exactly what a bad
# merge looks like.
#
# ═══ Why a trap is not enough ═══════════════════════════════════════════════
#
# A `trap ... EXIT` handles a FAILING proof correctly, and it survives SIGTERM.
# It does NOT survive SIGKILL, and SIGKILL is what a tool timeout escalates to.
# No trap can be written that survives it. That is precisely the gap the
# sentinel fills: it is the only artefact that outlives a hard kill and knows a
# real file was mutated.
#
# ═══ Three rules this helper enforces, each paid for ════════════════════════
#
# 1. REFUSE, NEVER AUTO-REPAIR.
#    A harness that silently restores makes the next run green and hides that a
#    destructive run was interrupted — the mitigation-masks-its-own-alarm defect
#    this repo has spent a day removing. So a found sentinel is a hard stop, and
#    the refusal prints the ONE command that settles what it is looking at:
#    `git show <commit>:<path>` against the working file. Leaked mutation, or
#    real regression, in a single step.
#
# 2. A LIVE PID IS A RUNNING HARNESS, NOT A LEAK.
#    Two proofs invoked concurrently is a different problem from one proof
#    killed yesterday, and the two demand opposite responses (wait vs. inspect).
#    The sentinel records the pid AND that pid's /proc start time, so a recycled
#    pid cannot be mistaken for a live one, and the refusal says which case it
#    is. Getting this distinction printed is what turned a half-hour diagnosis
#    into one read.
#
# 3. RESTORE IS VERIFIED ON CONTENT *AND* MODE.
#    `cp pristine target` over an EXISTING destination keeps the destination's
#    mode, not the source's. A mutation applied by `mv` from a fresh tempfile
#    takes that tempfile's umask-derived 644 and silently drops the executable
#    bit. Content then restores byte-identical while the mode does not, and
#    sha256 alone cannot see it — observed here as a dangling mode-only diff
#    after a run that reported zero findings. Both are checked, both reported.
#
# ═══ Sentinel naming ════════════════════════════════════════════════════════
#
# `.<proof-name>-mutation-in-progress`, at the repo root, UNIQUE per proof.
#
# A shared name is worse than no name at all. Proof A finishes, its restore
# deletes the marker, and proof B — which was killed earlier with a mutation
# still on disk — now sees a clean repo, reads its own leaked mutation as a
# genuine failure, and the refusal that exists to prevent exactly that never
# fires. `.mutation-in-progress` (generic) was in use by one proof and is the
# shape of that bug.
#
# The `*mutation-in-progress` suffix is deliberate: .gitignore already carries
# that glob, so every sentinel minted through this helper is ignored the day it
# is named, with no .gitignore edit and no chance of one being committed.
# test/terraform-mutation-sentinel.bats asserts BOTH the uniqueness and the
# ignore coverage across every proof on disk, derived from disk rather than from
# a hand-written list.
#
# ═══ Interface ══════════════════════════════════════════════════════════════
#
#   ms_guard_init <proof-name> <file> [<file>...]
#       Refuse if a sentinel for <proof-name> exists (exit 3 leaked / 4 running).
#       Snapshot every <file> to a backup dir OUTSIDE the repository, recording
#       sha256 and mode. Does not arm.
#
#   ms_guard_arm  [<label>]     Write/refresh the sentinel. Call before mutating.
#   ms_guard_disarm             Remove the sentinel. Rarely called directly.
#   ms_guard_restore            Restore content+mode, verify, clear on success.
#   ms_guard_verify             Verify only. Returns 1 on drift. Prints a report.
#   ms_guard_report             Print "<sha256>  <mode>  <path>" per guarded file.
#   ms_guard_finish             restore + verify + drop backup dir. Returns verify.
#   ms_sed <file> <sed-expr>    Mutate, distinguishing SYNTAX ERROR from NO-OP.
#   ms_assert_mutated <file>    Assert <file> now differs from its pristine copy.
#   ms_sentinel_path            Echo the sentinel path.
#
# Under `set -e`, call the returning-status functions in a condition:
#
#     if ! ms_guard_verify; then ...; fi
#
# ═══ What this helper deliberately does NOT do ══════════════════════════════
#
# It does not lock. Two proofs mutating the same file concurrently is a real
# hazard (`scripts/gcp-tf/demo-up.sh` has three owners) but the gate runs them
# sequentially with `&&`, so the sentinel's live-pid refusal is the correct
# guard for it: a concurrent second run stops with a message naming the first,
# rather than silently interleaving mutations. A lock would make that case wait
# and then succeed, which is worse — it hides that two owners are colliding.
#
# It does not `git checkout`. Restoring a directory reverts in-progress work
# elsewhere in the same tree, and the resulting "the guard did not fire" reads
# exactly like a real finding.

# ── Exit codes, so a caller and a reader agree on what happened ─────────────
MS_EXIT_HARNESS=2 # the harness itself is broken (bad pattern, missing file)
MS_EXIT_LEAKED=3  # a previous run died with a mutation on disk
MS_EXIT_RUNNING=4 # another instance of this proof is alive right now

MS_PROOF_NAME=""
MS_SENTINEL=""
MS_BACKUP_DIR=""
MS_HEAD_COMMIT=""
MS_FILES=()
MS_SHAS=()
MS_MODES=()

ms__die() { # message...
	printf 'HARNESS ERROR: %s\n' "$1" >&2
	shift
	local line
	for line in "$@"; do printf '               %s\n' "$line" >&2; done
	exit "$MS_EXIT_HARNESS"
}

# The repo root, derived from this file's own location (<root>/test/helpers/).
#
# Deliberately NOT `git rev-parse --show-toplevel` against the cwd, and not the
# caller's $REPO_ROOT. Proofs differ: some `cd "$REPO_ROOT"` and pass relative
# paths, some never cd and pass absolute ones. Anchoring here makes the helper
# correct under both without the caller having to know.
#
# Overridable by presetting MS_REPO_ROOT, which is the only reason this rail can
# be tested at all: its own suite drives it against a throwaway git repo in
# BATS_TEST_TMPDIR. A component that can only be exercised against the real tree
# would have to mutate the real tree to prove it protects the real tree.
MS_REPO_ROOT="${MS_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Repo-relative form of a guarded path.
#
# Load-bearing for the refusal message: `git show <commit>:/home/andy/...` is
# not a thing git can resolve, so a proof passing absolute paths would print a
# discriminator that silently does not work — at the exact moment somebody is
# trying to tell a leaked mutation from a real regression.
ms__rel() { # path
	local p="$1"
	case "$p" in
	"${MS_REPO_ROOT}/"*) printf '%s' "${p#"${MS_REPO_ROOT}/"}" ;;
	/*) printf '%s' "$p" ;; # outside the repo; left alone and reported as-is
	*) printf '%s' "$p" ;;
	esac
}

ms__abs() { # rel
	case "$1" in
	/*) printf '%s' "$1" ;;
	*) printf '%s/%s' "$MS_REPO_ROOT" "$1" ;;
	esac
}

ms__sha() { sha256sum "$(ms__abs "$1")" | cut -d' ' -f1; }
ms__mode() { stat -c '%a' "$(ms__abs "$1")"; }

# The start time of <pid>, in clock ticks since boot, or "" if it is gone.
#
# /proc/<pid>/stat cannot be split on whitespace: field 2 is the executable name
# in parentheses and may itself contain spaces and parentheses. Everything after
# the LAST ") " is fields 3..52, so starttime (field 22) is field 20 of that
# remainder. Reading it is what makes the liveness check immune to pid reuse —
# a recycled pid has a different start time, and without this a long-dead
# harness could be reported as "still running" and a leaked mutation left alone.
ms__pid_starttime() { # pid
	local pid="$1" stat_line rest
	[ -n "$pid" ] || return 0
	[ -r "/proc/${pid}/stat" ] || return 0
	stat_line="$(cat "/proc/${pid}/stat" 2>/dev/null)" || return 0
	rest="${stat_line##*') '}"
	printf '%s' "$rest" | awk '{ print $20 }'
}

# True only if <pid> is alive AND is the same process that wrote the sentinel.
#
# Never implemented with a pgrep/pkill pattern: this tool wraps commands in
# `bash -c`, so the whole script text is the wrapper shell's own cmdline and a
# pattern naming the proof matches the process doing the searching.
ms__pid_is_live() { # pid want_starttime
	local pid="$1" want="$2" got
	[ -n "$pid" ] || return 1
	[ -d "/proc/${pid}" ] || return 1
	got="$(ms__pid_starttime "$pid")"
	if [ -n "$want" ]; then
		[ "$got" = "$want" ] || return 1
	fi
	return 0
}

ms__sentinel_field() { # key
	[ -f "$MS_SENTINEL" ] || return 0
	sed -n "s/^${1}:[[:space:]]*//p" "$MS_SENTINEL" | head -1
}

ms_sentinel_path() { printf '%s\n' "$MS_SENTINEL"; }

ms__refuse() {
	local pid start label started commit
	pid="$(ms__sentinel_field pid)"
	start="$(ms__sentinel_field pid_starttime)"
	label="$(ms__sentinel_field label)"
	started="$(ms__sentinel_field started)"
	commit="$(ms__sentinel_field commit)"

	if ms__pid_is_live "$pid" "$start"; then
		{
			printf '\n'
			printf 'REFUSING TO START: another run of %s is ALIVE.\n' "$MS_PROOF_NAME"
			printf '\n'
			printf '  sentinel : %s\n' "$MS_SENTINEL"
			printf '  pid      : %s  (running now — this is NOT a leaked mutation)\n' "$pid"
			printf '  started  : %s\n' "${started:-unknown}"
			printf '  mutation : %s\n' "${label:-<none recorded>}"
			printf '\n'
			printf '  Nothing is wrong with the tree yet. That run owns the files below\n'
			printf '  and will restore them. Wait for it, or kill it and re-read this\n'
			printf '  message — a dead pid turns this into the LEAKED case, which needs\n'
			printf '  the tree inspected by hand.\n'
			printf '\n'
			ms__print_guarded_files
			printf '\n'
		} >&2
		exit "$MS_EXIT_RUNNING"
	fi

	{
		printf '\n'
		printf 'REFUSING TO START: %s left a mutation on disk.\n' "$MS_PROOF_NAME"
		printf '\n'
		printf '  sentinel : %s\n' "$MS_SENTINEL"
		printf '  pid      : %s  (DEAD — that run was killed, probably SIGKILL from a\n' "${pid:-unknown}"
		printf '             tool timeout, which no EXIT trap survives)\n'
		printf '  started  : %s\n' "${started:-unknown}"
		printf '  mutation : %s\n' "${label:-<none recorded>}"
		printf '\n'
		printf '  One or more REAL files are probably still mutated. Anything failing\n'
		printf '  right now is this harness'"'"'s doing, not a regression — a functional\n'
		printf '  line replaced by a bare ":" is a mutation signature, never a merge\n'
		printf '  artefact.\n'
		printf '\n'
		printf '  Settle it in one step. This compares each file against the commit the\n'
		printf '  killed run started from, so the diff is the mutation and nothing else:\n'
		printf '\n'
		ms__print_discriminator "${commit:-HEAD}"
		printf '\n'
		printf '  Restore deliberately, then remove the sentinel:\n'
		printf '\n'
		printf '      rm %s\n' "$MS_SENTINEL"
		printf '\n'
		printf '  This harness will NOT repair the tree for you. A run that silently\n'
		printf '  fixed its own mess would go green and hide that a destructive step is\n'
		printf '  being killed part-way — and every gate result read since then was\n'
		printf '  computed against an unknown tree. CONTRACT §7b.\n'
		printf '\n'
	} >&2
	exit "$MS_EXIT_LEAKED"
}

ms__print_guarded_files() {
	local f
	printf '  files under this harness'"'"'s control:\n'
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		printf '      %s\n' "$f"
	done < <(ms__sentinel_field_all file)
}

ms__sentinel_field_all() { # key
	[ -f "$MS_SENTINEL" ] || return 0
	sed -n "s/^${1}:[[:space:]]*//p" "$MS_SENTINEL"
}

ms__print_discriminator() { # commit
	local commit="$1" f any=0
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		any=1
		# Two different path forms in one command, and both are load-bearing.
		#
		# `git show <commit>:<path>` needs a WORKTREE-RELATIVE path; handed an
		# absolute one it fails with "exists on disk, but not in <commit>".
		# `diff`'s operand needs to be ABSOLUTE, because whoever reads this is
		# not necessarily standing in the repo root — and a printed command that
		# only works from one directory is a dead end found during an incident.
		# Both shapes are executed for real by
		# test/terraform-mutation-sentinel.bats.
		printf '      git -C %s show %s:%s | diff -u - %s/%s\n' \
			"$MS_REPO_ROOT" "$commit" "$f" "$MS_REPO_ROOT" "$f"
	done < <(ms__sentinel_field_all file)
	if [ "$any" -eq 0 ]; then
		printf '      git -C %s status --porcelain\n' "$MS_REPO_ROOT"
		printf '      git -C %s diff\n' "$MS_REPO_ROOT"
	fi
	local b
	b="$(ms__sentinel_field backup_dir)"
	if [ -n "$b" ]; then
		printf '\n'
		printf '  Pristine copies, if that run got far enough to take them and the\n'
		printf '  directory has not been reaped:\n'
		printf '      %s\n' "$b"
	fi
}

# ── ms_guard_init <proof-name> <file> [<file>...] ───────────────────────────
ms_guard_init() {
	local name="${1:-}"
	shift || true

	[ -n "$name" ] || ms__die "ms_guard_init needs a proof name as its first argument."
	case "$name" in
	*[!a-z0-9-]*) ms__die "proof name '${name}' must be lower-case letters, digits and dashes." ;;
	esac
	[ "$#" -gt 0 ] || ms__die "ms_guard_init needs at least one file to guard."

	MS_PROOF_NAME="$name"
	# Suffix chosen to fall under the existing `*mutation-in-progress` glob in
	# .gitignore — see the naming note at the top of this file.
	MS_SENTINEL="${MS_REPO_ROOT}/.${name}-mutation-in-progress"

	[ -e "$MS_SENTINEL" ] && ms__refuse

	local f rel
	for f in "$@"; do
		[ -f "$(ms__abs "$(ms__rel "$f")")" ] || ms__die \
			"guarded file not found: ${f}" \
			"Paths are taken relative to ${MS_REPO_ROOT} unless absolute."
	done

	MS_HEAD_COMMIT="$(git -C "$MS_REPO_ROOT" rev-parse HEAD 2>/dev/null || echo HEAD)"
	MS_BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/msproof-${name}.XXXXXX")"

	MS_FILES=()
	MS_SHAS=()
	MS_MODES=()
	for f in "$@"; do
		rel="$(ms__rel "$f")"
		mkdir -p "${MS_BACKUP_DIR}/$(dirname "$rel")"
		# -p so the pristine copy carries the original mode even before any
		# chmod on restore — belt and braces for a manual recovery.
		cp -p "$(ms__abs "$rel")" "${MS_BACKUP_DIR}/${rel}"
		MS_FILES+=("$rel")
		MS_SHAS+=("$(ms__sha "$rel")")
		MS_MODES+=("$(ms__mode "$rel")")
	done
}

# ── ms_guard_arm [label] ────────────────────────────────────────────────────
ms_guard_arm() { # [label]
	local label="${1:-unlabelled}" i
	[ -n "$MS_SENTINEL" ] || ms__die "ms_guard_arm called before ms_guard_init."
	{
		printf 'mutation-proof: %s\n' "$MS_PROOF_NAME"
		printf 'label:          %s\n' "$label"
		printf 'started:        %s\n' "$(date -Is 2>/dev/null || date)"
		printf 'pid:            %s\n' "$$"
		printf 'pid_starttime:  %s\n' "$(ms__pid_starttime "$$")"
		printf 'commit:         %s\n' "$MS_HEAD_COMMIT"
		printf 'backup_dir:     %s\n' "$MS_BACKUP_DIR"
		for i in "${!MS_FILES[@]}"; do
			printf 'file:           %s\n' "${MS_FILES[$i]}"
			printf 'pristine:       %s/%s  sha256=%s mode=%s\n' \
				"$MS_BACKUP_DIR" "${MS_FILES[$i]}" "${MS_SHAS[$i]}" "${MS_MODES[$i]}"
		done
	} >"$MS_SENTINEL"
}

ms_guard_disarm() { [ -n "$MS_SENTINEL" ] && rm -f "$MS_SENTINEL"; return 0; }

# Arm only if nothing is armed. Lets ms_sed guarantee the marker exists on every
# mutation path without stamping over a caller's explicit, more useful label.
#
# This is the difference between a rail that is enforced and one that depends on
# every call site remembering to arm. A proof that mutates without arming leaves
# NOTHING behind when it is SIGKILLed, which is the exact hole the sentinel
# exists to close.
ms__arm_if_needed() { # label
	[ -n "$MS_SENTINEL" ] || ms__die "mutation attempted before ms_guard_init."
	[ -e "$MS_SENTINEL" ] || ms_guard_arm "$1"
}

# ── ms_guard_verify ─────────────────────────────────────────────────────────
#
# Content AND mode. Returns 1 on any drift, and names which of the two moved —
# a mode-only diff is invisible to sha256 and reads as "restored cleanly".
ms_guard_verify() {
	local i f bad=0 sha mode
	for i in "${!MS_FILES[@]}"; do
		f="${MS_FILES[$i]}"
		if [ ! -f "$(ms__abs "$f")" ]; then
			printf '*** RESTORE FAILED: %s does not exist.\n' "$f" >&2
			bad=1
			continue
		fi
		sha="$(ms__sha "$f")"
		mode="$(ms__mode "$f")"
		if [ "$sha" != "${MS_SHAS[$i]}" ]; then
			printf '*** RESTORE FAILED (content): %s\n' "$f" >&2
			printf '        want sha256 %s\n' "${MS_SHAS[$i]}" >&2
			printf '        got  sha256 %s\n' "$sha" >&2
			bad=1
		fi
		if [ "$mode" != "${MS_MODES[$i]}" ]; then
			printf '*** RESTORE FAILED (mode): %s\n' "$f" >&2
			printf '        want mode %s, got %s\n' "${MS_MODES[$i]}" "$mode" >&2
			printf '        sha256 matches, so this is invisible to a content check.\n' >&2
			printf '        `cp` onto an existing file keeps the DESTINATION mode; a\n' >&2
			printf '        mutation applied via `mv` from a tempfile drops the +x bit.\n' >&2
			bad=1
		fi
	done
	return "$bad"
}

# ── ms_guard_report ─────────────────────────────────────────────────────────
ms_guard_report() {
	local i f sha mode
	for i in "${!MS_FILES[@]}"; do
		f="${MS_FILES[$i]}"
		if [ -f "$f" ]; then
			sha="$(ms__sha "$f")"
			mode="$(ms__mode "$f")"
		else
			sha="<missing>"
			mode="----"
		fi
		printf '  %s  mode=%s  %s\n' "$sha" "$mode" "$f"
	done
}

# ── ms_guard_restore ────────────────────────────────────────────────────────
#
# The sentinel is cleared ONLY when verification passes. A failed restore that
# also deleted its own marker would leave a mutated tree with nothing recording
# that fact — which is the exact failure the sentinel exists to prevent, and it
# is what an unconditional `rm -f "$SENTINEL"` in an EXIT trap does today.
ms_guard_restore() {
	local i f pristine got bad=0
	for i in "${!MS_FILES[@]}"; do
		f="${MS_FILES[$i]}"
		pristine="${MS_BACKUP_DIR}/${f}"

		# The pristine copy is verified BEFORE it is trusted.
		#
		# `[ -f "$pristine" ] && cp ...` silently skips when the backup is gone,
		# and silently installs corruption when it is damaged. Both then surface
		# as "RESTORE FAILED (content)" pointing at the WORKING file — sending
		# you to inspect the one thing that is not at fault.
		#
		# Not hypothetical: this rail's own backup directory was reaped mid-run
		# by an external cleaner (a sandbox that owned $TMPDIR), and the copy
		# that came back was neither the original nor the mutation. The recorded
		# sha256 in the sentinel is what caught it.
		if [ ! -f "$pristine" ]; then
			printf '*** PRISTINE COPY MISSING: %s\n' "$pristine" >&2
			printf '        for %s\n' "$f" >&2
			printf '        Nothing can be restored from it. Recover with:\n' >&2
			printf '        git -C %s show %s:%s > %s\n' \
				"$MS_REPO_ROOT" "$MS_HEAD_COMMIT" "$f" "$(ms__abs "$f")" >&2
			bad=1
			continue
		fi
		got="$(sha256sum "$pristine" | cut -d' ' -f1)"
		if [ "$got" != "${MS_SHAS[$i]}" ]; then
			printf '*** PRISTINE COPY CORRUPT: %s\n' "$pristine" >&2
			printf '        want sha256 %s\n' "${MS_SHAS[$i]}" >&2
			printf '        got  sha256 %s\n' "$got" >&2
			printf '        Restoring from it would install unknown content.\n' >&2
			bad=1
			continue
		fi

		cp "$pristine" "$(ms__abs "$f")"
		# Not a courtesy. `cp` onto an existing destination keeps the
		# DESTINATION's mode, so without this the +x bit stays dropped.
		chmod "${MS_MODES[$i]}" "$(ms__abs "$f")"
	done

	if [ "$bad" -ne 0 ]; then
		printf '*** SENTINEL KEPT at %s — the tree is NOT clean.\n' "$MS_SENTINEL" >&2
		return 1
	fi
	if ms_guard_verify; then
		ms_guard_disarm
		return 0
	fi
	printf '*** SENTINEL KEPT at %s — the tree is NOT clean.\n' "$MS_SENTINEL" >&2
	return 1
}

# ── ms_guard_finish ─────────────────────────────────────────────────────────
#
# The backup dir is kept when restore fails: it is the only pristine copy left,
# and the refusal on the next run points at it.
ms_guard_finish() {
	local rc=0
	ms_guard_restore || rc=1
	[ -n "$MS_BACKUP_DIR" ] && [ "$rc" -eq 0 ] && rm -rf "$MS_BACKUP_DIR"
	return "$rc"
}

# ── ms_guard_on_exit — the EXIT trap every proof should install ─────────────
#
#     trap ms_guard_on_exit EXIT
#
# Two things must both be true and they pull in opposite directions.
#
# THE TRAP MUST NOT REWRITE THE VERDICT. A failing last command in a bash EXIT
# trap replaces the script's exit status. That has already turned an 8/8-green
# run in this repo into a reported failure, and a proof's own PASS/FAIL count is
# the thing the gate is reading. So the status is captured FIRST and re-raised.
#
# A DIRTY TREE MUST NOT REPORT SUCCESS. If the proof passed but the restore did
# not, exiting 0 would hand the next proof in the &&-chain a mutated file and
# call it green. So a failed restore promotes 0 to a harness error — and only 0.
# A proof that already failed keeps its own status, which is the more
# informative of the two.
ms_guard_on_exit() {
	local status=$?
	if ! ms_guard_finish; then
		[ "$status" -eq 0 ] && status="$MS_EXIT_HARNESS"
	fi
	exit "$status"
}

# ── ms_sed <file> <sed-expr> ────────────────────────────────────────────────
#
# The two silent failures this exists for, told apart by name:
#
#   SYNTAX ERROR — an unescaped `|` inside a `s|…|…|` program, an unbalanced
#   brace. sed exits non-zero and touches nothing. Reads identically to "the
#   mutation landed and the guard did not fire", which sends you to fix a guard
#   that is fine.
#
#   NO-OP — the program is valid, the pattern no longer matches because the
#   file it targets was refactored. sed exits 0 and changes nothing, the suite
#   then runs against CORRECT code and passes, and the harness reports the
#   opposite of what it claims to have proven.
#
# Both abort the run. Neither is ever reported as a finding.
ms_sed() { # file sed-expr
	local file="$1" expr="$2" abs before after err rc=0
	abs="$(ms__abs "$(ms__rel "$file")")"
	[ -f "$abs" ] || ms__die "ms_sed: no such file: ${file}"
	# Armed HERE, not at the call site. A mutation applied with no sentinel on
	# disk leaves nothing behind when the run is SIGKILLed.
	ms__arm_if_needed "${file}: ${expr}"
	before="$(ms__sha "$file")"
	err="$(sed -i "$expr" "$abs" 2>&1)" || rc=$?
	if [ "$rc" -ne 0 ]; then
		ms__die "sed REJECTED the mutation program (syntax), it never ran." \
			"file:       ${file}" \
			"expression: ${expr}" \
			"sed said:   ${err}" \
			"This is NOT 'the guard did not fire'. Watch for an unescaped |" \
			"inside s|…|…|, and for \$ in a double-quoted program expanding" \
			"against this harness's own environment."
	fi
	after="$(ms__sha "$file")"
	if [ "$before" = "$after" ]; then
		ms__die "the mutation changed NOTHING — the pattern no longer matches." \
			"file:       ${file}" \
			"expression: ${expr}" \
			"sed succeeded and the file is byte-identical, so the suite below" \
			"would run against CORRECT code and pass. Fix the pattern; do NOT" \
			"read the resulting green as a proof."
	fi
	return 0
}

# ── The second level: did the mutation REACH the thing under test? ─────────
#
# Comparing hashes proves the BYTES changed. It does not prove the system under
# test now evaluates anything different, and the gap between those two is a
# false finding that points at correct code — worse than a missed defect,
# because somebody then goes and "fixes" a working guard.
#
# The measured case: a proof mutated `KEYS_DIR ?=` at Makefile:42. The hash
# moved, so the assert passed. Makefile:43 is `export KEYS_DIR`, and an
# inherited environment variable beats `?=` — make expanded the SAME value, the
# suite stayed green, and the proof reported a working guard as dead.
#
# `export` is only one absorber. `?=` defaults, `${X:-fallback}`, build caches,
# generated files, vendored copies and anything read from a second source all
# swallow a mutation while the bytes on disk change happily.
#
# So: capture what the system under test SAYS before the mutation, and require
# that to move too.
#
#   ms_sed_effective <file> <sed-expr> <oracle-command>
#
# The oracle should be the cheapest command whose output the mutation must
# change — `make -n <target>`, `bash -n`, a `--dry-run`, a single grep of a
# generated artefact. It runs from the repo root.
MS_ORACLE_BEFORE=""

ms_oracle_capture() { # command
	MS_ORACLE_BEFORE="$(cd "$MS_REPO_ROOT" && bash -c "$1" 2>&1)" || true
}

ms_assert_effective() { # command [context]
	local cmd="$1" context="${2:-the mutation}" after
	after="$(cd "$MS_REPO_ROOT" && bash -c "$cmd" 2>&1)" || true
	if [ "$after" = "$MS_ORACLE_BEFORE" ]; then
		ms__die \
			"the bytes changed but the SYSTEM UNDER TEST did not notice." \
			"context: ${context}" \
			"oracle:  ${cmd}" \
			"The file on disk is different and this oracle evaluates to exactly" \
			"the same thing, so the check below would run against EFFECTIVELY" \
			"UNCHANGED behaviour and pass — reporting a working guard as dead." \
			"Something is absorbing the mutation. Look for an \`export\` beating" \
			"a \`?=\`, a \${X:-fallback}, a cache, a generated file, or a second" \
			"copy of the value that is the one actually being read."
	fi
	return 0
}

ms_sed_effective() { # file sed-expr oracle-command
	ms_oracle_capture "$3"
	ms_sed "$1" "$2"
	ms_assert_effective "$3" "$1: $2"
}

# ── ms_assert_mutated <file> ────────────────────────────────────────────────
#
# For mutations applied by something other than sed (awk into a tempfile, a
# heredoc rewrite, a python3 filter). Same invariant, applied after the fact.
ms_assert_mutated() { # file
	local file i want=""
	file="$(ms__rel "$1")"
	for i in "${!MS_FILES[@]}"; do
		[ "${MS_FILES[$i]}" = "$file" ] && want="${MS_SHAS[$i]}"
	done
	[ -n "$want" ] || ms__die "ms_assert_mutated: ${file} is not guarded by ms_guard_init."
	# Unlike ms_sed this runs AFTER the mutation, so it cannot arm on the
	# caller's behalf — by now a SIGKILL would already have leaked. An unarmed
	# sentinel here means the mutation ran outside the rail, which is a harness
	# defect and not a finding.
	[ -e "$MS_SENTINEL" ] || ms__die \
		"${file} was mutated with NO sentinel armed." \
		"Call ms_guard_arm \"<label>\" BEFORE applying a non-sed mutation." \
		"A SIGKILL between the mutation and here leaves the file broken on" \
		"disk with nothing recording that fact."
	if [ "$(ms__sha "$file")" = "$want" ]; then
		ms__die "the mutation changed NOTHING — ${file} is byte-identical." \
			"The check below would run against CORRECT code and pass." \
			"Fix the mutation; do NOT read the resulting green as a proof."
	fi
	return 0
}
