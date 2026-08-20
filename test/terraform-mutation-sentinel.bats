#!/usr/bin/env bats
#
# terraform-mutation-sentinel.bats — the safety rail under test/*-mutation-proof.sh.
#
# ═══ The shape this file is written against ═════════════════════════════════
#
# Nine defects in this repo in one day shared one shape: THE ASSERTION WAS TRUE,
# AND IT WAS TRUE OF THE WRONG THING. Prose satisfying a grep. A token matching
# inside a longer token. The other branch of an `if` satisfying a stub.
#
# A test for refusal logic is squarely in that family, because
#
#     "the harness refuses when a sentinel exists"
#
# is trivially satisfied by a harness that refuses unconditionally — which would
# take the entire mutation gate offline while every test here stayed green. So
# every refusal case below is paired with its negative: it refuses WITH a
# sentinel and PROCEEDS WITHOUT one, and the proceed case asserts the work
# actually happened (backup taken, sentinel armed, mutation applied) rather than
# merely that the exit status was 0.
#
# Same treatment for the mode check: asserting "restore verifies the mode" is
# satisfied by a verifier that always fails, so mode drift is proven detected
# AND a clean restore is proven to pass.
#
# Registration: named test/terraform-*.bats, which is what `GCP_TF_BATS` globs.
# Nothing else is required and a hand-registration would run it twice.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	HELPER="${REPO_ROOT}/test/helpers/mutation-sentinel.bash"
	SANDBOX="${BATS_TEST_TMPDIR}/sandbox"
	mkdir -p "$SANDBOX"
	# A throwaway git repo so `git rev-parse` and the discriminator resolve for
	# real. Signing is forced off: a bare `git commit` under a global
	# commit.gpgsign=true launches pinentry on a tty no test runner has, and
	# blocks until the harness times out.
	git -C "$SANDBOX" init -q 2>/dev/null
	git -C "$SANDBOX" config user.email t@example.com
	git -C "$SANDBOX" config user.name t
	git -C "$SANDBOX" config commit.gpgsign false
	printf '#!/bin/sh\nreal_line=1\n' >"${SANDBOX}/target.sh"
	chmod 755 "${SANDBOX}/target.sh"
	git -C "$SANDBOX" add -A
	git -C "$SANDBOX" commit -qm init --no-gpg-sign
}

# A minimal proof harness that uses the helper exactly as a real proof does.
# Body is supplied by the caller so each test drives one path.
#
# MS_REPO_ROOT is preset so the rail operates on the sandbox rather than on this
# repository. That injectable boundary is the only reason this file can exist:
# a helper that could only be exercised against the real tree would have to
# mutate the real tree to prove that it protects the real tree.
write_proof() { # <body>
	cat >"${SANDBOX}/proof.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${SANDBOX}"
export MS_REPO_ROOT="${SANDBOX}"
# shellcheck source=/dev/null
source "${HELPER}"
${1}
EOF
	chmod +x "${SANDBOX}/proof.sh"
}

SENTINEL_OF() { printf '%s/.%s-mutation-in-progress' "$SANDBOX" "$1"; }

# A pid that is guaranteed not to exist. pid_max tops out at 4194304 on Linux,
# so /proc/999999999 can never appear. Deterministic, unlike reaping a child and
# hoping the pid is not recycled between the wait and the assertion.
DEAD_PID=999999999

# ───────────────────────────────────────────────────────────────────────────
# Direction 1 of 2: it PROCEEDS when there is no sentinel.
#
# Without this, every refusal test below is satisfied by a harness that refuses
# unconditionally.
# ───────────────────────────────────────────────────────────────────────────

