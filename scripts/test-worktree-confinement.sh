#!/usr/bin/env bash
#
# test-worktree-confinement.sh — live-kernel proof harness for Rule SP-1.
#
# @id      test-worktree-confinement
# @doc     docs/signalloom/worktree-landlock-confinement.md
# @target  nono/profiles/worktree-agent.json, bin/agent-git
# @tests   test/worktree-landlock-confinement.bats
#
# Builds a throwaway main-repo + worktree pair, runs every Rule SP-1 claim as a
# probe against the REAL kernel through `nono`, and writes a machine-readable
# verdict to docs/signalloom/evidence/worktree-confinement-proof.json.
#
# ── Why every probe is hermetic ──────────────────────────────────────────────
#
# Not one probe touches the internet. Proving "push is blocked" by failing to
# reach github.com proves nothing: an offline CI VM produces the identical
# failure, and the harness would report a working control on a host where no
# control exists. So the remotes point at LOOPBACK ports and the evidence comes
# from a paired control:
#
#   port 39999  a real listener runs there; it is NOT in the profile's
#               open_port list, so unconfined connect succeeds and confined
#               connect must be refused. That pair is the whole proof.
#   port 31337  also has a listener and IS in open_port. A confined connect
#               must SUCCEED. Without this the suite could pass by the sandbox
#               being a blanket failure rather than a policy.
#
# A negative result with no positive control is indistinguishable from a broken
# probe. This file refuses to report a pass it cannot separate from that.
#
# ── Why the profile is derived rather than used verbatim ─────────────────────
#
# The shipped profile grants ~/src/.worktrees and ~/.cline/worktrees. A fixture
# built there would race the other agents working in that tree. So the harness
# rewrites ONLY filesystem.allow and filesystem.read to point at the fixture,
# and copies filesystem.deny, environment.deny_vars and the entire network block
# VERBATIM from the shipped profile. Every security claim is therefore tested
# against the shipped bytes; only the location of the sandbox's writable island
# is substituted, and test/worktree-landlock-confinement.bats separately asserts
# that the shipped allow-list names the real roots.
#
# Usage:
#   scripts/test-worktree-confinement.sh [--json PATH] [--keep] [--profile PATH]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${REPO_ROOT}/nono/profiles/worktree-agent.json"
EVIDENCE="${REPO_ROOT}/docs/signalloom/evidence/worktree-confinement-proof.json"
KEEP=0

# Landlock port rules are enforced per-port, so these two constants carry the
# whole positive/negative discrimination.
#
# OPEN_PORT is chosen AT RUNTIME from the profile's own network.open_port list,
# picking the first entry nothing is already bound to. Hard-coding it was the
# first implementation and it silently lied: 31337 is in the profile and is also
# Pulse's port on this host, so the harness's own listener failed to bind with
# EADDRINUSE while the "confined connect succeeds" control passed against an
# unrelated daemon. A control that passes because something else happens to be
# listening is not a control. CLOSED_PORT must NOT appear in open_port.
OPEN_PORT=""
readonly CLOSED_PORT=39999

RESULTS=()
FAILED=0
SKIPPED=0

log() { printf '[%s] %s\n' "$(date -u '+%H:%M:%S')" "$*" >&2; }

usage() {
	sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ── JSON emission ────────────────────────────────────────────────────────────
json_escape() { printf '%s' "$1" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))'; }

record() {
	local id="$1" desc="$2" expect="$3" rc="$4" verdict="$5" evidence="$6"
	RESULTS+=("$(printf '{"id":%s,"description":%s,"expectation":%s,"exit_code":%s,"verdict":%s,"evidence":%s}' \
		"$(json_escape "$id")" "$(json_escape "$desc")" "$(json_escape "$expect")" \
		"${rc}" "$(json_escape "$verdict")" "$(json_escape "$evidence")")")
	case "$verdict" in
	fail) FAILED=$((FAILED + 1)) ;;
	skip | inconclusive) SKIPPED=$((SKIPPED + 1)) ;;
	esac
	printf '  %-42s %s\n' "$id" "$verdict" >&2
}

