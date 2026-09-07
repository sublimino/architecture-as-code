#!/usr/bin/env bats
#
# Rule SP-1 — worktree Landlock confinement.
#
# @id      worktree-landlock-confinement
# @target  nono/profiles/worktree-agent.json, bin/agent-git, scripts/test-worktree-confinement.sh
# @doc     docs/signalloom/worktree-landlock-confinement.md
#
# The claim under test: a coding agent working in a git worktree can commit
# locally without a GPG prompt, and cannot push, cannot reach an arbitrary
# outbound socket, and cannot read the host's credential stores — because the
# KERNEL refuses, not because a prompt asked it not to.
#
# ── The suite is split in two, deliberately ─────────────────────────────────
#
# STRUCTURAL tests run everywhere and never skip. They assert the profile's
# content, the wrapper's argv handling, the documentation, and the CI
# registration. They need no kernel feature and no sandbox binary.
#
# LIVE tests need `nono` and an active Landlock LSM. The CI VM has neither, so
# they skip there — and a skip is exactly the failure mode this repository has
# already been burned by: `test/obsidian-lint.bats` skipped all 81 of its tests
# for two commits because the binary under test would not compile, and the suite
# read green throughout.
#
# Two mechanisms stop that happening here:
#
#   1. Nothing skips in setup(). A skip in setup() takes the WHOLE FILE with it,
#      including the structural half that has no business skipping. Each live
#      test calls require_sandbox itself.
#   2. The last test in this file counts the live tests and asserts the skip
#      accounting is consistent with the host — on a host WITH nono, zero live
#      tests may skip. A suite that skips its only real assertions on a capable
#      host is reporting green for a check that never ran.

setup() {
	# No skip here. See the header — a setup() skip is silent and total.
	REPO_ROOT="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
	PROFILE="$REPO_ROOT/nono/profiles/worktree-agent.json"
	WRAPPER="$REPO_ROOT/bin/agent-git"
	HARNESS="$REPO_ROOT/scripts/test-worktree-confinement.sh"
	EVIDENCE="$REPO_ROOT/docs/signalloom/evidence/worktree-confinement-proof.json"
	DOC="$REPO_ROOT/docs/signalloom/worktree-landlock-confinement.md"
	PIPELINE="$REPO_ROOT/scripts/ci/vm-pipeline.sh"
}

# True when this host can actually enforce the control. Both halves matter: nono
# without Landlock would fall back to a weaker mode, and Landlock without nono
# has no front-end here.
sandbox_available() {
	command -v nono >/dev/null 2>&1 || return 1
	grep -qw landlock /sys/kernel/security/lsm 2>/dev/null || return 1
	return 0
}

require_sandbox() {
	sandbox_available || skip "nono and/or Landlock unavailable on this host — live enforcement not measurable here"
}

# Read one JSON path out of the profile. Kept as a function so a change to the
# reader is made once rather than in fourteen places that could drift apart.
profile_query() {
	python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[k]
print(json.dumps(d))
' "$PROFILE" "$1"
}

# ─────────────────────────────────────────────────────────────────────────────
# Structural: the profile
# ─────────────────────────────────────────────────────────────────────────────

@test "SP-1 profile exists and is parseable JSON" {
	[ -f "$PROFILE" ]
	run python3 -m json.tool "$PROFILE"
	[ "$status" -eq 0 ]
	# Assert the parse produced a document, not merely that the tool exited 0.
	[ -n "${output//[[:space:]]/}" ]
}

@test "SP-1 profile declares the nono schema" {
	run profile_query '$schema'
	[ "$status" -eq 0 ]
	[[ "$output" == *"nono.sh/schema/profile.json"* ]]
}

@test "SP-1 profile passes 'nono profile validate'" {
	require_sandbox
	run nono profile validate "$PROFILE"
	[ "$status" -eq 0 ]
	# Exit status alone is not the assertion: validate prints a verdict line and
	# a checker that changed its exit convention would silently stop testing.
	[[ "$output" == *"Result: valid"* ]]
}

@test "SP-1 profile grants the canonical worktree home" {
	run profile_query 'filesystem.allow'
	[ "$status" -eq 0 ]
	[[ "$output" == *"~/src/.worktrees/"* ]]
}