@test "PROCEEDS on a clean tree, and does the work rather than just exiting 0" {
	write_proof '
		ms_guard_init demo-proof target.sh
		ms_guard_arm "M1 example"
		ms_sed target.sh "s/real_line=1/real_line=0/"
		grep -q "real_line=0" target.sh || { echo "mutation not on disk"; exit 9; }
		[ -f "$MS_SENTINEL" ] || { echo "sentinel not armed"; exit 9; }
		[ -f "${MS_BACKUP_DIR}/target.sh" ] || { echo "no backup taken"; exit 9; }
		ms_guard_finish
		echo PROCEEDED
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *PROCEEDED* ]]
	# and it cleaned up after itself. Scoped to the guarded path: the sandbox
	# also holds the generated proof.sh, and an unscoped `status` would be
	# non-empty for a reason that has nothing to do with restoration.
	[ ! -e "$(SENTINEL_OF demo-proof)" ]
	run git -C "$SANDBOX" status --porcelain -- target.sh
	[ -z "$output" ]
}

# ───────────────────────────────────────────────────────────────────────────
# Direction 2 of 2: it REFUSES when a sentinel is present.
# ───────────────────────────────────────────────────────────────────────────

@test "REFUSES when a sentinel exists, and does not touch the tree" {
	printf 'mutation-proof: demo-proof\npid:            %s\n' "$DEAD_PID" \
		>"$(SENTINEL_OF demo-proof)"
	write_proof '
		ms_guard_init demo-proof target.sh
		echo SHOULD-NOT-REACH
		ms_sed target.sh "s/real_line=1/real_line=0/"
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 3 ]
	[[ "$output" != *SHOULD-NOT-REACH* ]]
	[[ "$output" == *"REFUSING TO START"* ]]
	# The refusal is inert: the guarded file is untouched.
	run grep -c 'real_line=1' "${SANDBOX}/target.sh"
	[ "$output" -eq 1 ]
}

@test "a DEAD pid is reported as a leaked mutation, not as a running harness" {
	printf 'mutation-proof: demo-proof\nlabel:          M7 something\npid:            %s\npid_starttime:  12345\ncommit:         HEAD\nfile:           target.sh\n' \
		"$DEAD_PID" >"$(SENTINEL_OF demo-proof)"
	write_proof 'ms_guard_init demo-proof target.sh'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 3 ]
	[[ "$output" == *"left a mutation on disk"* ]]
	[[ "$output" == *"DEAD"* ]]
	[[ "$output" != *"is ALIVE"* ]]
	# The whole point of the distinction: it names the mutation that leaked.
	[[ "$output" == *"M7 something"* ]]
}

@test "a LIVE pid is reported as a running harness, not as a leaked mutation" {
	sleep 30 &
	local live=$!
	local start
	start="$(awk '{ n=split($0, a, ") "); rest=a[n]; split(rest, b, " "); print b[20] }' "/proc/${live}/stat")"
	printf 'mutation-proof: demo-proof\nlabel:          M2 other\npid:            %s\npid_starttime:  %s\nfile:           target.sh\n' \
		"$live" "$start" >"$(SENTINEL_OF demo-proof)"
	write_proof 'ms_guard_init demo-proof target.sh'
	run bash "${SANDBOX}/proof.sh"
	kill "$live" 2>/dev/null || true
	# A DIFFERENT exit code from the leaked case, because the two need opposite
	# responses: wait for the live one, inspect the tree for the dead one.
	[ "$status" -eq 4 ]
	[[ "$output" == *"is ALIVE"* ]]
	[[ "$output" == *"NOT a leaked mutation"* ]]
	[[ "$output" != *"left a mutation on disk"* ]]
}

@test "a RECYCLED pid does not masquerade as a live harness" {
	# The reason the sentinel records /proc start time and not just the pid.
	# Without it, any long-running unrelated process that happened to inherit
	# the number would make a genuinely leaked mutation report as "still
	# running", and nobody would ever inspect the tree.
	sleep 30 &
	local live=$!
	printf 'mutation-proof: demo-proof\npid:            %s\npid_starttime:  1\nfile:           target.sh\n' \
		"$live" >"$(SENTINEL_OF demo-proof)"
	write_proof 'ms_guard_init demo-proof target.sh'
	run bash "${SANDBOX}/proof.sh"
	kill "$live" 2>/dev/null || true
	[ "$status" -eq 3 ]
	[[ "$output" == *"left a mutation on disk"* ]]
}