# ── preflight ────────────────────────────────────────────────────────────────
require() {
	local missing=""
	for c in git python3 nono; do command -v "$c" >/dev/null 2>&1 || missing="${missing}${c} "; done
	if [ -n "$missing" ]; then
		echo "MISSING TOOL(S): ${missing}" >&2
		echo "This harness proves a KERNEL control and cannot be simulated. Refusing to" >&2
		echo "report anything rather than emit a green file that means nothing." >&2
		return 1
	fi
	[ -f "$PROFILE" ] || { echo "profile not found: $PROFILE" >&2; return 1; }
	grep -qw landlock /sys/kernel/security/lsm 2>/dev/null || {
		echo "landlock absent from /sys/kernel/security/lsm — no control to prove" >&2
		return 1
	}
	return 0
}

# ── fixture ──────────────────────────────────────────────────────────────────
FIXTURE=""
LISTENER_PIDS=()

cleanup() {
	local p
	for p in ${LISTENER_PIDS[@]+"${LISTENER_PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
	if [ "$KEEP" -eq 0 ] && [ -n "$FIXTURE" ] && [ -d "$FIXTURE" ]; then rm -rf "$FIXTURE"; fi
}
trap cleanup EXIT

# First port in the profile's open_port list that nothing is currently bound to.
# Refuses rather than falling back, because a fallback to a port outside the
# profile would invert the meaning of the control that uses it.
pick_open_port() {
	local candidates port
	candidates="$(python3 -c 'import json,sys; print(" ".join(str(p) for p in json.load(open(sys.argv[1])).get("network",{}).get("open_port",[])))' "$PROFILE")"
	[ -n "$candidates" ] || return 1
	for port in $candidates; do
		if ! ss -lnt "sport = :$port" 2>/dev/null | grep -q LISTEN; then
			printf '%s' "$port"
			return 0
		fi
	done
	return 1
}

start_listener() {
	local port="$1"
	python3 - "$port" <<'PY' &
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(16)
s.settimeout(1.0)
deadline = time.time() + 600
while time.time() < deadline:
    try:
        c, _ = s.accept()
        c.close()
    except socket.timeout:
        pass
    except OSError:
        break
PY
	LISTENER_PIDS+=("$!")
}

build_fixture() {
	FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/crkc-sp1.XXXXXXXX")"
	mkdir -p "$FIXTURE/home" "$FIXTURE/wt" "$FIXTURE/shim" "$FIXTURE/out"

	git init -q --initial-branch=main "$FIXTURE/main"
	git -C "$FIXTURE/main" config user.email agent@example.invalid
	git -C "$FIXTURE/main" config user.name "Confined Agent"
	# The condition this whole card exists under: signing ON by default.
	git -C "$FIXTURE/main" config commit.gpgsign true
	echo base >"$FIXTURE/main/README.md"
	git -C "$FIXTURE/main" add README.md
	git -C "$FIXTURE/main" commit -q --no-gpg-sign -m "fixture base"
	git -C "$FIXTURE/main" worktree add -q -b sp1/probe "$FIXTURE/wt/probe" main

	# A pinentry shim that records its own invocation. Its presence on PATH is
	# what makes "pinentry was never invoked" a measurement rather than an
	# assumption; probe P3 proves the shim itself fires before trusting silence.
	cat >"$FIXTURE/shim/pinentry" <<EOF
#!/bin/sh
echo "invoked \$(date -u +%s)" >> "$FIXTURE/out/pinentry-invoked"
exit 1
EOF
	chmod +x "$FIXTURE/shim/pinentry"
	cp "$FIXTURE/shim/pinentry" "$FIXTURE/shim/pinentry-curses"

	# Derive the runtime profile: security blocks verbatim, paths rewritten.
	python3 - "$PROFILE" "$FIXTURE" >"$FIXTURE/profile.json" <<'PY'
import json, sys
src, fixture = sys.argv[1], sys.argv[2]
p = json.load(open(src))
fs = p.setdefault("filesystem", {})
# Rewritten: where the writable island lives.
# Deliberately NOT {fixture}/outside-src: probe_submodule needs a real path
# outside the island to prove containment against.
fs["allow"] = [f"{fixture}/wt/", f"{fixture}/main/.git/", f"{fixture}/out/"]
fs["read"] = fs.get("read", []) + [f"{fixture}/shim/"]
# Untouched, and that is the point: deny/env/network are the security claims.
p["meta"]["name"] = "worktree-agent-fixture"
p["meta"]["description"] = "DERIVED FROM " + src + " — allow/read rewritten to a fixture; deny, environment and network copied verbatim."
json.dump(p, sys.stdout, indent=2)
PY
	nono profile validate "$FIXTURE/profile.json" >/dev/null 2>&1 || {
		echo "derived profile failed validation" >&2
		return 1
	}
}

# Run a command inside the sandbox. HOME is redirected into the fixture because
# nono writes its own session state under $HOME/.local/state and this harness
# must run from inside an already-sandboxed agent shell where that path is denied.
confined() {
	HOME="$FIXTURE/home" PATH="$FIXTURE/shim:$PATH" \
		timeout 60 nono run -s --allow-cwd -p "$FIXTURE/profile.json" -- "$@" 2>&1
}

confined_diag() {
	HOME="$FIXTURE/home" PATH="$FIXTURE/shim:$PATH" \
		timeout 60 nono run -s --allow-cwd --diagnostics-json -p "$FIXTURE/profile.json" -- "$@" 2>&1 >/dev/null
}

tcp_probe() {
	printf 'exec 3<>/dev/tcp/127.0.0.1/%s && echo TCP_OK' "$1"
}

# ── probes ───────────────────────────────────────────────────────────────────
probe_controls() {
	local out rc
	# Unconfined connect to the closed port. If this fails the listener is dead
	# and every "denied" verdict below would be meaningless.
	out="$(bash -c "$(tcp_probe "$CLOSED_PORT")" 2>&1)" && rc=0 || rc=$?
	if [ "$rc" -eq 0 ]; then
		record "control.unconfined-connect-closed-port" \
			"unconfined connect to 127.0.0.1:${CLOSED_PORT} succeeds" \
			"exit 0, TCP_OK" "$rc" "pass" "$out"
	else
		record "control.unconfined-connect-closed-port" \
			"unconfined connect to 127.0.0.1:${CLOSED_PORT} succeeds" \
			"exit 0, TCP_OK" "$rc" "fail" "listener not reachable unconfined: $out"
	fi

	# Confined connect to an ALLOWED port. Without this the sandbox could be a
	# blanket failure and every denial below would still read as a pass.
	out="$(confined bash -c "$(tcp_probe "$OPEN_PORT")")" && rc=0 || rc=$?
	if [ "$rc" -eq 0 ] && [[ "$out" == *TCP_OK* ]]; then
		record "control.confined-connect-open-port" \
			"confined connect to allow-listed 127.0.0.1:${OPEN_PORT} succeeds" \
			"exit 0, TCP_OK" "$rc" "pass" "$out"
	else
		record "control.confined-connect-open-port" \
			"confined connect to allow-listed 127.0.0.1:${OPEN_PORT} succeeds" \
			"exit 0, TCP_OK" "$rc" "fail" "allow-listed port unreachable — the sandbox is denying everything, so no denial below is informative: $out"
	fi
}

probe_network_denial() {
	local out rc
	out="$(confined bash -c "$(tcp_probe "$CLOSED_PORT")")" && rc=0 || rc=$?
	if [ "$rc" -ne 0 ] && [[ "$out" == *"Permission denied"* || "$out" == *"Operation not permitted"* ]]; then
		record "net.closed-port-denied" \
			"confined connect to non-allow-listed 127.0.0.1:${CLOSED_PORT} is refused by the kernel" \
			"non-zero exit, EACCES/EPERM from connect(2)" "$rc" "pass" "$out"
	else
		record "net.closed-port-denied" \
			"confined connect to non-allow-listed 127.0.0.1:${CLOSED_PORT} is refused by the kernel" \
			"non-zero exit, EACCES/EPERM from connect(2)" "$rc" "fail" "$out"
	fi
}

probe_commit() {
	local out rc wt="$FIXTURE/wt/probe"
	echo "change-$RANDOM" >"$wt/file.txt"

	out="$(cd "$wt" && confined git add file.txt)" && rc=0 || rc=$?
	out="$(cd "$wt" && confined git commit -m "confined commit" --no-gpg-sign)" && rc=0 || rc=$?
	if [ "$rc" -eq 0 ]; then
		record "git.commit-no-gpg-sign" \
			"confined 'git commit --no-gpg-sign' in a worktree succeeds" \
			"exit 0" "$rc" "pass" "$(cd "$wt" && git log --oneline -1)"
	else
		record "git.commit-no-gpg-sign" \
			"confined 'git commit --no-gpg-sign' in a worktree succeeds" \
			"exit 0" "$rc" "fail" "$out"
	fi

	# The counterfactual. gpgsign is true in this fixture, so an unflagged commit
	# must fail — and must fail FAST, at gpg's inability to reach a keyring,
	# never by blocking on a pinentry prompt.
	echo "change2-$RANDOM" >>"$wt/file.txt"
	local start elapsed
	start="$(date +%s)"
	out="$(cd "$wt" && confined git commit -am "unflagged commit")" && rc=0 || rc=$?
	elapsed=$(($(date +%s) - start))
	if [ "$rc" -ne 0 ] && [ "$elapsed" -lt 30 ]; then
		record "git.commit-unflagged-fails-fast" \
			"confined 'git commit' without --no-gpg-sign fails in seconds, not on a prompt timeout" \
			"non-zero exit within 30s" "$rc" "pass" "elapsed=${elapsed}s :: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
	else
		record "git.commit-unflagged-fails-fast" \
			"confined 'git commit' without --no-gpg-sign fails in seconds, not on a prompt timeout" \
			"non-zero exit within 30s" "$rc" "fail" "elapsed=${elapsed}s :: $out"
	fi
}

probe_pinentry() {
	local out rc
	# Positive control FIRST: prove the shim records an invocation, otherwise an
	# empty sentinel file below is evidence of a broken probe, not of silence.
	rm -f "$FIXTURE/out/pinentry-invoked"
	"$FIXTURE/shim/pinentry" >/dev/null 2>&1 || true
	if [ -s "$FIXTURE/out/pinentry-invoked" ]; then
		record "pinentry.shim-control" \
			"the pinentry shim records its own invocation" \
			"sentinel file non-empty after a direct call" 0 "pass" \
			"$(cat "$FIXTURE/out/pinentry-invoked")"
	else
		record "pinentry.shim-control" \
			"the pinentry shim records its own invocation" \
			"sentinel file non-empty after a direct call" 1 "fail" \
			"shim did not record; the silence assertion below cannot be trusted"
	fi

	rm -f "$FIXTURE/out/pinentry-invoked"
	local wt="$FIXTURE/wt/probe"
	echo "p-$RANDOM" >>"$wt/file.txt"
	out="$(cd "$wt" && PATH="$FIXTURE/shim:$PATH" AGENT_GIT_SKIP_ROOT_CHECK=1 \
		HOME="$FIXTURE/home" timeout 60 nono run -s --allow-cwd -p "$FIXTURE/profile.json" -- \
		"$REPO_ROOT/bin/agent-git" commit -am "wrapper commit" 2>&1)" && rc=0 || rc=$?
	if [ ! -e "$FIXTURE/out/pinentry-invoked" ]; then
		record "pinentry.never-invoked" \
			"a wrapper-driven confined commit never invokes pinentry" \
			"sentinel file absent" "$rc" "pass" "no pinentry invocation recorded; commit rc=${rc}"
	else
		record "pinentry.never-invoked" \
			"a wrapper-driven confined commit never invokes pinentry" \
			"sentinel file absent" "$rc" "fail" "$(cat "$FIXTURE/out/pinentry-invoked")"
	fi
}

probe_push() {
	local wt="$FIXTURE/wt/probe" out rc url id
	# Three transports, three ports, all loopback. https->39443, ssh->22,
	# git->9418; none appear in the profile's open_port list.
	for spec in \
		"https|https://127.0.0.1:39443/example.git" \
		"ssh|ssh://git@127.0.0.1:22/example.git" \
		"git|git://127.0.0.1:9418/example.git"; do
		id="${spec%%|*}"
		url="${spec#*|}"
		git -C "$wt" remote remove origin >/dev/null 2>&1 || true
		git -C "$wt" remote add origin "$url"
		out="$(cd "$wt" && confined git push origin HEAD)" && rc=0 || rc=$?
		if [ "$rc" -ne 0 ]; then
			record "git.push-denied.${id}" \
				"confined 'git push' over ${id} to ${url} is refused" \
				"non-zero exit, no successful publication" "$rc" "pass" \
				"$(printf '%s' "$out" | grep -iE 'permission denied|not permitted|could not connect|unable to (access|connect)' | head -1)"
		else
			record "git.push-denied.${id}" \
				"confined 'git push' over ${id} to ${url} is refused" \
				"non-zero exit, no successful publication" "$rc" "fail" "$out"
		fi
	done
	git -C "$wt" remote remove origin >/dev/null 2>&1 || true
}

probe_credentials() {
	local out rc
	for spec in \
		"ssh|${HOME}/.ssh" \
		"gnupg|${HOME}/.gnupg" \
		"aws|${HOME}/.aws" \
		"gcloud|${HOME}/.config/gcloud"; do
		local id="${spec%%|*}" path="${spec#*|}"
		out="$(confined bash -c "ls -A '$path' >/dev/null 2>&1 && echo READABLE || echo DENIED")" && rc=0 || rc=$?
		if [[ "$out" == *DENIED* ]]; then
			record "fs.credential-denied.${id}" \
				"confined process cannot enumerate ${path}" \
				"DENIED" "$rc" "pass" "$out"
		else
			record "fs.credential-denied.${id}" \
				"confined process cannot enumerate ${path}" \
				"DENIED" "$rc" "fail" "$out"
		fi
	done

	out="$(confined bash -c "cat '$FIXTURE/main/README.md' >/dev/null 2>&1 && echo READABLE || echo DENIED")" && rc=0 || rc=$?
	if [[ "$out" == *DENIED* ]]; then
		record "fs.parent-worktree-denied" \
			"confined process cannot read the parent repository's WORKING TREE (its .git is granted; its source is not)" \
			"DENIED" "$rc" "pass" "$out"
	else
		record "fs.parent-worktree-denied" \
			"confined process cannot read the parent repository's WORKING TREE" \
			"DENIED" "$rc" "fail" "$out"
	fi
}

probe_child_inheritance() {
	local wt="$FIXTURE/wt/probe" hooks out rc
	hooks="$(git -C "$wt" rev-parse --git-path hooks)"
	mkdir -p "$hooks"
	cat >"$hooks/pre-commit" <<EOF
#!/bin/bash
# Landlock restrictions are inherited across fork/exec and cannot be dropped, so
# this hook — a grandchild of the sandboxed process — must see the same denial.
if bash -c 'exec 3<>/dev/tcp/127.0.0.1/${CLOSED_PORT}' 2>/dev/null; then
  echo CHILD_CONNECT_OK > "$FIXTURE/out/hook-verdict"
else
  echo CHILD_CONNECT_DENIED > "$FIXTURE/out/hook-verdict"
fi
exit 0
EOF
	chmod +x "$hooks/pre-commit"
	rm -f "$FIXTURE/out/hook-verdict"

	echo "hook-$RANDOM" >>"$wt/file.txt"
	out="$(cd "$wt" && confined git commit -am "commit with hook" --no-gpg-sign)" && rc=0 || rc=$?
	local verdict
	verdict="$(cat "$FIXTURE/out/hook-verdict" 2>/dev/null || echo HOOK_DID_NOT_RUN)"
	if [ "$verdict" = "CHILD_CONNECT_DENIED" ]; then
		record "child.hook-inherits-network-denial" \
			"a git hook spawned by a confined commit inherits the network denial" \
			"CHILD_CONNECT_DENIED" "$rc" "pass" "$verdict"
	elif [ "$verdict" = "HOOK_DID_NOT_RUN" ]; then
		record "child.hook-inherits-network-denial" \
			"a git hook spawned by a confined commit inherits the network denial" \
			"CHILD_CONNECT_DENIED" "$rc" "fail" \
			"the hook never ran, so nothing about inheritance was measured :: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
	else
		record "child.hook-inherits-network-denial" \
			"a git hook spawned by a confined commit inherits the network denial" \
			"CHILD_CONNECT_DENIED" "$rc" "fail" "$verdict"
	fi
	rm -f "$hooks/pre-commit"
}

probe_submodule() {
	local wt="$FIXTURE/wt/probe" out rc
	# A submodule whose SOURCE lives outside the allow-list. `git submodule
	# update` clones it in a child process, which is exactly the escape a
	# recursive operation would offer if confinement were not inherited.
	#
	# The first version of this probe wrote .gitmodules and ran `git submodule
	# update --init` without ever registering the submodule in the index. With
	# nothing in the index, update is a NO-OP that exits 0 — the probe reported a
	# containment failure that was really a probe failure. The submodule is now
	# added and committed UNCONFINED first, so the confined run has real work to
	# refuse.
	#
	# `-c protocol.file.allow=always` is passed on BOTH runs deliberately. git
	# blocks file:// submodules by default (CVE-2022-39253), and without the
	# override the confined run would fail on git's own policy rather than on
	# Landlock — a pass for entirely the wrong reason.
	git init -q "$FIXTURE/outside-src"
	git -C "$FIXTURE/outside-src" config user.email a@b.invalid
	git -C "$FIXTURE/outside-src" config user.name A
	echo secret >"$FIXTURE/outside-src/secret.txt"
	git -C "$FIXTURE/outside-src" add -A
	git -C "$FIXTURE/outside-src" commit -q --no-gpg-sign -m outside

	# `-q --force`, not `-qf`: git submodule's option parser rejects the combined
	# short form and prints usage with exit 1, which the guard below then reports
	# as a fixture failure rather than as the flag typo it is. --force is needed
	# because the host's global gitignore may cover the submodule path.
	if ! git -C "$wt" -c protocol.file.allow=always submodule add -q --force \
		"file://$FIXTURE/outside-src" sp1-sub/outside >/dev/null 2>&1; then
		record "submodule.outside-allowlist-denied" \
			"a submodule sourced from outside the allow-list cannot be materialised inside the sandbox" \
			"non-zero exit from a confined 'submodule update'" 1 "fail" \
			"fixture setup failed: could not register the submodule unconfined, so nothing was measured"
		return 0
	fi
	git -C "$wt" commit -q --no-gpg-sign -m "add outside submodule"

	# Deinit alone is NOT enough, and the first version of this probe reported a
	# containment failure because of it. `submodule add` clones the source into
	# .git/modules/<name>, which lives inside the allow-listed parent .git. A
	# later `submodule update --init` finds that cache and checks it out without
	# ever touching the original source — so the operation legitimately succeeds
	# with the source denied. The claim "outside sources are unreachable" is about
	# FETCHING, so the cache has to go for the probe to be about anything.
	local modules_dir
	modules_dir="$(git -C "$wt" rev-parse --git-path "modules/sp1-sub/outside" 2>/dev/null || true)"
	git -C "$wt" -c protocol.file.allow=always submodule deinit -q --force sp1-sub/outside >/dev/null 2>&1 || true
	rm -rf "$wt/sp1-sub/outside"
	[ -n "$modules_dir" ] && rm -rf "$modules_dir"
	# Assert the cache is really gone: if it survived, the probe below measures a
	# checkout rather than a fetch and its verdict means nothing.
	if [ -n "$modules_dir" ] && [ -d "$modules_dir" ]; then
		record "submodule.outside-allowlist-denied" \
			"a submodule sourced from outside the allow-list cannot be materialised inside the sandbox" \
			"non-zero exit from a confined 'submodule update'" 1 "fail" \
			"could not clear the .git/modules cache at ${modules_dir}; the probe would measure a checkout, not a fetch"
		return 0
	fi

	out="$(cd "$wt" && confined git -c protocol.file.allow=always submodule update --init --recursive sp1-sub/outside)" && rc=0 || rc=$?
	if [ "$rc" -ne 0 ] && [ ! -s "$wt/sp1-sub/outside/secret.txt" ]; then
		record "submodule.outside-allowlist-denied" \
			"a submodule sourced from outside the allow-list cannot be materialised inside the sandbox" \
			"non-zero exit and no submodule content on disk" "$rc" "pass" \
			"$(printf '%s' "$out" | grep -iE 'permission|denied|fatal' | head -1)"
	else
		record "submodule.outside-allowlist-denied" \
			"a submodule sourced from outside the allow-list cannot be materialised inside the sandbox" \
			"non-zero exit and no submodule content on disk" "$rc" "fail" \
			"$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
	fi

	# Control: the same operation must SUCCEED when the source IS allowed.
	# Without it, a pass above is indistinguishable from git being broken.
	out="$(cd "$wt" && HOME="$FIXTURE/home" timeout 60 nono run -s --allow-cwd \
		-a "$FIXTURE/outside-src" -p "$FIXTURE/profile.json" -- \
		git -c protocol.file.allow=always submodule update --init --recursive sp1-sub/outside 2>&1)" && rc=0 || rc=$?
	if [ "$rc" -eq 0 ] && [ -s "$wt/sp1-sub/outside/secret.txt" ]; then
		record "submodule.allowed-source-control" \
			"the same submodule update SUCCEEDS when its source is added to the allow-list" \
			"exit 0 and submodule content present" "$rc" "pass" "content materialised"
	else
		record "submodule.allowed-source-control" \
			"the same submodule update SUCCEEDS when its source is added to the allow-list" \
			"exit 0 and submodule content present" "$rc" "fail" \
			"the denial above cannot be attributed to the allow-list: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
	fi
}

probe_index_lock() {
	local wt="$FIXTURE/wt/probe" git_dir out rc
	git_dir="$(git -C "$wt" rev-parse --git-dir)"

	# A lock older than the stale threshold and held by nothing: the wrapper must
	# clear it and say so. Not clearing it is how a killed agent bricks a worktree.
	: >"$git_dir/index.lock"
	touch -d '2 hours ago' "$git_dir/index.lock"
	echo "lock-$RANDOM" >>"$wt/file.txt"
	out="$(cd "$wt" && AGENT_GIT_SKIP_ROOT_CHECK=1 "$REPO_ROOT/bin/agent-git" commit -am "post-lock commit" 2>&1)" && rc=0 || rc=$?
	if [ "$rc" -eq 0 ] && [ ! -e "$git_dir/index.lock" ]; then
		record "lock.stale-index-lock-cleared" \
			"agent-git clears an unheld, stale .git/index.lock and completes the commit" \
			"exit 0 and no lock left behind" "$rc" "pass" "$(printf '%s' "$out" | head -1)"
	else
		record "lock.stale-index-lock-cleared" \
			"agent-git clears an unheld, stale .git/index.lock and completes the commit" \
			"exit 0 and no lock left behind" "$rc" "fail" "$out"
	fi

	# The counterfactual: a FRESH lock must be left alone. A wrapper that deletes
	# every lock it finds corrupts a concurrent write, which is worse than the
	# problem it solves.
	: >"$git_dir/index.lock"
	echo "lock2-$RANDOM" >>"$wt/file.txt"
	out="$(cd "$wt" && AGENT_GIT_SKIP_ROOT_CHECK=1 "$REPO_ROOT/bin/agent-git" commit -am "fresh lock commit" 2>&1)" && rc=0 || rc=$?
	if [ -e "$git_dir/index.lock" ]; then
		record "lock.fresh-index-lock-preserved" \
			"agent-git leaves a FRESH .git/index.lock in place rather than racing a live writer" \
			"lock still present" "$rc" "pass" "lock preserved; commit rc=${rc}"
		rm -f "$git_dir/index.lock"
	else
		record "lock.fresh-index-lock-preserved" \
			"agent-git leaves a FRESH .git/index.lock in place rather than racing a live writer" \
			"lock still present" "$rc" "fail" "a fresh lock was removed"
	fi
}

probe_telemetry() {
	# The kernel-audit parser deliverable.
	#
	# FINDING, recorded here because it is not obvious and would otherwise be
	# rediscovered: nono 0.73.0's --diagnostics-json emits session.denials for
	# FILESYSTEM path discovery only. A Landlock *network* refusal populates none
	# of denials/ipc_denials/violations. The structured signal for a blocked
	# connect is therefore the pair (session.diagnostics contains
	# command_failed_likely_sandbox, child stderr carries the connect(2) errno).
	# A parser that looked only at session.denials would report zero blocked
	# connections on a host where every connection was blocked.
	local raw parsed
	raw="$(confined_diag bash -c "$(tcp_probe "$CLOSED_PORT")" || true)"
	printf '%s' "$raw" >"$FIXTURE/out/diagnostics.txt"

	parsed="$(python3 - "$FIXTURE/out/diagnostics.txt" <<'PY'
import json, re, sys
raw = open(sys.argv[1]).read()
start = raw.find("{")
session = {}
if start >= 0:
    try:
        session = json.loads(raw[start:]).get("session", {})
    except Exception:
        session = {}
errnos = re.findall(r"(?:connect|socket|bind):\s*(Permission denied|Operation not permitted)", raw)
codes = [d.get("code") for d in session.get("diagnostics", []) or []]
out = {
    "syscall_denials": errnos,
    "sandbox_diagnostic_codes": codes,
    "session_denials": session.get("denials", []),
    "structured": bool(errnos) and "command_failed_likely_sandbox" in codes,
}
print(json.dumps(out))
PY
	)"
	if printf '%s' "$parsed" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["structured"] else 1)'; then
		record "telemetry.blocked-connect-is-structured" \
			"a blocked connect(2) yields a parseable errno plus a sandbox diagnostic code" \
			"syscall_denials non-empty AND command_failed_likely_sandbox present" 0 "pass" "$parsed"
	else
		record "telemetry.blocked-connect-is-structured" \
			"a blocked connect(2) yields a parseable errno plus a sandbox diagnostic code" \
			"syscall_denials non-empty AND command_failed_likely_sandbox present" 1 "fail" "$parsed"
	fi
}