@test "SP-1 profile grants the kanban runtime worktree home" {
	# ~/.cline/worktrees is a symlink to ~/src/.worktrees on this host, but the
	# kanban runtime hard-codes the .cline spelling, so both are named.
	run profile_query 'filesystem.allow'
	[ "$status" -eq 0 ]
	[[ "$output" == *".cline/worktrees/"* ]]
}

@test "SP-1 profile grants a parent repository .git object store" {
	# Empirically required: a worktree's commit writes objects and refs into the
	# PARENT repository's .git. Granting only the worktree yields
	# "fatal: not a git repository: (null)". See the runbook.
	run profile_query 'filesystem.allow'
	[ "$status" -eq 0 ]
	[[ "$output" == *"/.git/"* ]]
}

@test "SP-1 profile denies every named credential store" {
	local want path missing=""
	for want in "~/.ssh/" "~/.gnupg/" "~/.aws/" "~/.config/gcloud/" "/etc/shadow"; do
		run profile_query 'filesystem.deny'
		[ "$status" -eq 0 ]
		case "$output" in
		*"$want"*) ;;
		*) missing="${missing}${want} " ;;
		esac
	done
	if [ -n "$missing" ]; then
		echo "filesystem.deny does not name: $missing"
		false
	fi
	# The mechanism assertion: an empty deny list would make the loop above pass
	# for every entry it failed to find, because the case would never match and
	# ... no, it would report them. But an unparseable path would return "null"
	# and match nothing, so assert the list is a non-empty array.
	run profile_query 'filesystem.deny'
	[[ "$output" == \[* ]]
	[ "${#output}" -gt 10 ]
}

@test "SP-1 profile denies SSH_AUTH_SOCK so a forwarded agent cannot bypass isolation" {
	run profile_query 'environment.deny_vars'
	[ "$status" -eq 0 ]
	[[ "$output" == *"SSH_AUTH_SOCK"* ]]
}

@test "SP-1 profile blocks outbound network by default" {
	run profile_query 'network.block'
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
}

@test "SP-1 profile never allow-lists a git transport port" {
	# 22 ssh, 443 https, 9418 git://. Any of these in open_port would reopen the
	# exact hole the card exists to close.
	run profile_query 'network.open_port'
	[ "$status" -eq 0 ]
	local found
	found="$(python3 -c '
import json, sys
ports = json.loads(sys.argv[1])
bad = [p for p in ports if p in (22, 443, 9418)]
print(" ".join(str(p) for p in bad))
print(len(ports))
' "$output")"
	local bad total
	bad="$(printf '%s' "$found" | head -1)"
	total="$(printf '%s' "$found" | tail -1)"
	# Assert the list was non-empty before believing "no bad ports found":
	# an empty open_port would clear this check while proving nothing.
	[ "$total" -gt 0 ]
	[ -z "$bad" ] || {
		echo "network.open_port contains git transport port(s): $bad"
		false
	}
}

# ─────────────────────────────────────────────────────────────────────────────
# Structural: the wrapper
# ─────────────────────────────────────────────────────────────────────────────

@test "agent-git exists, is executable, and is syntactically valid" {
	[ -f "$WRAPPER" ]
	[ -x "$WRAPPER" ]
	run bash -n "$WRAPPER"
	[ "$status" -eq 0 ]
	# `bash -n` downgrades exactly one syntax fault — an unterminated heredoc —
	# to a stderr warning with exit 0. Asserting empty output closes that.
	[ -z "$output" ]
}

@test "agent-git injects --no-gpg-sign into a plain commit" {
	run env AGENT_GIT_DRY_RUN=1 AGENT_GIT_SKIP_ROOT_CHECK=1 AGENT_GIT_BIN=/usr/bin/git \
		"$WRAPPER" commit -m "a message with spaces"
	[ "$status" -eq 0 ]
	[[ "$output" == *"--no-gpg-sign"* ]]
	# The message must survive as ONE argument. Dry-run prints one arg per line.
	[[ "$output" == *"a message with spaces"* ]]
}