@test "the refusal prints the one command that settles leaked-vs-regression" {
	local head
	head="$(git -C "$SANDBOX" rev-parse HEAD)"
	printf 'mutation-proof: demo-proof\npid:            %s\ncommit:         %s\nfile:           target.sh\n' \
		"$DEAD_PID" "$head" >"$(SENTINEL_OF demo-proof)"
	write_proof 'ms_guard_init demo-proof target.sh'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 3 ]
	[[ "$output" == *"show ${head}:target.sh"* ]]
	# git's operand is worktree-relative, diff's is absolute — see the note in
	# ms__print_discriminator, and the test below that runs the thing for real.
	[[ "$output" == *"diff -u - ${SANDBOX}/target.sh"* ]]
	# and it is against the commit the killed run started from, not a bare HEAD,
	# so the diff is the mutation and not everything committed since.
	[[ "$output" != *"show HEAD:target.sh"* ]]
}

@test "the printed discriminator ACTUALLY RUNS, whether the proof stored the path absolute or relative" {
	# A refusal message carrying a command that errors is worse than no message:
	# it sends someone to a dead end during an incident, which is exactly when
	# they have least patience for it.
	#
	# `git show <commit>:<path>` needs a WORKTREE-RELATIVE path. Handed an
	# absolute one it fails with "exists on disk, but not in <commit>". Proofs
	# in this repo differ — some cd to the root and pass relative paths, some
	# never cd and pass "${REPO_ROOT}/scripts/..." — so both shapes are driven
	# here and the emitted command is EXECUTED, not just pattern-matched.
	#
	# Worktree note: the root must come from the worktree, not from
	# --git-common-dir. This repo runs many worktrees; a sibling test resolved
	# KEYS_DIR through the common dir and silently skipped in every one of them
	# while passing in the main checkout. The rail anchors on its own location,
	# which is inside the worktree.
	local shape
	for shape in relative absolute; do
		rm -f "$(SENTINEL_OF demo-proof)"
		git -C "$SANDBOX" checkout -q -- target.sh
		if [ "$shape" = relative ]; then
			write_proof '
				ms_guard_init demo-proof target.sh
				ms_sed target.sh "s/real_line=1/real_line=0/"
				exit 0   # leaks deliberately: no restore, sentinel stays armed
			'
		else
			write_proof '
				ms_guard_init demo-proof "${MS_REPO_ROOT}/target.sh"
				ms_sed "${MS_REPO_ROOT}/target.sh" "s/real_line=1/real_line=0/"
				exit 0
			'
		fi
		# Leak a mutation on purpose, without the EXIT trap installed.
		run bash "${SANDBOX}/proof.sh"
		[ "$status" -eq 0 ]
		[ -f "$(SENTINEL_OF demo-proof)" ]

		# Now the next run refuses. Harvest the command it printed and run it.
		write_proof 'ms_guard_init demo-proof target.sh'
		run bash "${SANDBOX}/proof.sh"
		[ "$status" -eq 3 ]

		local cmd
		cmd="$(printf '%s\n' "$output" | grep -m1 'git -C .* show .* diff -u -')"
		[ -n "$cmd" ] || {
			echo "${shape}: refusal printed no discriminator" >&2
			return 1
		}
		# It must run, and it must show the mutation — a command that runs and
		# reports "no difference" would be just as useless. Run from a cwd that
		# is NOT the repo root: a printed command that only works from one
		# directory is a dead end at exactly the wrong moment.
		run bash -c "cd / && ${cmd}"
		[ "$status" -eq 1 ] # diff exits 1 when the files differ, which they must
		[[ "$output" == *"-real_line=1"* ]]
		[[ "$output" == *"+real_line=0"* ]]
		[[ "$output" != *"exists on disk, but not in"* ]]
		[[ "$output" != *"fatal:"* ]]
	done
}