write_evidence() {
	local body="" r
	for r in ${RESULTS[@]+"${RESULTS[@]}"}; do body="${body}${r},"; done
	body="[${body%,}]"
	# Written to a file rather than interpolated into the heredoc, and that is not
	# style. An UNQUOTED heredoc processes backslash escapes, so every `\"` that
	# json.dumps emitted arrived at Python as a bare `"` and the whole document
	# failed to parse with "Invalid control character". The probe results were
	# correct; only their transport was destroying them.
	printf '%s' "$body" >"$FIXTURE/out/probes.json"
	mkdir -p "$(dirname "$EVIDENCE")"
	python3 - "$EVIDENCE" "$FAILED" "$SKIPPED" "$PROFILE" "$FIXTURE/out/probes.json" <<'PY'
import json, subprocess, sys, datetime
probes = json.load(open(sys.argv[5]))
def sh(*a):
    try:
        return subprocess.run(a, capture_output=True, text=True).stdout.strip()
    except Exception:
        return ""
doc = {
    "artifact": "worktree-confinement-proof",
    "rule": "SP-1",
    "card": "CRKC-P3-2",
    "generated": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
    "host": {
        "kernel": sh("uname", "-r"),
        "lsm": open("/sys/kernel/security/lsm").read().strip(),
        "nono": sh("nono", "--version"),
        "git": sh("git", "--version"),
    },
    "profile": sys.argv[4],
    "totals": {
        "probes": len(probes),
        "passed": sum(1 for p in probes if p["verdict"] == "pass"),
        "failed": int(sys.argv[2]),
        "skipped": int(sys.argv[3]),
    },
    "probes": probes,
}
json.dump(doc, open(sys.argv[1], "w"), indent=2)
open(sys.argv[1], "a").write("\n")
print(sys.argv[1])
PY
}

main() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--json)
			EVIDENCE="$2"
			shift 2
			;;
		--profile)
			PROFILE="$2"
			shift 2
			;;
		--keep)
			KEEP=1
			shift
			;;
		-h | --help)
			usage
			return 0
			;;
		*)
			echo "unknown option: $1" >&2
			return 2
			;;
		esac
	done

	require || return 1
	if ! OPEN_PORT="$(pick_open_port)"; then
		echo "no free port in the profile's network.open_port list — cannot establish" >&2
		echo "the positive control, so no denial below would be informative." >&2
		return 1
	fi
	log "building fixture (open_port=${OPEN_PORT}, closed_port=${CLOSED_PORT})"
	build_fixture
	start_listener "$OPEN_PORT"
	start_listener "$CLOSED_PORT"
	sleep 1
	# Assert both listeners are actually up. A dead listener turns "connect
	# refused" into an ambiguous result that reads as a successful denial.
	local p
	for p in "$OPEN_PORT" "$CLOSED_PORT"; do
		ss -lnt "sport = :$p" 2>/dev/null | grep -q LISTEN || {
			echo "listener on 127.0.0.1:${p} did not come up; refusing to report probes" >&2
			return 1
		}
	done

	log "running probes"
	probe_controls
	probe_network_denial
	probe_commit
	probe_pinentry
	probe_push
	probe_credentials
	probe_child_inheritance
	probe_submodule
	probe_index_lock
	probe_telemetry

	local path
	path="$(write_evidence)"
	log "evidence written: $path"
	log "probes=${#RESULTS[@]} failed=${FAILED} skipped=${SKIPPED}"
	[ "$FAILED" -eq 0 ]
}

main "$@"