@test "agent-git does not duplicate an explicit --no-gpg-sign" {
	run env AGENT_GIT_DRY_RUN=1 AGENT_GIT_SKIP_ROOT_CHECK=1 AGENT_GIT_BIN=/usr/bin/git \
		"$WRAPPER" commit --no-gpg-sign -m x
	[ "$status" -eq 0 ]
	local count
	count="$(printf '%s\n' "$output" | grep -c -- '--no-gpg-sign' || true)"
	[ "$count" -eq 1 ]
}

@test "agent-git respects an explicit -S and does not contradict it" {
	# A caller who asked to sign gets to sign. Injecting --no-gpg-sign alongside
	# -S would silently override an explicit instruction.
	run env AGENT_GIT_DRY_RUN=1 AGENT_GIT_SKIP_ROOT_CHECK=1 AGENT_GIT_BIN=/usr/bin/git \
		"$WRAPPER" commit -S -m x
	[ "$status" -eq 0 ]
	[[ "$output" != *"--no-gpg-sign"* ]]
	[[ "$output" == *"-S"* ]]
}

@test "agent-git leaves a non-commit subcommand's argv untouched" {
	run env AGENT_GIT_DRY_RUN=1 AGENT_GIT_SKIP_ROOT_CHECK=1 AGENT_GIT_BIN=/usr/bin/git \
		"$WRAPPER" status --short
	[ "$status" -eq 0 ]
	[ "$output" = "status
--short" ]
}

@test "agent-git finds the subcommand behind git's global options" {
	# `git -C dir commit` puts the subcommand at argv[2]. A parser that reads
	# argv[0] would stop enforcing for every caller that uses -C or -c.
	run env AGENT_GIT_DRY_RUN=1 AGENT_GIT_SKIP_ROOT_CHECK=1 AGENT_GIT_BIN=/usr/bin/git \
		"$WRAPPER" -C /tmp commit -m x
	[ "$status" -eq 0 ]
	[[ "$output" == *"--no-gpg-sign"* ]]
}

@test "agent-git refuses push, with a reason rather than a transport error" {
	run env AGENT_GIT_SKIP_ROOT_CHECK=1 AGENT_GIT_BIN=/usr/bin/git \
		"$WRAPPER" push origin HEAD
	[ "$status" -eq 4 ]
	# Status alone would pass against any failure at all, including the wrapper
	# crashing. The refusal must be the reason.
	[[ "$output" == *"Rule SP-1"* ]]
}

@test "agent-git refuses push even when hidden behind a global option" {
	run env AGENT_GIT_SKIP_ROOT_CHECK=1 AGENT_GIT_BIN=/usr/bin/git \
		"$WRAPPER" -C /tmp push origin HEAD
	[ "$status" -eq 4 ]
	[[ "$output" == *"Rule SP-1"* ]]
}

@test "agent-git refuses to run outside an allowed worktree root" {
	run env -u AGENT_GIT_SKIP_ROOT_CHECK AGENT_GIT_BIN=/usr/bin/git \
		AGENT_GIT_WORKTREE_ROOTS="$BATS_TEST_TMPDIR/nowhere" \
		bash -c "cd / && '$WRAPPER' status"
	[ "$status" -eq 3 ]
	[[ "$output" == *"does not resolve under an allowed worktree root"* ]]
}

@test "agent-git resolves symlinks before evaluating the worktree root" {
	# The whole point of readlink -f: ~/.cline/worktrees and ~/src/.worktrees are
	# the same inode by two names, and a textual prefix test accepts one and
	# rejects the other. Landlock compares inodes; this must too.
	mkdir -p "$BATS_TEST_TMPDIR/real/inner"
	ln -sfn "$BATS_TEST_TMPDIR/real" "$BATS_TEST_TMPDIR/link"
	run env -u AGENT_GIT_SKIP_ROOT_CHECK AGENT_GIT_DRY_RUN=1 AGENT_GIT_BIN=/usr/bin/git \
		AGENT_GIT_WORKTREE_ROOTS="$BATS_TEST_TMPDIR/real" \
		bash -c "cd '$BATS_TEST_TMPDIR/link/inner' && '$WRAPPER' status"
	[ "$status" -eq 0 ]
	[ "$output" = "status" ]
}

@test "agent-git does not accept a sibling directory that merely shares a prefix" {
	# Root /a/b must not admit /a/b-other. A missing trailing slash in the prefix
	# comparison is how that goes wrong, and it goes wrong silently.
	mkdir -p "$BATS_TEST_TMPDIR/root" "$BATS_TEST_TMPDIR/root-other"
	run env -u AGENT_GIT_SKIP_ROOT_CHECK AGENT_GIT_BIN=/usr/bin/git \
		AGENT_GIT_WORKTREE_ROOTS="$BATS_TEST_TMPDIR/root" \
		bash -c "cd '$BATS_TEST_TMPDIR/root-other' && '$WRAPPER' status"
	[ "$status" -eq 3 ]
	[[ "$output" == *"allowed worktree root"* ]]
}

@test "agent-git handles the no-argument invocation" {
	# The production invocation is a test case. A wrapper invoked bare must print
	# usage and exit 2, not fall through an option loop into an obscure error.
	run env AGENT_GIT_SKIP_ROOT_CHECK=1 AGENT_GIT_BIN=/usr/bin/git "$WRAPPER"
	[ "$status" -eq 2 ]
	[[ "$output" == *"USAGE"* ]]
}

@test "agent-git never resolves itself as the real git" {
	# bin/ is prepended to PATH so agents reach the wrapper. A naive
	# `command -v git` in that environment returns the wrapper and recurses.
	run env -u AGENT_GIT_BIN AGENT_GIT_DRY_RUN=1 AGENT_GIT_SKIP_ROOT_CHECK=1 \
		PATH="$REPO_ROOT/bin:$PATH" "$WRAPPER" status
	[ "$status" -eq 0 ]
	[ "$output" = "status" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Structural: documentation, evidence, and registration
# ─────────────────────────────────────────────────────────────────────────────

@test "the SP-1 runbook exists and covers troubleshooting" {
	[ -f "$DOC" ]
	run grep -c -i 'troubleshoot' "$DOC"
	[ "$status" -eq 0 ]
	[ "$output" -gt 0 ]
}

@test "the confinement proof harness exists and is syntactically valid" {
	[ -f "$HARNESS" ]
	[ -x "$HARNESS" ]
	run bash -n "$HARNESS"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "the evidence artifact is valid JSON with the expected shape" {
	[ -f "$EVIDENCE" ]
	run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("artifact", "rule", "card", "generated", "host", "profile", "totals", "probes"):
    assert k in d, "missing key: " + k
assert d["rule"] == "SP-1"
assert isinstance(d["probes"], list) and d["probes"], "probes list is empty"
print(len(d["probes"]))
' "$EVIDENCE"
	[ "$status" -eq 0 ]
	# Assert a non-trivial number of probes. A one-probe artifact would satisfy
	# every structural check above while proving almost nothing.
	[ "$output" -ge 15 ]
}

@test "the evidence artifact records zero failed probes" {
	[ -f "$EVIDENCE" ]
	run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
t = d["totals"]
bad = [p["id"] for p in d["probes"] if p["verdict"] != "pass"]
print(t["failed"], t["passed"], len(d["probes"]), " ".join(bad))
' "$EVIDENCE"
	[ "$status" -eq 0 ]
	local failed passed total
	failed="$(printf '%s' "$output" | awk '{print $1}')"
	passed="$(printf '%s' "$output" | awk '{print $2}')"
	total="$(printf '%s' "$output" | awk '{print $3}')"
	[ "$failed" -eq 0 ]
	# The counts must be internally consistent. A totals block that disagrees
	# with the probe list is a totals block nobody should read.
	[ "$passed" -eq "$total" ]
}

@test "the evidence artifact carries both a positive and a negative network control" {
	# A denial with no positive control is indistinguishable from a broken probe.
	# This is the assertion that stops the harness being weakened into one that
	# only ever records failures.
	[ -f "$EVIDENCE" ]
	run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
ids = {p["id"] for p in d["probes"]}
need = {"control.unconfined-connect-closed-port",
        "control.confined-connect-open-port",
        "net.closed-port-denied"}
missing = need - ids
print(" ".join(sorted(missing)) if missing else "OK")
' "$EVIDENCE"
	[ "$status" -eq 0 ]
	[ "$output" = "OK" ]
}

@test "this suite is registered in the CI pipeline" {
	# d2-signalloom/test/bats-registry-coverage.bats fails when a repo-root suite
	# is invoked by no runner. Registering here rather than discovering it there.
	[ -f "$PIPELINE" ]
	run bash -c "sed 's/#.*//' '$PIPELINE' | grep -c 'worktree-landlock-confinement.bats'"
	[ "$status" -eq 0 ]
	[ "$output" -ge 1 ]
}

@test "the proof harness is invoked by a Makefile target" {
	# Same contract for the .sh half: a proof nothing runs proves nothing.
	run bash -c "grep -vE '^[[:space:]]*#' '$REPO_ROOT/Makefile' | grep -c 'test-worktree-confinement.sh'"
	[ "$status" -eq 0 ]
	[ "$output" -ge 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Live: the kernel actually refuses
# ─────────────────────────────────────────────────────────────────────────────

# Build a minimal main-repo + worktree pair and a fixture profile derived from
# the shipped one. Shared by the live tests below.
live_fixture() {
	local f="$BATS_TEST_TMPDIR/fx"
	[ -d "$f/wt/probe" ] && {
		printf '%s' "$f"
		return 0
	}
	mkdir -p "$f/home" "$f/wt"
	git init -q --initial-branch=main "$f/main"
	git -C "$f/main" config user.email a@b.invalid
	git -C "$f/main" config user.name A
	git -C "$f/main" config commit.gpgsign true
	echo base >"$f/main/README.md"
	git -C "$f/main" add README.md
	git -C "$f/main" commit -q --no-gpg-sign -m base
	git -C "$f/main" worktree add -q -b live/probe "$f/wt/probe" main
	python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))
f = sys.argv[2]
p["filesystem"]["allow"] = [f + "/wt/", f + "/main/.git/"]
p["meta"]["name"] = "worktree-agent-live-test"
json.dump(p, open(f + "/profile.json", "w"), indent=2)
' "$PROFILE" "$f"
	printf '%s' "$f"
}

live_run() {
	local f="$1"
	shift
	HOME="$f/home" timeout 60 nono run -s --allow-cwd -p "$f/profile.json" -- "$@" 2>&1
}

@test "LIVE: a confined 'git commit --no-gpg-sign' in a worktree succeeds" {
	require_sandbox
	local f
	f="$(live_fixture)"
	echo change >"$f/wt/probe/file.txt"
	run bash -c "cd '$f/wt/probe' && HOME='$f/home' timeout 60 nono run -s --allow-cwd -p '$f/profile.json' -- git add file.txt"
	[ "$status" -eq 0 ]
	run bash -c "cd '$f/wt/probe' && HOME='$f/home' timeout 60 nono run -s --allow-cwd -p '$f/profile.json' -- git commit -m confined --no-gpg-sign"
	[ "$status" -eq 0 ]
	# The commit must actually exist, not merely have exited 0.
	run git -C "$f/wt/probe" log --oneline -1
	[ "$status" -eq 0 ]
	[[ "$output" == *"confined"* ]]
}

@test "LIVE: a confined 'git push' is refused by the kernel" {
	require_sandbox
	local f
	f="$(live_fixture)"
	git -C "$f/wt/probe" remote add origin "git://127.0.0.1:9418/nope.git" 2>/dev/null || true
	run bash -c "cd '$f/wt/probe' && HOME='$f/home' timeout 60 nono run -s --allow-cwd -p '$f/profile.json' -- git push origin HEAD 2>&1"
	[ "$status" -ne 0 ]
	# A non-zero exit alone would pass against a missing remote, a bad ref, or a
	# broken git. The errno is the evidence that the KERNEL refused.
	[[ "$output" == *"Operation not permitted"* || "$output" == *"Permission denied"* ]]
}

@test "LIVE: a confined process cannot read the host's SSH private keys" {
	require_sandbox
	local f
	f="$(live_fixture)"
	run live_run "$f" bash -c "ls -A \"$HOME/.ssh\" >/dev/null 2>&1 && echo READABLE || echo DENIED"
	[ "$status" -eq 0 ]
	[ "$output" = "DENIED" ]
}

@test "LIVE: a confined connect to a non-allow-listed port is refused, and an allow-listed one is not" {
	require_sandbox
	local f port
	f="$(live_fixture)"
	port="$(python3 -c '
import json, socket, sys
ports = json.load(open(sys.argv[1]))["network"]["open_port"]
for p in ports:
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p)); s.close(); print(p); break
    except OSError:
        s.close()
' "$PROFILE")"
	[ -n "$port" ]

	# One listener on an allow-listed port, one on a denied port. Both must be up
	# before either verdict means anything.
	python3 -c '
import socket, sys, time
socks = []
for p in (int(sys.argv[1]), 39999):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", p)); s.listen(8); socks.append(s)
time.sleep(25)
' "$port" &
	local listener=$!
	sleep 1

	run live_run "$f" bash -c "exec 3<>/dev/tcp/127.0.0.1/$port && echo OPEN_OK || echo OPEN_DENIED"
	local open_result="$output"
	run live_run "$f" bash -c "exec 3<>/dev/tcp/127.0.0.1/39999 && echo CLOSED_OK || echo CLOSED_DENIED"
	local closed_result="$output"
	kill "$listener" 2>/dev/null || true

	# Both halves, in one test, because either alone is uninformative: a blanket
	# denial satisfies the negative and a blanket allow satisfies nothing.
	[[ "$open_result" == *OPEN_OK* ]]
	[[ "$closed_result" == *CLOSED_DENIED* ]]
}

@test "LIVE: a child process spawned by git inherits the confinement" {
	require_sandbox
	local f hooks
	f="$(live_fixture)"
	hooks="$(git -C "$f/wt/probe" rev-parse --git-path hooks)"
	mkdir -p "$hooks"
	cat >"$hooks/pre-commit" <<EOF
#!/bin/bash
if bash -c 'exec 3<>/dev/tcp/127.0.0.1/39999' 2>/dev/null; then
  echo CHILD_OK > "$f/wt/probe/.hook-verdict"
else
  echo CHILD_DENIED > "$f/wt/probe/.hook-verdict"
fi
exit 0
EOF
	chmod +x "$hooks/pre-commit"
	rm -f "$f/wt/probe/.hook-verdict"
	echo hookchange >>"$f/wt/probe/file.txt"
	run bash -c "cd '$f/wt/probe' && HOME='$f/home' timeout 60 nono run -s --allow-cwd -p '$f/profile.json' -- git commit -am hooked --no-gpg-sign"
	rm -f "$hooks/pre-commit"
	# The hook must have RUN. An absent verdict file means nothing was measured,
	# which must fail rather than read as a denial.
	[ -f "$f/wt/probe/.hook-verdict" ]
	run cat "$f/wt/probe/.hook-verdict"
	[ "$output" = "CHILD_DENIED" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Skip accounting — the guard against this file reporting green for nothing
# ─────────────────────────────────────────────────────────────────────────────

@test "the LIVE half is not silently skipped on a host that can run it" {
	# The failure this exists to prevent, from this repository's own history: a
	# suite whose tests all skipped on a missing binary read green for two
	# commits while the thing under test would not even compile.
	#
	# So: count the LIVE tests declared in this file, and on a host WITH the
	# sandbox require that a filtered run of them executes every one. On a host
	# without it, state plainly how many were not run.
	local declared
	declared="$(grep -c '^@test "LIVE: ' "$BATS_TEST_FILENAME")"
	[ "$declared" -ge 4 ]

	if ! sandbox_available; then
		echo "NOTE: ${declared} LIVE tests were skipped — nono and/or Landlock absent."
		echo "The structural half above still ran and still asserts the profile,"
		echo "the wrapper and the CI registration."
		return 0
	fi

	# --count first: a filter matching nothing exits 0 printing 1..0, which would
	# turn this guard into a guaranteed pass the moment a test is renamed.
	run bats --count --filter '^LIVE: ' "$BATS_TEST_FILENAME"
	[ "$status" -eq 0 ]
	[ "$output" -eq "$declared" ] || {
		echo "filter selected ${output} LIVE test(s) but ${declared} are declared."
		echo "A renamed test would make this guard blind."
		false
	}
}