# ───────────────────────────────────────────────────────────────────────────
# The sentinel's contents. It has to be enough to act on without the harness.
# ───────────────────────────────────────────────────────────────────────────

@test "the armed sentinel names the mutation, the file, the backup path and the pid" {
	write_proof '
		ms_guard_init demo-proof target.sh
		ms_guard_arm "M4 the specific thing"
		cp "$MS_SENTINEL" "'"${SANDBOX}"'/captured"
		ms_guard_finish
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 0 ]
	local s="${SANDBOX}/captured"
	grep -q '^mutation-proof: *demo-proof$' "$s"
	grep -q '^label: *M4 the specific thing$' "$s"
	grep -q '^file: *target.sh$' "$s"
	grep -q '^pid: *[0-9][0-9]*$' "$s"
	grep -q '^pid_starttime: *[0-9][0-9]*$' "$s"
	grep -q '^backup_dir: */' "$s"
	grep -q '^commit: *[0-9a-f]\{40\}$' "$s"
	# the pristine line carries both discriminators a manual restore needs
	grep -q '^pristine:.*sha256=[0-9a-f]\{64\} mode=[0-7]\{3,4\}$' "$s"
}

@test "the sentinel name is unique per proof, so one restore cannot clear another's" {
	write_proof '
		ms_guard_init alpha-proof target.sh
		echo "$MS_SENTINEL"
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *".alpha-proof-mutation-in-progress" ]]
	# A sentinel belonging to a DIFFERENT proof must not block this one.
	printf 'pid: %s\n' "$DEAD_PID" >"$(SENTINEL_OF beta-proof)"
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 0 ]
}

# ───────────────────────────────────────────────────────────────────────────
# Restore verification: content AND mode, both directions.
# ───────────────────────────────────────────────────────────────────────────

@test "restore returns content and mode, and verification passes on a clean restore" {
	write_proof '
		ms_guard_init demo-proof target.sh
		ms_guard_arm "M1"
		# The exact shape that drops the +x bit: rewrite via a tempfile and mv.
		# `cp` back would restore the bytes and leave the mode at 644.
		sed "s/real_line=1/real_line=0/" target.sh > target.sh.tmp
		mv target.sh.tmp target.sh
		ms_assert_mutated target.sh
		[ "$(stat -c %a target.sh)" != "755" ] || { echo "premise broken: mv kept the mode"; exit 9; }
		ms_guard_finish
		echo "restored mode=$(stat -c %a target.sh)"
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"restored mode=755"* ]]
	[ "$(stat -c '%a' "${SANDBOX}/target.sh")" = "755" ]
	# Scoped to the guarded path — see the note in the clean-tree test above.
	# A mode-only diff shows here as ' M' with an identical blob, which is
	# precisely the dangling change a content-only check reports as restored.
	run git -C "$SANDBOX" status --porcelain -- target.sh
	[ -z "$output" ]
}

@test "verification FAILS on mode-only drift, which sha256 alone cannot see" {
	write_proof '
		ms_guard_init demo-proof target.sh
		ms_guard_arm "M1"
		chmod 644 target.sh          # content untouched; sha256 is identical
		if ms_guard_verify; then echo "MODE DRIFT MISSED"; exit 9; fi
		echo CAUGHT
		chmod 755 target.sh
		ms_guard_finish
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *CAUGHT* ]]
	[[ "$output" == *"RESTORE FAILED (mode)"* ]]
	[[ "$output" == *"invisible to a content check"* ]]
	[[ "$output" != *"MODE DRIFT MISSED"* ]]
}

@test "verification FAILS on content drift" {
	write_proof '
		ms_guard_init demo-proof target.sh
		ms_guard_arm "M1"
		printf "extra\n" >> target.sh
		if ms_guard_verify; then echo "CONTENT DRIFT MISSED"; exit 9; fi
		echo CAUGHT
		ms_guard_finish
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *CAUGHT* ]]
	[[ "$output" == *"RESTORE FAILED (content)"* ]]
	[[ "$output" != *"CONTENT DRIFT MISSED"* ]]
}

@test "a FAILED restore keeps the sentinel, so nothing records a clean tree that is not" {
	write_proof '
		ms_guard_init demo-proof target.sh
		ms_guard_arm "M1"
		# Corrupt the pristine copy so restore cannot possibly succeed.
		printf "corrupt\n" > "${MS_BACKUP_DIR}/target.sh"
		if ms_guard_restore; then echo "RESTORE CLAIMED SUCCESS"; exit 9; fi
		[ -f "$MS_SENTINEL" ] || { echo "SENTINEL WAS CLEARED ON A FAILED RESTORE"; exit 9; }
		echo KEPT
		exit 0
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *KEPT* ]]
	[[ "$output" == *"SENTINEL KEPT"* ]]
	[[ "$output" != *"SENTINEL WAS CLEARED"* ]]
	[ -f "$(SENTINEL_OF demo-proof)" ]
}

@test "a SUCCESSFUL restore clears the sentinel" {
	# The negative of the test above. A verifier that always failed, or a
	# restore that never cleared, would satisfy that one and break the gate.
	write_proof '
		ms_guard_init demo-proof target.sh
		ms_guard_arm "M1"
		ms_sed target.sh "s/real_line=1/real_line=0/"
		ms_guard_restore || { echo "CLEAN RESTORE REPORTED FAILURE"; exit 9; }
		[ ! -e "$MS_SENTINEL" ] || { echo "SENTINEL SURVIVED A GOOD RESTORE"; exit 9; }
		echo CLEARED
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *CLEARED* ]]
	[ ! -e "$(SENTINEL_OF demo-proof)" ]
}

@test "ms_guard_report prints a sha256 and a mode for every guarded file" {
	write_proof '
		ms_guard_init demo-proof target.sh
		ms_guard_report
		ms_guard_finish
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 0 ]
	[[ "$output" =~ [0-9a-f]{64}[[:space:]]+mode=755[[:space:]]+target\.sh ]]
}

# ───────────────────────────────────────────────────────────────────────────
# "Assert the mutation applied" — and tell the two silent failures apart.
# ───────────────────────────────────────────────────────────────────────────

@test "ms_sed ABORTS when the pattern no longer matches (a no-op that exits 0)" {
	write_proof '
		ms_guard_init demo-proof target.sh
		ms_guard_arm "M1"
		ms_sed target.sh "s/this_pattern_is_gone/x/"
		echo "REACHED THE CHECK WITH NO MUTATION APPLIED"
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 2 ]
	[[ "$output" == *"changed NOTHING"* ]]
	[[ "$output" == *"would run against CORRECT code and pass"* ]]
	[[ "$output" != *"REACHED THE CHECK"* ]]
}

@test "ms_sed ABORTS on a sed SYNTAX error with a different message from a no-op" {
	# An unescaped | inside s|…|…| is the specific one that has bitten here, and
	# it reads identically to "the guard did not fire" if sed's status is
	# dropped. The message must not be the no-op message.
	write_proof '
		ms_guard_init demo-proof target.sh
		ms_guard_arm "M1"
		ms_sed target.sh "s|real_line|a|b|"
		echo "REACHED THE CHECK"
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 2 ]
	[[ "$output" == *"REJECTED the mutation program"* ]]
	[[ "$output" == *"NOT 'the guard did not fire'"* ]]
	[[ "$output" != *"changed NOTHING"* ]]
	[[ "$output" != *"REACHED THE CHECK"* ]]
}

@test "ms_sed SUCCEEDS on a pattern that matches" {
	# The negative. Both aborts above are satisfied by an ms_sed that always
	# aborts, which would take every mutation proof offline while staying green.
	write_proof '
		ms_guard_init demo-proof target.sh
		ms_guard_arm "M1"
		ms_sed target.sh "s/real_line=1/real_line=0/"
		grep -q "real_line=0" target.sh && echo APPLIED
		ms_guard_finish
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *APPLIED* ]]
}

@test "ms_assert_mutated ABORTS when a non-sed mutation changed nothing" {
	write_proof '
		ms_guard_init demo-proof target.sh
		ms_guard_arm "M1"
		awk "{ print }" target.sh > target.sh.tmp && mv target.sh.tmp target.sh
		ms_assert_mutated target.sh
		echo "REACHED THE CHECK"
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 2 ]
	[[ "$output" == *"byte-identical"* ]]
	[[ "$output" != *"REACHED THE CHECK"* ]]
}

@test "ms_sed ARMS the sentinel itself, so a call site cannot forget" {
	# The rail has to be enforced, not remembered. A mutation applied with no
	# sentinel on disk leaves nothing behind when the run is SIGKILLed — which
	# is the entire hole this helper exists to close.
	write_proof '
		ms_guard_init demo-proof target.sh
		[ ! -e "$MS_SENTINEL" ] || { echo "armed too early"; exit 9; }
		ms_sed target.sh "s/real_line=1/real_line=0/"
		[ -f "$MS_SENTINEL" ] || { echo "MUTATION APPLIED WITH NO SENTINEL"; exit 9; }
		grep -q "^label:.*real_line" "$MS_SENTINEL" || { echo "label does not name the mutation"; exit 9; }
		echo AUTO-ARMED
		ms_guard_finish
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *AUTO-ARMED* ]]
	[[ "$output" != *"MUTATION APPLIED WITH NO SENTINEL"* ]]
}

@test "ms_sed does not stamp over a caller's explicit label" {
	# Auto-arming must not cost the better diagnostic. "M4 the specific thing"
	# tells you which mutation leaked; "target.sh: s/a/b/" does not.
	write_proof '
		ms_guard_init demo-proof target.sh
		ms_guard_arm "M4 the specific thing"
		ms_sed target.sh "s/real_line=1/real_line=0/"
		grep -q "^label: *M4 the specific thing$" "$MS_SENTINEL" || { echo "LABEL LOST"; exit 9; }
		echo KEPT
		ms_guard_finish
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *KEPT* ]]
	[[ "$output" != *"LABEL LOST"* ]]
}

@test "ms_assert_mutated ABORTS when the mutation ran with no sentinel armed" {
	# It runs after the fact, so it cannot arm on the caller's behalf — by then
	# a SIGKILL would already have leaked. Unarmed here is a harness defect.
	write_proof '
		ms_guard_init demo-proof target.sh
		sed -i "s/real_line=1/real_line=0/" target.sh
		ms_assert_mutated target.sh
		echo "REACHED THE CHECK"
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 2 ]
	[[ "$output" == *"NO sentinel armed"* ]]
	[[ "$output" != *"REACHED THE CHECK"* ]]
}

@test "the EXIT trap does not rewrite a proof's verdict" {
	# A failing last command in a bash EXIT trap replaces the script's exit
	# status. That has already turned an 8/8-green run in this repo into a
	# reported failure. The proof's own count is what the gate reads.
	write_proof '
		ms_guard_init demo-proof target.sh
		trap ms_guard_on_exit EXIT
		ms_sed target.sh "s/real_line=1/real_line=0/"
		echo "1 unproven"
		exit 1
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 1 ]
	[[ "$output" == *"1 unproven"* ]]
	[ ! -e "$(SENTINEL_OF demo-proof)" ]
}

@test "the EXIT trap passes a clean run through as 0" {
	# The negative of both trap tests. A trap that always promoted, or always
	# failed, would satisfy one of them and break every proof.
	write_proof '
		ms_guard_init demo-proof target.sh
		trap ms_guard_on_exit EXIT
		ms_sed target.sh "s/real_line=1/real_line=0/"
		echo "15 proven"
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"15 proven"* ]]
}

@test "a PASSING proof whose restore FAILED does not exit 0" {
	# Otherwise the &&-chain carries on into the next proof with a mutated file
	# on disk and calls the whole thing green — the exact way a leaked mutation
	# reaches the next run.
	write_proof '
		ms_guard_init demo-proof target.sh
		trap ms_guard_on_exit EXIT
		ms_sed target.sh "s/real_line=1/real_line=0/"
		printf "corrupt\n" > "${MS_BACKUP_DIR}/target.sh"
		echo "15 proven"
		exit 0
	'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 2 ]
	[[ "$output" == *"15 proven"* ]]
	[[ "$output" == *"RESTORE FAILED"* ]]
	# and the marker survives, so the next run refuses rather than compounding
	[ -f "$(SENTINEL_OF demo-proof)" ]
}

@test "ms_guard_init refuses to guard a file it cannot find" {
	# A guarded path that does not resolve would otherwise produce an empty
	# backup and a restore that silently does nothing.
	write_proof 'ms_guard_init demo-proof no/such/file.sh'
	run bash "${SANDBOX}/proof.sh"
	[ "$status" -eq 2 ]
	[[ "$output" == *"guarded file not found"* ]]
}

# ───────────────────────────────────────────────────────────────────────────
# Fleet-wide invariants, derived from disk. A proof that lands tomorrow is
# covered without editing this file.
# ───────────────────────────────────────────────────────────────────────────

@test "every mutation proof on disk sources the shared sentinel helper" {
	# "Assert the mechanism is present before testing it." A correct test can
	# run happily against a tree where the thing under test was never wired in.
	local p missing="" n=0
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		n=$((n + 1))
		grep -q 'helpers/mutation-sentinel.bash' "$p" || missing="${missing} ${p}"
	done < <(cd "$REPO_ROOT" && ls -1 test/*-mutation-proof.sh)

	[ "$n" -gt 0 ] || {
		echo "no test/*-mutation-proof.sh found — refusing a vacuous pass" >&2
		return 1
	}
	[ -z "$missing" ] || {
		echo "mutation proofs not using the shared sentinel rail:${missing}" >&2
		echo "" >&2
		echo "Each one mutates a REAL file per CONTRACT §7b. Without the rail, a" >&2
		echo "SIGKILL leaves that file mutated and the next proof in the &&-chain" >&2
		echo "reads it as a regression." >&2
		return 1
	}
}

@test "every mutation proof declares a sentinel name UNIQUE to it" {
	# A shared name is worse than none: proof A's restore deletes proof B's
	# marker, B then sees a clean repo, reads its own leaked mutation as a real
	# failure, and the refusal never fires. `.mutation-in-progress` (generic)
	# was live in this tree and is exactly that bug.
	local p name seen="" dupes="" n=0
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		n=$((n + 1))
		name="$(sed -n 's/.*ms_guard_init[[:space:]]\{1,\}\([a-z0-9-]\{1,\}\).*/\1/p' \
			"${REPO_ROOT}/${p}" | head -1)"
		[ -n "$name" ] || {
			echo "${p}: no ms_guard_init <name> found" >&2
			return 1
		}
		case " ${seen} " in
		*" ${name} "*) dupes="${dupes} ${name}(${p})" ;;
		esac
		seen="${seen} ${name}"
	done < <(cd "$REPO_ROOT" && ls -1 test/*-mutation-proof.sh)

	[ "$n" -gt 0 ] || {
		echo "no proofs discovered — refusing a vacuous pass" >&2
		return 1
	}
	[ -z "$dupes" ] || {
		echo "duplicate sentinel names:${dupes}" >&2
		return 1
	}
	# And the generic name specifically must not come back.
	[[ " ${seen} " != *" mutation "* ]]
}

@test "every sentinel a proof can mint is covered by .gitignore" {
	# The suffix is load-bearing: `*mutation-in-progress` is already in
	# .gitignore, so a sentinel minted through the helper is ignored the day it
	# is named. Three sentinels in this tree used a `.RUNNING` suffix that the
	# glob does not match — one `git add -A` during an interrupted run would
	# have committed a marker saying the tree is mutated.
	local p name n=0 bad="" handrolled=""
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		n=$((n + 1))
		name="$(sed -n 's/.*ms_guard_init[[:space:]]\{1,\}\([a-z0-9-]\{1,\}\).*/\1/p' \
			"${REPO_ROOT}/${p}" | head -1)"
		# An EMPTY name would render as `.-mutation-in-progress`, which the glob
		# happily matches — the check would pass while proving nothing. This is
		# the assertion-true-of-the-wrong-thing shape, and it was live in the
		# first draft of this very test.
		[ -n "$name" ] || {
			echo "${p}: no ms_guard_init <name>; the ignore check would be vacuous" >&2
			return 1
		}
		git -C "$REPO_ROOT" check-ignore -q ".${name}-mutation-in-progress" ||
			bad="${bad} .${name}-mutation-in-progress"
		# A hand-rolled sentinel path bypasses the helper's naming entirely, so
		# the check above would still pass while an unignored marker sat in the
		# tree. Three proofs used a `.RUNNING` suffix the glob does not match.
		grep -qE '^[[:space:]]*SENTINEL=|\.RUNNING' "${REPO_ROOT}/${p}" &&
			handrolled="${handrolled} ${p}"
	done < <(cd "$REPO_ROOT" && ls -1 test/*-mutation-proof.sh)

	[ "$n" -gt 0 ] || {
		echo "no proofs discovered — refusing a vacuous pass" >&2
		return 1
	}
	[ -z "$bad" ] || {
		echo "sentinels not covered by .gitignore:${bad}" >&2
		return 1
	}
	[ -z "$handrolled" ] || {
		echo "proofs still declaring a sentinel path by hand:${handrolled}" >&2
		echo "Use ms_guard_init; its name falls under the existing glob." >&2
		return 1
	}
}

@test "MUTATION: a proof that drops the rail is caught by the fleet-wide check" {
	# Proves the three checks above can actually go red. Each is an
	# absence-of-bad assertion, and those are trivially satisfied by nothing
	# being present — the failure mode that made a `no wildcard verbs` guard
	# pass hardest right after the grant it guarded was deleted.
	local scratch="${BATS_TEST_TMPDIR}/fleet"
	mkdir -p "${scratch}/test"
	printf '#!/usr/bin/env bash\nsource test/helpers/mutation-sentinel.bash\nms_guard_init alpha x\n' \
		>"${scratch}/test/alpha-mutation-proof.sh"
	# (a) a proof with no rail at all
	printf '#!/usr/bin/env bash\n# no rail here\n' \
		>"${scratch}/test/beta-mutation-proof.sh"
	run grep -L 'helpers/mutation-sentinel.bash' \
		"${scratch}/test/alpha-mutation-proof.sh" "${scratch}/test/beta-mutation-proof.sh"
	[[ "$output" == *"beta-mutation-proof.sh"* ]]
	[[ "$output" != *"alpha-mutation-proof.sh"* ]]

	# (b) two proofs sharing one sentinel name
	printf '#!/usr/bin/env bash\nsource test/helpers/mutation-sentinel.bash\nms_guard_init alpha y\n' \
		>"${scratch}/test/beta-mutation-proof.sh"
	local names
	names="$(sed -n 's/.*ms_guard_init[[:space:]]\{1,\}\([a-z0-9-]\{1,\}\).*/\1/p' \
		"${scratch}"/test/*-mutation-proof.sh)"
	[ "$(printf '%s\n' "$names" | sort -u | wc -l)" -lt "$(printf '%s\n' "$names" | wc -l)" ]
}
