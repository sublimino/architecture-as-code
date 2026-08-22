#!/usr/bin/env bash
#
# guard-falsification-proof.sh — prove this repository's guards can actually fail.
#
# ── Why this exists ─────────────────────────────────────────────────────────
#
# A check that cannot fail is worse than no check, because it reads as coverage.
# This repository has shipped that shape repeatedly, and every instance was
# found by accident rather than by a test:
#
#   * a registry guard whose exclusion-list reader shelled out to
#     `make -f - include Makefile`, which re-ran the default target instead of
#     printing the variable. The list parsed empty; two tests passed vacuously.
#   * the same guard's `-not -path '*/.worktrees/*'` filter, which matched the
#     ENTIRE TREE when run from a worktree. Correct in the main checkout,
#     silently examining nothing everywhere agents actually work.
#   * a CI-wiring assertion that grepped the whole pipeline file for a script
#     name. The stage's own COMMENT contained it, so deleting the real
#     invocation left the test green.
#   * scripts/check-flux-substitution.sh, which printed "no unsubstituted
#     tokens" against no cluster at all.
#   * `patch_py` in the audit proof, which asserted its anchors and never
#     checked python's exit code. A stale anchor produced a false
#     "all twelve guards are decoration".
#
# Five, in guards written by people already hunting this exact bug. The
# assumption here is that the rest of the estate is no better.
#
# ── What this proves that the existing suites do not ────────────────────────
#
# Two falsification harnesses already exist and this one is modelled on them:
# d2-signalloom/test/audit-guard-reintroduction-proof.sh (12 cases) and
# d2-signalloom/test/seam-guard-mutation-proof.sh (11 cases).
#
# Many guards in this estate ALREADY falsify themselves — ci-build-parity.bats
# and rbac-subject-resolution.bats build fixture repos, inject drift, and assert
# a non-zero exit. Those fixture tests are real evidence, and they are not what
# this harness re-tests.
#
# The untested half is the REAL-TREE assertion. "RBAC every binding in this
# repository resolves", "no cosign sign call site signs by tag", "no UNDECLARED
# proxy location drops Authorization while accepting mutation" — each of those
# runs the checker against the actual repository and has been green since the
# day it was written. A fixture test proves the CHECKER can go red. It proves
# nothing about whether the real-tree assertion is still WIRED to the real tree.
# That is precisely the check-flux-substitution.sh shape: a correct checker,
# pointed at nothing, reporting success.
#
# So every case below mutates the REAL FILE the real-tree assertion reads, and
# requires that assertion to go red.
#
# ── Verdicts: never two, and as it turned out never three ───────────────────
#
# The defect that produced a false "all twelve audit guards are decoration" was
# a two-outcome verdict: the harness could not tell "the guard ran and stayed
# quiet" from "the guard never ran". Those are different answers and they do not
# share an exit path here.
#
#   FIRED         the guard went red, and its output matched the expected
#                 signature. The check is live for this defect.
#   BLIND SPOT    the guard stayed green on the injected defect, but went RED on
#                 the POSITIVE CONTROL — a blunter form of the same defect. The
#                 guard works and has a specific gap. FINDING. Widen the check.
#   DECORATION    the guard stayed green on the defect AND on the control. It
#                 does not fire. FINDING. Rewrite the check.
#   UNCLASSIFIED  the guard stayed green and no control is registered, so blind
#                 spot and decoration were not told apart. FINDING, but the
#                 finding is "nobody has measured this yet" — never quoted as
#                 evidence that a guard is dead.
#   UNFAITHFUL    the mutation changed the target and injected NO violation of
#                 the property. A defect in THIS FILE. No verdict is filed about
#                 the guard, because none was earned.
#   UNKNOWN       the harness could not run the case. Never counted as either a
#                 pass or a finding.
#
# ── The fifth verdict, and why it had to exist ──────────────────────────────
#
# UNFAITHFUL was added after a verdict from this harness was proven wrong and
# the guard it accused turned out to be innocent.
#
# SIGN-BY-TAG mutated a `cosign sign` call by ADDING an image reference beside
# the digest that was already there. Every phase passed: the anchor matched, the
# file changed, the checksum moved, the tree restored. The guard stayed green
# and the harness printed "GUARD DID NOT FIRE". But the harness had proof only
# that it had EDITED A FILE. Whether it had injected a DEFECT was never checked.
#
# That is this file's own catalogue, one level up: a check that runs, reports
# confidently, and measured nothing. Shipped by the tool built to find it.
#
# Every case therefore carries a PROPERTY ORACLE — an independent statement of
# the property that reports how many units violate it. It must read 0 on a clean
# tree and >= 1 once the mutation lands. A mutation that cannot move it injected
# nothing, and gets this verdict instead of an accusation. A case with no oracle
# cannot produce a finding at all, and the registry refuses to start without one.
#
# Two verdicts that look identical from outside — "the guard is blind" and "my
# mutation was a no-op" — have opposite repairs. Confusing them gets a working
# guard rewritten, which is strictly worse than leaving it alone.
#
# The third and fourth verdicts were added because the first real run of this
# file got it wrong. It printed "GUARD DID NOT FIRE — THIS CHECK IS DECORATION"
# for two guards. Both statements underneath that headline were true; the
# headline was false. Re-tested with a blunter mutation, both went red. One
# mutation can only ever establish "this guard did not catch THIS ONE THING", and
# the leap from there to "this guard catches nothing" is an inference — the
# identical over-reach that produced the false "all twelve audit guards are
# decoration" this harness was built in response to. The control turns the
# inference back into a measurement.
#
# UNKNOWN covers: a baseline that was not green; a --filter that selected ZERO
# tests; a mutation that did not change the file; a guard that went red for a
# reason other than the injected defect; a tree that did not recover on restore;
# and a positive control that could not be applied, because a finding that cannot
# be classified must not be filed as though it had been.
#
# ── On `bats --filter` selecting nothing ────────────────────────────────────
#
# Measured against bats 1.13.0 in this tree:
#
#     $ bats --tap --filter 'THIS_MATCHES_NOTHING_XYZ' test/kind-config-heredoc.bats
#     1..0
#     run-exit=0
#
# A filter that matches no test exits 0. A typo in this file's registry would
# therefore produce a green baseline, a green mutated run, and a report reading
# "GUARD DID NOT FIRE — this check is decoration" for every affected case, with
# nothing whatever wrong with the guard. Each case asserts `bats --count` is
# non-zero before it believes anything.
#
# ── Restore ─────────────────────────────────────────────────────────────────
#
# Never `git checkout -- <path>`. That reverts the operator's own uncommitted
# work, and it has already happened in this repository: the audit proof's
# restore reverted an in-progress edit to a tracked test file, and the case then
# ran against the OLD guard and reported "did not fire" — a harness bug that
# reads exactly like a guard defect.
#
# Files are snapshotted byte-for-byte before mutation and written back from that
# snapshot. Files that did not exist are recorded as absent and deleted on
# restore. An EXIT trap restores on every path including SIGINT, and
# `--self-test` proves the trap works by killing a run mid-mutation and checking
# the file came back.
#
# ── Usage ───────────────────────────────────────────────────────────────────
#
#   test/guard-falsification-proof.sh              run every registered case
#   test/guard-falsification-proof.sh --list       print the registry and exit
#   test/guard-falsification-proof.sh --only RBAC  run cases whose id matches
#   test/guard-falsification-proof.sh --self-test  prove THIS harness can fail
#
# Requires: bats, python3, git, yq. No cluster, no database, no network.
# The harness performs READS ONLY against Kubernetes — it never mutates a
# cluster, and no registered case invokes kubectl.

set -eo pipefail   # deliberately NOT -u: the shell snapshot's grep wrapper
                   # references $ZSH_VERSION unguarded, and nounset makes every
                   # grep call in this script fatal.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SNAPSHOT_DIR="$(mktemp -d)"

# Diagnostics travel through a FILE, not through a shell variable.
#
# oracle_count and selected_test_count are both called as `v="$(fn ...)"`, and a
# command substitution runs in a SUBSHELL. A global assigned in there is
# discarded when the subshell exits, so the first version of both functions set
# a rich explanation that the caller could never read — every diagnostic came
# out empty, and the reason for an UNKNOWN was silently blank in exactly the
# situation the reason exists for. Verified:
#
#     $ bash -c 'E=""; f(){ E="set inside"; printf "42"; }; v="$(f)"; echo "[$E]"'
#     []
#
# One file, written by the callee and read by the caller, crosses that boundary.
ERR_CHANNEL="${SNAPSHOT_DIR}/last-error.txt"
err_set() { printf '%s' "$1" >"$ERR_CHANNEL"; }
err_get() { cat "$ERR_CHANNEL" 2>/dev/null; }
err_clear() { : >"$ERR_CHANNEL"; }
FIRED=0
NOT_FIRED=0        # total findings = BLIND + DECOR + UNCLASSIFIED
BLIND=0
DECOR=0
UNCLASSIFIED=0
UNKNOWN=0
UNFAITHFUL=0       # mutations that injected no defect. A HARNESS bug, never a finding.
DIRTY_TREE=0
declare -a FINDINGS=()
declare -a UNKNOWNS=()
declare -a UNFAITHFULS=()

# ── Snapshot and restore ────────────────────────────────────────────────────
#
# Parallel arrays rather than an associative array keyed on path, because the
# same file may legitimately be mutated by more than one case and the FIRST
# snapshot is the one to keep.
declare -a SNAP_PATHS=()
declare -a SNAP_KEYS=()

snapshot() {
	local path="$1" key
	local p
	for p in "${SNAP_PATHS[@]}"; do
		[ "$p" = "$path" ] && return 0   # already held; keep the earliest bytes
	done
	key="$(printf '%s' "$path" | md5sum | cut -d' ' -f1)"
	SNAP_PATHS+=("$path")
	SNAP_KEYS+=("$key")
	if [ -e "$path" ]; then
		cp -p "$path" "${SNAPSHOT_DIR}/${key}.bytes"
	else
		# Record absence explicitly. A case that CREATES a file (a new spec, a
		# new bats suite) restores by deletion, and conflating that with "no
		# snapshot taken" would leave the file behind.
		: >"${SNAPSHOT_DIR}/${key}.absent"
	fi
}

restore_all() {
	local i key path
	for i in "${!SNAP_PATHS[@]}"; do
		path="${SNAP_PATHS[$i]}"
		key="${SNAP_KEYS[$i]}"
		if [ -f "${SNAPSHOT_DIR}/${key}.absent" ]; then
			rm -f "$path"
		elif [ -f "${SNAPSHOT_DIR}/${key}.bytes" ]; then
			cp -p "${SNAPSHOT_DIR}/${key}.bytes" "$path"
		fi
	done
}

cleanup() {
	local rc=$?
	restore_all
	rm -rf "$SNAPSHOT_DIR"
	# An EXIT trap whose last command fails REPLACES the script's exit status
	# under errexit. That defect has shipped here before: eight green stages
	# still reported failure because a trap's final command returned non-zero.
	# The explicit return preserves whatever the script actually decided.
	return $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ── Mutation helpers ────────────────────────────────────────────────────────
#
# Every one of these ASSERTS ITS ANCHOR and exits non-zero when the anchor is
# absent. A sed or python patch whose pattern misses is a no-op that prints
# success, and the case then reports "guard did not fire" for a reason that has
# nothing to do with the guard. That exact false alarm has already shipped in
# this repository. Content travels through the environment, not through nested
# shell quoting, so an anchor containing quotes, backslashes or newlines cannot
# be silently mangled on the way in.

py_sub() {   # file, old, new  — replace FIRST occurrence, assert old present
	MUT_FILE="$1" MUT_OLD="$2" MUT_NEW="$3" python3 - <<-'PY'
		import os, sys, pathlib
		p = pathlib.Path(os.environ["MUT_FILE"])
		if not p.exists():
		    sys.stderr.write("target does not exist: %s\n" % p); sys.exit(3)
		s = p.read_text()
		old, new = os.environ["MUT_OLD"], os.environ["MUT_NEW"]
		if old not in s:
		    sys.stderr.write("ANCHOR NOT FOUND in %s: %r\n" % (p, old[:160])); sys.exit(3)
		p.write_text(s.replace(old, new, 1))
	PY
}

py_insert_before() {   # file, anchor, text — insert text before FIRST anchor
	MUT_FILE="$1" MUT_OLD="$2" MUT_NEW="$3" python3 - <<-'PY'
		import os, sys, pathlib
		p = pathlib.Path(os.environ["MUT_FILE"])
		if not p.exists():
		    sys.stderr.write("target does not exist: %s\n" % p); sys.exit(3)
		s = p.read_text()
		anchor, text = os.environ["MUT_OLD"], os.environ["MUT_NEW"]
		if anchor not in s:
		    sys.stderr.write("ANCHOR NOT FOUND in %s: %r\n" % (p, anchor[:160])); sys.exit(3)
		p.write_text(s.replace(anchor, text + anchor, 1))
	PY
}

py_append() {   # file, text — append; asserts the file exists
	MUT_FILE="$1" MUT_NEW="$2" python3 - <<-'PY'
		import os, sys, pathlib
		p = pathlib.Path(os.environ["MUT_FILE"])
		if not p.exists():
		    sys.stderr.write("target does not exist: %s\n" % p); sys.exit(3)
		p.write_text(p.read_text() + os.environ["MUT_NEW"])
	PY
}

py_create() {   # file, text — create a NEW file; asserts it did not exist
	MUT_FILE="$1" MUT_NEW="$2" python3 - <<-'PY'
		import os, sys, pathlib
		p = pathlib.Path(os.environ["MUT_FILE"])
		if p.exists():
		    sys.stderr.write("expected %s to be absent, but it exists\n" % p); sys.exit(3)
		p.parent.mkdir(parents=True, exist_ok=True)
		p.write_text(os.environ["MUT_NEW"])
	PY
}

# ── Guard invocation ────────────────────────────────────────────────────────

GUARD_STATUS=0
GUARD_OUTPUT=""

# show <text> <grep-ere or ""> <max-lines> <prefix>
#
# Display-only output, and NEVER fatal. This function exists because the harness
# shipped the exact defect it hunts, and only running it found that out.
#
# `set -o pipefail` makes a pipeline return the first non-zero status in it. A
# `grep` that MATCHES NOTHING returns 1. Under `set -e` that combination kills
# the script. Run 2 of this harness died on
#
#     printf '%s\n' "$ctrl_output" | grep -E '^not ok|^# ' | head -3 | sed ...
#
# because the last registered case was an `sh`-kind guard whose output is prose
# and contains no TAP lines at all, so the grep selected nothing. The script
# exited between the final verdict and the summary block. All 21 verdicts had
# been computed and NOT ONE was printed — and the exit status was 1, which is
# this harness's code for "a guard did not fire". A silent death that renders as
# an ordinary finding is precisely the failure mode being catalogued here, and it
# stayed invisible for four cases in run 1 only because bats output always
# happened to contain a matching line.
#
# `head` is the second trigger: it closes the pipe once it has its lines, and the
# upstream `printf` can then take SIGPIPE and report non-zero for the same
# reason. Both are cosmetic; neither may ever decide a verdict.
# No sed, no grep, no pipeline — bash builtins only.
#
# The first version of this function was `... | grep -E "$pat" | head -n | sed
# "s|^|$prefix|"`, and it printed NOTHING for every finding in the run that
# introduced it:
#
#     *** GUARD DID NOT FIRE ***
#         the defect was present and the guard exited 0. Observed output:
#     sed: -e expression #1, char 13: unknown option to `s'
#
# The prefix for indented evidence is "      | ". It contains the `|` that was
# being used as the s/// delimiter, so sed rejected the expression on every call.
# The `|| true` added to stop pipefail killing the run then swallowed the failure
# status too, leaving four findings filed with their evidence silently missing —
# and the brief for this work says a guard may be reported ONLY with its observed
# output quoted. A cosmetic helper had quietly deleted the evidence while every
# verdict above it stayed correct, so the report still read as complete.
#
# Two lessons, both already in this file's own catalogue: a wrapper that makes
# failures non-fatal must not also make them invisible, and a formatter whose
# argument is interpolated into a mini-language (sed, awk, a regex) breaks on the
# first argument containing that language's metacharacters. Builtins take no
# delimiter and cannot be injected into.
show() {
	local text="$1" pat="$2" n="$3" prefix="$4" line count=0
	while IFS= read -r line; do
		if [ "$count" -ge "$n" ]; then break; fi
		# bash's own ERE engine: no subprocess, so no pipefail interaction and no
		# SIGPIPE. `head` closing a pipe early was the other way this died.
		if [ -n "$pat" ] && ! [[ "$line" =~ $pat ]]; then continue; fi
		printf '%s%s\n' "$prefix" "$line"
		count=$((count + 1))
	done <<< "$text"
	return 0
}

# run_guard <kind> <file> <filter>
#   kind=bats  file is a .bats suite, filter is a --filter regex ("" = whole file)
#   kind=sh    file is a script, filter is ignored
run_guard() {
	local kind="$1" file="$2" filter="$3"
	GUARD_OUTPUT=""
	GUARD_STATUS=0
	case "$kind" in
		bats)
			if [ -n "$filter" ]; then
				GUARD_OUTPUT="$(timeout 300 bats --tap --filter "$filter" "$file" 2>&1)" || GUARD_STATUS=$?
			else
				GUARD_OUTPUT="$(timeout 300 bats --tap "$file" 2>&1)" || GUARD_STATUS=$?
			fi
			;;
		sh)
			GUARD_OUTPUT="$(timeout 300 bash "$file" 2>&1)" || GUARD_STATUS=$?
			;;
		*)
			GUARD_OUTPUT="unknown guard kind: $kind"
			GUARD_STATUS=99
			;;
	esac
	return 0
}

# selected_test_count <kind> <file> <filter>
#
# The mechanism assertion. `bats --filter` matching nothing exits 0 with "1..0",
# so a stale test name in the registry below is indistinguishable from a guard
# that works — until this returns 0 and the case is reported UNKNOWN.
selected_test_count() {
	local kind="$1" file="$2" filter="$3" n rc=0
	err_clear
	case "$kind" in
		bats)
			# `|| n=0` used to swallow the exit status here, so a bats that
			# CRASHED — too old for --count, missing from the VM image, a broken
			# libexec — was reported as "filter selected ZERO tests", which reads
			# as a stale test name in this registry. Two very different repairs,
			# and the wrong one sends someone editing a filter that was correct.
			# The CI VM produced eight could-not-run verdicts that the local tree
			# does not produce at all, so attributing them correctly is the
			# difference between a diagnosis and a guess.
			if [ -n "$filter" ]; then
				n="$(timeout 120 bats --count --filter "$filter" "$file" 2>&1)" || rc=$?
			else
				n="$(timeout 120 bats --count "$file" 2>&1)" || rc=$?
			fi
			if [ "$rc" -ne 0 ]; then
				err_set "bats --count itself failed (exit $rc): ${n}"
				n=0
			fi
			case "$n" in
				''|*[!0-9]*) err_set "bats --count printed a non-integer: ${n}"; n=0 ;;
			esac
			;;
		sh)
			# A script is one unit with no filter, so the bats zero-selection trap
			# cannot apply. State the limitation plainly rather than implying a
			# check that is not happening: there is no general way from out here to
			# assert that a CHECKER'S OWN SCAN found anything. That is exactly the
			# `-not -path '*/.worktrees/*'` defect — a checker examining an empty
			# set and reporting success — and only the checker can assert its own
			# mechanism. What is checkable here is that the file exists and is
			# readable, so a renamed or deleted script is UNKNOWN, never a pass.
			if [ -r "$file" ]; then n=1; else n=0; fi
			;;
		*)  n=0 ;;
	esac
	printf '%s' "${n:-0}"
}

# ── The registry ────────────────────────────────────────────────────────────
#
# Parallel arrays: id, category, guard kind, guard file, test filter, target
# file, expected failure signature (a grep -E pattern), mutation function name.
#
# The mutation is a bash FUNCTION rather than a string passed to eval. A string
# carrying nginx config, YAML and Makefile recipes through two layers of shell
# quoting is a no-op waiting to happen, and a no-op mutation is exactly the
# false alarm this harness exists to avoid.

declare -a C_ID=() C_CAT=() C_KIND=() C_GUARD=() C_FILTER=() C_TARGET=() C_SIG=() C_MUT=()
declare -a C_CTRL=() C_ORACLE=()

register() {
	C_ID+=("$1"); C_CAT+=("$2"); C_KIND+=("$3"); C_GUARD+=("$4")
	C_FILTER+=("$5"); C_TARGET+=("$6"); C_SIG+=("$7"); C_MUT+=("$8")
	C_CTRL+=("")     # no control mutation unless register_control follows
	C_ORACLE+=("")   # attached by attach_oracle below; MANDATORY, gated at startup
}

# attach_oracle <case-id> <oracle-fn>
#
# Attaches a PROPERTY ORACLE by id rather than by position. By id deliberately:
# the oracles were added to a registry several people edit concurrently, and an
# `attach` that has to sit immediately after its `register` turns every new
# oracle into a diff against somebody else's case. Keyed lookup means the whole
# oracle layer lives in one block and touches no existing registration line.
attach_oracle() {
	local id="$1" fn="$2" i found=0
	for i in "${!C_ID[@]}"; do
		if [ "${C_ID[$i]}" = "$id" ]; then C_ORACLE[$i]="$fn"; found=1; fi
	done
	if [ "$found" -eq 0 ]; then
		printf 'FATAL: attach_oracle names an unregistered case: %s\n' "$id" >&2
		exit 2
	fi
}

# register_control <mutation-fn>
#
# Attaches a POSITIVE CONTROL to the case just registered: a blunt, unambiguous
# version of the same defect that the guard is definitely supposed to catch.
#
# Why this exists — and it is the single most important thing this harness
# learned from its own first real run. That run reported two guards as
# "DECORATION", in those words. Both reports were WRONG, and wrong in the
# direction that does the most damage: a true statement ("the guard stayed green
# with this defect present") printed under a false headline ("this check is
# decoration"). Re-tested with a blunter mutation, both guards went red:
#
#   SIGN-BY-TAG          subtle: sign a tag ALONGSIDE the existing digest -> GREEN
#                        control: sign a tag INSTEAD of the digest        -> RED
#   CI-BUILD-PARITY-REAL subtle: `true # make <step>` (trailing comment)   -> GREEN
#                        control: delete the invocation line entirely      -> RED
#
# CI-BUILD-PARITY-REAL is recorded above as it was MEASURED, not as it stands.
# That blind spot was real and is now closed: check-ci-build-parity.sh strips
# trailing comments quote-awarely, and both parity cases FIRE on the subtle
# mutation as of 2026-08-16. The record stays because the classification is the
# lesson — the first run called this guard DECORATION and was wrong, and the
# control is what turned that inference into a measurement and then into a
# two-line fix. Do not read these two lines as the guard's current behaviour;
# run the harness for that.
#
# Neither guard is decoration. Each is a live guard with a specific blind spot,
# which is a real finding and a completely different repair. Calling a working
# guard decoration gets it rewritten; naming the blind spot gets it fixed.
#
# One mutation can only ever prove "this guard did not catch THIS". Concluding
# "this guard catches NOTHING" from that is an inference, and the brief for this
# work forbids exactly that inference. The control is what turns the inference
# into a measurement.
register_control() {
	if [ "${#C_ID[@]}" -eq 0 ]; then
		printf 'FATAL: register_control called before any register\n' >&2
		exit 2
	fi
	C_CTRL[$(( ${#C_ID[@]} - 1 ))]="$1"
}

# ── RBAC ────────────────────────────────────────────────────────────────────

FLEET_TENANT="d2-osramp-fleet/tenants/local/signalloom.yaml"

mut_rbac_dangling_sa() {
	# A RoleBinding naming a ServiceAccount nobody declares is legal, is stored
	# by the API server, is marked Ready by Flux, and grants NOTHING. In this
	# estate the only symptom is a workload getting fewer results than it should.
	#
	# The SUBJECT is renamed, never the declaration. Renaming both — which a bare
	# `sed s/spire-agent/…/` does, since the declaration and the subject carry the
	# same name — leaves the manifest perfectly consistent and injects no drift at
	# all. rbac-subject-resolution.bats records having made exactly that mistake
	# and reporting its own checker as broken when it was correct.
	py_sub "$FLEET_TENANT" \
		'        - kind: ServiceAccount
          name: spire-agent
          namespace: inf-bao' \
		'        - kind: ServiceAccount
          name: spire-agent-typo
          namespace: inf-bao'
}
register RBAC-DANGLING-SA rbac bats test/rbac-subject-resolution.bats \
	'every binding in this repository resolves' "$FLEET_TENANT" \
	'confers no permissions|not ok' mut_rbac_dangling_sa

mut_rbac_discovery_grant_removed() {
	# Adds a namespace to the proxy's discovery list without the matching
	# Role/RoleBinding. The proxy degrades gracefully on a 403 — it logs, keeps
	# the namespaces that work, and /agents simply returns fewer agents than the
	# cluster holds. Same silent-shortfall shape as a `kind load` that exits 0
	# having transferred nothing.
	py_sub "d2-signalloom/apps/fake-integration-proxy/server.py" \
		'DEFAULT_AGENT_DISCOVERY_NAMESPACES = ("fe-signalloom-agents", "fe-signalloom")' \
		'DEFAULT_AGENT_DISCOVERY_NAMESPACES = ("fe-signalloom-agents", "fe-signalloom", "ns-with-no-grant-at-all")'
}
register RBAC-DISCOVERY-UNGRANTED rbac bats d2-signalloom/test/agent-discovery-rbac.bats \
	'every discovery namespace grants the proxy SA a pod-reading Role' \
	"d2-signalloom/apps/fake-integration-proxy/server.py" \
	'not ok' mut_rbac_discovery_grant_removed

# ── Supply chain and signing ────────────────────────────────────────────────

mut_cosign_referrers_mode() {
	# The no-op flag whose presence in one call site and absence in another sent
	# a whole investigation after the storage format instead of the key.
	py_sub "scripts/push-local.sh" \
		'COSIGN_PASSWORD="" cosign sign --yes' \
		'COSIGN_PASSWORD="" cosign sign --registry-referrers-mode=oci-1-1 --yes'
}
register SIGN-REFERRERS-MODE supplychain bats test/cosign-signing-consistency.bats \
	'no cosign sign call site passes --registry-referrers-mode' \
	"scripts/push-local.sh" 'registry-referrers-mode|not ok' mut_cosign_referrers_mode

mut_cosign_sign_by_tag() {
	# Signing a tag races a concurrent re-push: the tag can move between the push
	# and the sign, leaving the signature on a digest nobody serves. This is the
	# flux-system stall's neighbour — a signature that exists but not where the
	# consumer looks.
	#
	# `cosign sign` takes MULTIPLE image references, so this signs the moving tag
	# AND the digest. The tag half carries the full defect: the signature lands
	# wherever :signed points at that instant, and a concurrent push moves it.
	#
	# The reference used is the tag this script pushed four lines earlier and
	# already has in hand. The earlier version of this mutation injected
	# "${REGISTRY}/demo:latest" — a variable that does not exist in this file,
	# under `set -euo pipefail`. That models a crash, not a signing defect, and a
	# mutation whose injected code could never ship is not evidence about
	# anything. Verified by hand on 2026-08-16: the guard is green under BOTH
	# forms, so the finding does not depend on this correction — but the
	# correction is what makes the finding quotable.
	py_sub "scripts/admission-demo.sh" \
		'  "${REGISTRY_HOST}/acme/images/listener@${SIGNED_DIGEST}"' \
		'  "${REGISTRY_HOST}/acme/images/listener:signed" \
  "${REGISTRY_HOST}/acme/images/listener@${SIGNED_DIGEST}"'
}
register SIGN-BY-TAG supplychain bats test/cosign-signing-consistency.bats \
	'every cosign sign call site signs by digest, never by tag' \
	"scripts/admission-demo.sh" 'not a digest reference|not ok' mut_cosign_sign_by_tag

ctl_cosign_pure_tag() {
	# The control: sign a tag INSTEAD of the digest, rather than alongside it.
	# Measured — this goes red, which is what proves the guard above is live and
	# that the green on the subtle mutation is a blind spot rather than decoration.
	py_sub "scripts/admission-demo.sh" \
		'"${REGISTRY_HOST}/acme/images/listener@${SIGNED_DIGEST}"' \
		'"${REGISTRY_HOST}/acme/images/listener:signed"'
}
register_control ctl_cosign_pure_tag

# ── Authorization boundary ──────────────────────────────────────────────────

NGINX_CONF="d2-signalloom/apps/dashboard-signalloom/nginx.conf"

mut_nginx_unauth_mutable_location() {
	# A NEW proxy location that neither forwards Authorization nor restricts
	# methods. This is byte-for-byte the shape of the /supercred-api/ hole: any
	# browser that could load the dashboard could POST through it, borrowing the
	# proxy's ServiceAccount identity with no credential of its own.
	py_insert_before "$NGINX_CONF" \
		'  location /supercred-api/' \
		'  location /new-unguarded-api/ {
    proxy_pass http://afm-platform.fe-k8s-afm.svc.cluster.local:8000/;
  }

'
}
register AUTHZ-NEW-UNGUARDED-LOCATION authz bats \
	d2-signalloom/test/nginx-unauthenticated-locations-are-readonly.bats \
	'no UNDECLARED proxy location drops Authorization while accepting mutation' \
	"$NGINX_CONF" 'unauthenticated proxy location|not ok' mut_nginx_unauth_mutable_location

mut_nginx_remove_limit_except() {
	# Deletes the three lines that closed unauthenticated pod-stun. Before this
	# guard existed, `limit_except` appeared in exactly one file in the whole
	# repository and in no test — so removing it reopened the hole while every
	# suite stayed green.
	py_sub "$NGINX_CONF" 'limit_except GET HEAD' 'limit_except GET HEAD POST PUT DELETE PATCH'
}
register AUTHZ-SUPERCRED-MUTATION-REOPENED authz bats \
	d2-signalloom/test/nginx-unauthenticated-locations-are-readonly.bats \
	'the /supercred-api/ prefix specifically is still mutation-denied' \
	"$NGINX_CONF" 'not ok' mut_nginx_remove_limit_except

mut_route_collision() {
	# An nginx proxy prefix that shadows a client-side SPA route. The server
	# answers first, the route becomes unreachable, and nothing in the SPA knows.
	py_insert_before "$NGINX_CONF" \
		'  location /supercred-api/' \
		'  location /agents {
    proxy_pass http://afm-platform.fe-k8s-afm.svc.cluster.local:8000/;
  }

'
}
register AUTHZ-ROUTE-COLLISION authz bats \
	d2-signalloom/test/dashboard-route-collisions.bats \
	'no proxy prefix shadows a SPA route' \
	"$NGINX_CONF" 'not ok' mut_route_collision

# ── Key-path safety ─────────────────────────────────────────────────────────

mut_keys_dir_concat() {
	# Concatenating a prefix onto an already-absolute KEYS_DIR produces
	# /repo//home/andy/... — the regression audit-anchor-keys-path.bats was
	# written for. It fails as "key not found", which reads as an unsigned
	# artifact rather than as a path bug.
	py_append "Makefile" '
guard-falsification-probe: ## injected by guard-falsification-proof.sh
	@echo $(REPO_ROOT)/$(KEYS_DIR)/cosign.key
'
}
register KEYS-DIR-CONCAT keys bats test/keys-dir-path-safety.bats \
	'no Makefile line concatenates a prefix onto' \
	"Makefile" 'not ok' mut_keys_dir_concat

# ── CI honesty ──────────────────────────────────────────────────────────────

PIPELINE="scripts/ci/vm-pipeline.sh"
# The second runner of root-level suites. The CI lane and the demo lane register
# overlapping but NOT identical sets, and reading only one of them counts every
# suite the other owns as invoked by nothing.
DEMO_PIPELINE="scripts/gcp-tf/demo-pipeline.sh"
CONVERTER="scripts/ci/openreports-convert.sh"

mut_ci_orphan_structured_report() {
	# A structured report the pipeline writes and the converter does not map is
	# silently dropped from the OpenReports artifact. The stage runs, the tests
	# pass, and the results reach nobody.
	py_append "$PIPELINE" '
run_stage \
  "Injected orphan stage" \
  "stage9z-orphan.txt" \
  "cd ${WORK_DIR} && npx playwright test --junit-xml=${REPORT_DIR}/stage9z-orphan.xml"
'
}
register CI-ORPHAN-REPORT ci-honesty bats test/ci-report-integrity.bats \
	'every structured report the pipeline produces is mapped in the converter' \
	"$PIPELINE" 'not in the converter map|not ok' mut_ci_orphan_structured_report

mut_ci_stale_converter_entry() {
	# The mirror image: a converter map entry for a file no stage produces. It
	# reads as a stage that runs and never does, and it would silently "match"
	# if someone reintroduced the filename for something else entirely.
	py_sub "$CONVERTER" \
		"  { file: 'stage1-static.tap'" \
		"  { file: 'stage9z-deleted-long-ago.tap', parser: parseTap, source: 'ghost', category: 'meta' },
  { file: 'stage1-static.tap'"
}
register CI-STALE-CONVERTER-ENTRY ci-honesty bats test/ci-report-integrity.bats \
	'every converter map entry names a file the pipeline actually produces' \
	"$CONVERTER" 'no pipeline stage produces|not ok' mut_ci_stale_converter_entry

mut_ci_parser_format_mismatch() {
	# parseTap on a non-TAP file matches nothing and contributes ZERO rows while
	# the entry reads as configured. Worse than no entry, for exactly that reason.
	py_sub "$CONVERTER" \
		"{ file: 'stage1-static.tap',     parser: parseTap," \
		"{ file: 'stage1-static.tap',     parser: parseJunitXml,"
}
register CI-PARSER-MISMATCH ci-honesty bats test/ci-report-integrity.bats \
	'no converter entry uses parseTap on a non-TAP file' \
	"$CONVERTER" 'mismatched file/parser|not ok' mut_ci_parser_format_mismatch

mut_ci_relative_path_var() {
	# A CI path variable holding a relative value resolves against whatever cwd
	# the stage happens to have. The VM's cwd is not ours.
	py_sub "Makefile" 'GCP_CI_REPORT_DIR=$(abspath ci-reports-2)' 'GCP_CI_REPORT_DIR=ci-reports-2'
}
register CI-RELATIVE-PATH ci-honesty bats test/ci-path-anchoring.bats \
	'no CI path variable is assigned a relative value in the Makefile' \
	"Makefile" 'not ok' mut_ci_relative_path_var

mut_ci_installer_unpinned() {
	# `@latest` in an installer makes the CI toolchain a moving target: the same
	# commit produces different results on different days, and the bisect that
	# chases it finds nothing.
	py_sub "scripts/ci/install-ci-tools.sh" 'COSIGN_VERSION="3.0.6"' 'COSIGN_VERSION="latest"'
}
register CI-UNPINNED-VERSION ci-honesty bats test/ci-installer-privileges.bats \
	'pinned versions are literal, never latest or a branch' \
	"scripts/ci/install-ci-tools.sh" 'not ok' mut_ci_installer_unpinned

# ── Test-suite honesty (the guards that guard the guards) ───────────────────

mut_unregistered_bats_suite() {
	# A .bats suite no runner invokes. Thirty-three of sixty-eight suites and
	# roughly 640 assertions sat in that state in this repository, committed and
	# never executed — among them the suite four documents call "the enforcement
	# mechanism for nginx route collisions".
	py_create "test/zz-injected-orphan-suite.bats" '#!/usr/bin/env bats

@test "injected orphan suite that no runner invokes" {
	[ 1 -eq 1 ]
}
'
}
register META-UNREGISTERED-SUITE meta bats \
	d2-signalloom/test/bats-registry-coverage.bats \
	'every repo-root bats suite is invoked by the CI pipeline' \
	"test/zz-injected-orphan-suite.bats" 'not ok' mut_unregistered_bats_suite

mut_uninvoked_proof_script() {
	# The third shape of the same hole: a proof script under test/ that nothing
	# runs. audit-guard-reintroduction-proof.sh sat in exactly this state — the
	# only thing in the repository proving the audit guards work at all, invoked
	# by nothing, and invisible to the bats registry because it is not a .bats
	# file.
	py_create "test/zz-injected-orphan-proof.sh" '#!/usr/bin/env bash
# Injected by guard-falsification-proof.sh. No runner invokes this.
exit 0
'
}
register META-UNINVOKED-PROOF meta bats \
	d2-signalloom/test/bats-registry-coverage.bats \
	'every proof script under test/ is invoked by something' \
	"test/zz-injected-orphan-proof.sh" 'no runner invokes|not ok' mut_uninvoked_proof_script

COMMENT_ONLY_PROOF="test/zz-injected-comment-only-proof.sh"

mut_proof_mentioned_only_in_a_comment() {
	# The documented defect shape, aimed at the guard that enforces wiring.
	#
	# A CI-wiring assertion that greps a pipeline file for a script NAME has
	# already shipped broken here once: the stage's own comment contained the
	# name, so deleting the real invocation left the test green. This guard's
	# implementation is
	#
	#     grep -rl --include='*.sh' --include='Makefile' --exclude="$base" \
	#          -F "$base" "$root/scripts" "$root/Makefile" "$root/d2-signalloom"
	#
	# and its comment two lines above says "Search every runner, ignoring
	# comments". Nothing in that command ignores comments. The comment describes
	# a filter the code does not have — so this case injects an orphan proof
	# script whose name appears in the pipeline ONLY inside a comment, and asks
	# whether the guard notices that nothing runs it.
	snapshot "$PIPELINE"
	py_create "$COMMENT_ONLY_PROOF" '#!/usr/bin/env bash
# Injected by the falsification harness. Mentioned in a comment, run by nothing.
exit 0
'
	py_append "$PIPELINE" '
# Injected by the falsification harness: zz-injected-comment-only-proof.sh is
# named on this line and invoked on none. If the wiring guard treats this as
# coverage, a commented-out stage counts as a running stage.
'
}
register META-PROOF-COMMENT-ONLY meta bats \
	d2-signalloom/test/bats-registry-coverage.bats \
	'every proof script under test/ is invoked by something' \
	"$COMMENT_ONLY_PROOF" 'no runner invokes|not ok' mut_proof_mentioned_only_in_a_comment

ctl_proof_orphan_no_comment() {
	# Control: the identical orphan script, with no mention anywhere. Must go red.
	py_create "$COMMENT_ONLY_PROOF" '#!/usr/bin/env bash
# Injected by the falsification harness. Mentioned nowhere, run by nothing.
exit 0
'
}
register_control ctl_proof_orphan_no_comment

mut_unregistered_playwright_spec() {
	# A Playwright spec matching no project's testMatch is silently skipped —
	# exit 0, no warning. Four specs hid that way.
	py_create "test/acceptance/zz-injected-orphan.spec.ts" "import { test, expect } from '@playwright/test';

test('injected orphan spec with no registry row', async () => {
  expect(1).toBe(1);
});
"
}
register META-UNREGISTERED-SPEC meta bats test/acceptance-spec-coverage.bats \
	'every spec on disk has exactly one registry row' \
	"test/acceptance/zz-injected-orphan.spec.ts" 'not ok' mut_unregistered_playwright_spec

# The banned verb is ASSEMBLED, never spelled out, for the same reason
# no-exec-probes-in-tests.bats assembles it in its own `exec_verb()`: this file
# is a *.sh inside a test/ directory, so it is IN THAT GUARD'S SCAN SCOPE. A
# literal below makes this harness report itself, which it did on the first real
# run — the guard was red at baseline, the case was correctly recorded UNKNOWN,
# and the culprit was this file. Spelling it out would force this file onto the
# guard's allowlist, and a self-exemption is the one entry nobody would question.
exec_verb() { printf 'e%s' 'xec'; }

mut_exec_probe_reintroduced() {
	# A probe that runs INSIDE the container fails identically whether the
	# property holds or not, the moment the image is hardened. The original
	# instance PASSED while testing nothing — and it was the auth test.
	py_append "test/healthcheck.bats" "
@test \"injected $(exec_verb) probe with no allowlist entry\" {
	run kubectl -n inf-signalloom $(exec_verb) deployment/cardvault -- wget -q -O- http://localhost:8080/
	[ \"\$status\" -ne 0 ]
}
"
}
# The FILTER is assembled too, not just the mutation. The first real run of this
# harness recorded META-EXEC-PROBE as UNKNOWN — "guard was NOT GREEN on an
# unmutated tree" — and the guard's own output named the culprit:
#
#   # kubectl exec used as a probe in test file(s) with no allowlist entry:
#   # test/guard-falsification-proof.sh:567: 'no test file outside the allowlist
#   #                                         probes with kubectl exec' \
#
# The mutation had been carefully assembled via exec_verb() and the filter string
# three lines below it spelled the verb out in full, so this file reported itself
# and lost the case. Every literal in this file is in that guard's scan scope,
# registry strings included.
register META-EXEC-PROBE meta bats test/no-exec-probes-in-tests.bats \
	"no test file outside the allowlist probes with kubectl $(exec_verb)" \
	"test/healthcheck.bats" 'with no allowlist entry|not ok' mut_exec_probe_reintroduced

mut_exec_allowlist_count_drift() {
	# The allowlist pins a COUNT, not a path. Without that, an entry is a blanket
	# exemption and the next probe added to an already-listed file inherits the
	# pass — including one of exactly the shape the guard exists to ban.
	py_append "d2-signalloom/test/supercred-demo.bats" "
@test \"injected extra probe in an already-allowlisted file\" {
	run kubectl -n inf-signalloom $(exec_verb) deployment/openbao -- bao kv get secret/injected
	[ \"\$status\" -eq 0 ]
}
"
}
register META-ALLOWLIST-COUNT-DRIFT meta bats test/no-exec-probes-in-tests.bats \
	'every allowlisted file has exactly its recorded number of occurrences' \
	"d2-signalloom/test/supercred-demo.bats" 'no longer match|not ok' mut_exec_allowlist_count_drift

mut_ci_build_parity_drop() {
	# The real-tree half of ci-build-parity. A build step present in the Makefile
	# recipe and missing from the pipeline is how a workload reached a VM in
	# ImagePullBackOff and failed three stages forty minutes into a lane.
	py_sub "$PIPELINE" 'make demo-signalloom-supercred-images' 'true # make demo-signalloom-supercred-images'
}
register CI-BUILD-PARITY-REAL ci-honesty bats test/ci-build-parity.bats \
	"PARITY the repo's own pipeline builds everything demo-signalloom-up builds" \
	"$PIPELINE" 'MISSING|not ok' mut_ci_build_parity_drop

ctl_ci_build_parity_delete() {
	# The control: delete the invocation line outright, leaving the pipeline's
	# explanatory FULL-LINE comment about the same step in place.
	#
	# Measured — this goes RED. That is the whole point: check-ci-build-parity.sh
	# does strip full-line comments, so a surviving comment does NOT rescue a
	# deleted step.
	#
	# This control earned its keep. It was what separated "live guard, one narrow
	# blind spot" from "decoration", and the two repairs are not the same repair:
	# the first gets a filter widened, the second gets the guard rewritten. The
	# gap it isolated — full-line comments stripped, TRAILING comments not, so
	# `sed -E 's/.*make[[:space:]]+//'` lifted the step name back out of dead
	# text — is closed as of 2026-08-16 by strip_shell_comments() in the guard.
	# The subtle mutation now goes red on its own, so this control no longer runs
	# (the harness only reaches a control when the guard stays green). It stays
	# registered anyway: it is the regression lock on the classification, and a
	# control that never fires costs nothing while a missing one costs a wrong
	# verdict.
	MUT_FILE="$PIPELINE" python3 - <<-'PY'
		import os, sys, pathlib
		p = pathlib.Path(os.environ["MUT_FILE"])
		lines = p.read_text().splitlines(keepends=True)
		inv = [i for i, l in enumerate(lines)
		       if "demo-signalloom-supercred-images" in l and not l.lstrip().startswith("#")]
		if len(inv) != 1:
		    sys.stderr.write("expected exactly 1 live invocation line, found %d\n" % len(inv))
		    sys.exit(3)
		del lines[inv[0]]
		p.write_text("".join(lines))
	PY
}
register_control ctl_ci_build_parity_delete

# The same defect measured one layer down, through the `sh` guard kind rather
# than through the bats wrapper. This localises the blind spot: if the bats case
# above and this one both stay green on the trailing-comment mutation, the gap is
# in check-ci-build-parity.sh itself and not in how the suite calls it. It also
# exercises the harness's `sh` code path against a real guard — that path had no
# registered case at all until now, which in a tool about untested checks was an
# untested branch of the tool itself.
register CI-BUILD-PARITY-SCRIPT ci-honesty sh scripts/check-ci-build-parity.sh \
	'' "$PIPELINE" 'MISSING' mut_ci_build_parity_drop
register_control ctl_ci_build_parity_delete

# The same guard aimed at the half of the recipe it could not see until now.
# check-ci-build-parity.sh read `$(MAKE)` lines only, so demo-signalloom-up's two
# closing script invocations were outside the comparison — and the guard printed
# a pass over a pipeline missing the only step that activates the Agent Trust
# slice. A from-scratch run then reached 21/27 stages with zero of six
# agent-trust-* namespaces, reporting the failure against signalloom-infra.
#
# Deleting the line rather than commenting it: the trailing-comment variant is
# already proven for `make` by mut_ci_build_parity_drop above, and both extractors
# share one strip_shell_comments.
mut_ci_build_parity_activation_drop() {
	# Line-precise, not py_sub. py_sub replaces the FIRST occurrence, and the
	# invocation now sits under a thirty-line comment block that discusses it —
	# add one backticked mention of the literal and py_sub would silently mutate
	# the prose while the live step kept running, scoring the guard green on a
	# tree that was never mutated.
	MUT_FILE="$PIPELINE" python3 - <<-'PY'
		import os, sys, pathlib
		p = pathlib.Path(os.environ["MUT_FILE"])
		lines = p.read_text().splitlines(keepends=True)
		inv = [i for i, l in enumerate(lines)
		       if l.strip() == "./scripts/agent-trust-local.sh up"]
		if len(inv) != 1:
		    sys.stderr.write("expected exactly 1 live invocation line, found %d\n" % len(inv))
		    sys.exit(3)
		del lines[inv[0]]
		p.write_text("".join(lines))
	PY
}
register CI-BUILD-PARITY-ACTIVATION ci-honesty bats test/ci-build-parity.bats \
	"PARITY the repo's pipeline activates the Agent Trust slice, in recipe order" \
	"$PIPELINE" 'MISSING|not ok' mut_ci_build_parity_activation_drop

mut_ci_build_parity_activation_early() {
	# Present but early, which is the worse of the two failures: the activation
	# snapshots its sibling ResourceSets' inputs and restores them after a fleet
	# refresh that reapplies `inputs: []`, so it must observe them ACTIVE. Run
	# before the handover it snapshots nothing, and preflight_bao then waits its
	# full 600s on a signalloom-infra that will never go Ready — a ten-minute
	# hang where the omission at least failed fast.
	MUT_FILE="$PIPELINE" python3 - <<-'PY'
		import os, sys, pathlib
		p = pathlib.Path(os.environ["MUT_FILE"])
		lines = p.read_text().splitlines(keepends=True)
		inv = [i for i, l in enumerate(lines)
		       if l.strip() == "./scripts/agent-trust-local.sh up"]
		anc = [i for i, l in enumerate(lines)
		       if "signalloom-local.sh up" in l and not l.lstrip().startswith("#")]
		if len(inv) != 1 or not anc:
		    sys.stderr.write("expected 1 invocation and >=1 anchor, found %d/%d\n"
		                     % (len(inv), len(anc)))
		    sys.exit(3)
		line = lines.pop(inv[0])
		p.write_text("".join(lines[:anc[0]] + [line] + lines[anc[0]:]))
	PY
}
register CI-BUILD-PARITY-ACTIVATION-ORDER ci-honesty bats test/ci-build-parity.bats \
	"PARITY the repo's pipeline activates the Agent Trust slice, in recipe order" \
	"$PIPELINE" 'TOO EARLY|not ok' mut_ci_build_parity_activation_early

# ── Kind cluster config safety ──────────────────────────────────────────────

mut_kind_command_substitution() {
	# The kind config heredoc is UNQUOTED, so its contents are live shell. A
	# command substitution there executes at cluster-create time with whatever
	# privileges the operator has.
	py_sub "scripts/create-kind-cluster.sh" 'kind: Cluster' 'kind: Cluster # $(id -un)'
}
register KIND-COMMAND-SUBSTITUTION supplychain bats test/kind-config-heredoc.bats \
	'no command substitution in the heredoc' \
	"scripts/create-kind-cluster.sh" 'not ok' mut_kind_command_substitution

# ── Property oracles: is the injected defect actually a defect? ─────────────
#
# This layer exists because a verdict from this harness was proven wrong, and
# the guard it accused was innocent.
#
# SIGN-BY-TAG mutated `cosign sign` by ADDING an image reference next to the
# digest that was already there. The guard asks whether the invocation carries a
# digest; it still did, so it stayed green, and the harness printed
# "GUARD DID NOT FIRE". Every phase had passed: the anchor matched, the file
# changed, the checksum moved, the tree restored. The harness had proof that it
# had edited a file and no proof whatsoever that it had injected a DEFECT.
#
# That is the same shape as every entry in this file's own catalogue — a check
# that runs, reports success, and measured nothing — committed by the tool built
# to find it. "The bytes changed" is not "the property is violated".
#
# So each case now carries an ORACLE: an independent statement of the property,
# over the target, that prints how many units VIOLATE it.
#
#   clean tree      the oracle MUST print 0. Otherwise the property does not
#                   hold at baseline, the case is measuring something else, and
#                   the verdict is UNKNOWN rather than a finding.
#   after mutation  the oracle MUST print >= 1. If it does not, the mutation
#                   injected no defect, and the case is UNFAITHFUL — a HARNESS
#                   bug, reported in its own category and never as a guard that
#                   failed to fire. That distinction is the entire point: the
#                   two are indistinguishable from the outside and they have
#                   opposite repairs.
#
# On circularity, which is the obvious objection. An oracle that greps for the
# string the mutation just injected would call every mutation faithful and prove
# nothing — the vacuous-check shape again, one level up. Two things stop it:
#
#   1. Each oracle is written as the PROPERTY, over the target file, and never
#      mentions the injected literal. assert_oracles_are_not_tautologies()
#      enforces that mechanically at startup by diffing the injected text
#      against the oracle's own source.
#   2. The oracle answers "is the defect really present here", derived directly
#      and locally. The guard answers "does a tree-wide scan still FIND it".
#      Those differ exactly where this repository keeps getting hurt — a correct
#      checker pointed at nothing — so they are not the same question and their
#      disagreement is informative.
#
# Oracles are deliberately re-derived rather than sharing the guards' helper
# functions. An oracle that calls the guard's own collector cannot disagree with
# the guard, and disagreement is the only thing it is for.

orc_rbac_dangling_sa() {
	ORC_FILE="$FLEET_TENANT" python3 - <<-'PY'
		import os, re, pathlib
		src = pathlib.Path(os.environ["ORC_FILE"]).read_text()
		# A SUBJECT is a list item: "- kind: ServiceAccount" then "name:".
		subs = re.findall(r'-\s+kind:\s*ServiceAccount\s*\n\s*name:\s*(\S+)', src)
		# A DECLARATION is a mapping whose metadata carries the name.
		#
		# The first version of this oracle collected EVERY `name:` in the fleet as
		# a declaration, which counts each subject as its own declaration — so the
		# renamed subject resolved to the typo it had just become and the oracle
		# reported zero violations for the exact defect it was written to detect.
		# It was caught by the baseline gate demanding 0 on a clean tree and then
		# >=1 after the mutation, which is the whole argument for having the gate.
		declared = set()
		for root in ("d2-osramp-fleet", "d2-signalloom", "d2-osramp-apps", "olly-replica"):
		    rp = pathlib.Path(root)
		    if not rp.is_dir():
		        continue
		    for p in rp.rglob("*.yaml"):
		        try:
		            txt = p.read_text()
		        except OSError:
		            continue
		        for m in re.finditer(r'(?<!-\s)\bkind:\s*ServiceAccount\s*\n\s*metadata:\s*\n((?:\s+\S.*\n)+)', txt):
		            nm = re.search(r'^\s*name:\s*(\S+)', m.group(1), re.M)
		            if nm:
		                declared.add(nm.group(1))
		        for m in re.finditer(r'metadata:\s*\{\s*name:\s*([^,}\s]+)', txt):
		            declared.add(m.group(1))
		# Kubernetes creates `default` in every namespace; no manifest declares it.
		# Named, never pattern-matched — "looks built-in" is not something an
		# oracle should be guessing at.
		declared.add("default")
		print(sum(1 for s in subs if s not in declared))
	PY
}

orc_rbac_discovery() {
	# Scoped to d2-signalloom AND d2-osramp-fleet, not d2-signalloom alone.
	# 141a757f (2026-08-01, "move agent namespace + RBAC into signalloom-infra
	# ResourceSet") relocated the fe-signalloom-agents Role/RoleBinding pair out
	# of d2-signalloom entirely, into the signalloom-infra ResourceSet at
	# d2-osramp-fleet/tenants/local/signalloom.yaml -- deliberately, for two
	# independent reasons documented in
	# d2-signalloom/apps/fleet-manager/base/rbac.yaml: the signalloom-apps
	# Kustomization's targetNamespace override would silently misapply a Role
	# declared for the agents namespace, and the namespace-scoped flux
	# ServiceAccount lacks `escalate`, so a RoleBinding whose roleRef can't
	# resolve aborts kustomize-controller's whole server-dry-run.
	#
	# This oracle was written two weeks later (1216c97c, 2026-08-16) and never
	# learned about the new location, so it reported the relocated grant as
	# ungranted from the day it was written -- a false positive in the oracle,
	# not a gap in product RBAC. Widening the search path is the fix; the RBAC
	# itself stays exactly where 141a757f put it.
	ORC_FILE="d2-signalloom/apps/fake-integration-proxy/server.py" python3 - <<-'PY'
		import os, re, pathlib, subprocess
		src = pathlib.Path(os.environ["ORC_FILE"]).read_text()
		m = re.search(r'DEFAULT_AGENT_DISCOVERY_NAMESPACES\s*=\s*\(([^)]*)\)', src)
		nss = re.findall(r'"([^"]+)"', m.group(1)) if m else []
		granted = subprocess.run(
		    ["grep", "-rl", "-e", "kind: Role", "--include=*.yaml",
		     "d2-signalloom", "d2-osramp-fleet"],
		    capture_output=True, text=True).stdout.split()
		bad = 0
		for ns in nss:
		    if not any(ns in pathlib.Path(f).read_text() for f in granted):
		        bad += 1
		print(bad)
	PY
}

# Fold `cosign sign` invocations in a file into single logical lines.
# Deliberately re-derived here rather than reusing the guard's awk: an oracle
# that shares the guard's collector cannot disagree with it, and disagreement
# is the only thing it is for.
_cosign_invocations() {
	ORC_FILE="$1" python3 - <<-'PY'
		import os, re, pathlib
		txt = pathlib.Path(os.environ["ORC_FILE"]).read_text()
		txt = re.sub(r'(?m)#.*$', '', txt)
		txt = txt.replace("\\\n", " ")
		for line in txt.split("\n"):
		    if re.search(r'cosign\s+sign(\s|$)', line):
		        print(re.sub(r'\s+', ' ', line.strip()))
	PY
}

orc_sign_referrers() {
	local n=0 line
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		case "$line" in *registry-referrers-mode*) n=$((n + 1)) ;; esac
	done <<< "$(_cosign_invocations "scripts/push-local.sh")"
	printf '%s' "$n"
}

# Every IMAGE REFERENCE argument of every `cosign sign` invocation must be a
# digest reference. Note "every", not "at least one": an invocation carrying a
# digest AND a tag signs the tag too, and the tag can move under a concurrent
# push. Positional arguments only — flag values such as --key "${KEYS_DIR}/…"
# contain a slash and are not image references.
orc_sign_by_tag() {
	ORC_FILE="scripts/admission-demo.sh" python3 - <<-'PY'
		import os, re, pathlib, shlex
		txt = pathlib.Path(os.environ["ORC_FILE"]).read_text()
		txt = re.sub(r'(?m)#.*$', '', txt).replace("\\\n", " ")
		VALUE_FLAGS = {"--key", "--signing-config", "--output", "--cert", "--certificate"}
		bad = 0
		for line in txt.split("\n"):
		    if not re.search(r'cosign\s+sign(\s|$)', line):
		        continue
		    try:
		        toks = shlex.split(line, posix=False)
		    except ValueError:
		        continue
		    skip = False
		    for t in toks[toks.index("sign") + 1:] if "sign" in toks else []:
		        if skip:
		            skip = False
		            continue
		        if t.startswith("-"):
		            if t.split("=")[0] in VALUE_FLAGS and "=" not in t:
		                skip = True
		            continue
		        ref = t.strip('"\'')
		        if "/" not in ref:
		            continue
		        if "@" not in ref:          # a tag reference, or a bare name
		            bad += 1
		print(bad)
	PY
}

# Reuse the guard-independent nginx location parser for the authz oracles.
_nginx_matrix() {
	ORC_FILE="$NGINX_CONF" python3 - <<-'PY'
		import os, re, pathlib
		src = re.sub(r'#[^\n]*', '', pathlib.Path(os.environ["ORC_FILE"]).read_text())
		depth, stack, out = 0, [], []
		for line in src.split("\n"):
		    m = re.search(r'location\s+([^\s{]+)\s*{', line)
		    if m and 'limit_except' not in line:
		        stack.append([m.group(1), depth, []])
		    elif stack:
		        stack[-1][2].append(line)
		    depth += line.count('{') - line.count('}')
		    while stack and depth <= stack[-1][1]:
		        prefix, _, body = stack.pop()
		        text = "\n".join(body)
		        fwd = bool(re.search(r'proxy_set_header\s+Authorization\s+\$http_authorization', text))
		        le = re.search(r'limit_except\s+([A-Z\s]+)\{([^}]*)\}', text)
		        denied = bool(le and re.search(r'deny\s+all', le.group(2))
		                      and set(le.group(1).split()) <= {'GET', 'HEAD', 'OPTIONS'})
		        if 'proxy_pass' in text:
		            out.append("%s\t%d\t%d" % (prefix, fwd, denied))
		print("\n".join(out))
	PY
}

# Locations that neither forward Authorization nor deny mutation, minus the
# ones this repository has written down as a deliberate decision.
_NGINX_DECLARED_UNGUARDED='/dex/ /dashboard/ /afm/ /clusters /metrics/ /health /jobs /webhooks/'

orc_authz_unguarded() {
	local n=0 prefix fwd denied
	while IFS=$'\t' read -r prefix fwd denied; do
		[ -n "$prefix" ] || continue
		[ "$fwd" = "0" ] && [ "$denied" = "0" ] || continue
		case " $_NGINX_DECLARED_UNGUARDED " in *" $prefix "*) continue ;; esac
		n=$((n + 1))
	done <<< "$(_nginx_matrix)"
	printf '%s' "$n"
}

orc_authz_supercred() {
	local prefix fwd denied
	while IFS=$'\t' read -r prefix fwd denied; do
		if [ "$prefix" = "/supercred-api/" ]; then
			[ "$denied" = "1" ] && printf '0' || printf '1'
			return 0
		fi
	done <<< "$(_nginx_matrix)"
	printf '1'   # the block is gone entirely: also a violation
}

orc_route_collision() {
	ORC_NGINX="$NGINX_CONF" ORC_APP="d2-signalloom/apps/dashboard-signalloom/src/App.tsx" python3 - <<-'PY'
		import os, re, pathlib
		src = pathlib.Path(os.environ["ORC_NGINX"]).read_text()
		proxy = set()
		for m in re.finditer(r'location\s+(=\s*)?(\S+)\s*\{', src):
		    path, start = m.group(2), m.end()
		    depth, i = 1, start
		    while i < len(src) and depth:
		        depth += (src[i] == "{") - (src[i] == "}")
		        i += 1
		    if "proxy_pass" not in src[start:i] or path == "/":
		        continue
		    seg = path.lstrip("/").split("/")[0]
		    if seg:
		        proxy.add(seg)
		spa = set()
		for path in re.findall(r'path="([^"]+)"', pathlib.Path(os.environ["ORC_APP"]).read_text()):
		    if not path.startswith("/") or path == "/":
		        continue
		    seg = path.lstrip("/").split("/")[0]
		    if seg and not seg.startswith(":"):
		        spa.add(seg)
		print(len(proxy & spa))
	PY
}

orc_keys_concat() {
	local n
	n="$(grep -vE '^[[:space:]]*#' Makefile | grep -cE '[^ 	="'"'"'(]/\$\(KEYS_DIR\)' || true)"
	printf '%s' "${n:-0}"
}

# ---- CI report integrity: derive both sides independently of the guard -----
_pipeline_structured() {
	ORC_FILE="$PIPELINE" python3 - <<-'PY'
		import os, re, pathlib
		txt = pathlib.Path(os.environ["ORC_FILE"]).read_text()
		out = set()
		for m in re.findall(r'(?:--junit-xml=|--outputFile=|JUNIT_OUTPUT_FILE=|-o\s+)\S*?([A-Za-z0-9._-]+\.(?:xml|json))', txt):
		    out.add(m)
		print("\n".join(sorted(out)))
	PY
}
_pipeline_all_outputs() {
	ORC_FILE="$PIPELINE" python3 - <<-'PY'
		import os, re, pathlib
		txt = pathlib.Path(os.environ["ORC_FILE"]).read_text()
		print("\n".join(sorted(set(re.findall(r'([A-Za-z0-9._-]+\.(?:txt|tap|json|xml))', txt)))))
	PY
}
_converter_mapped() {
	ORC_FILE="$CONVERTER" python3 - <<-'PY'
		import os, re, pathlib
		txt = pathlib.Path(os.environ["ORC_FILE"]).read_text()
		print("\n".join(re.findall(r"^\s*\{\s*file:\s*'([^']+)'", txt, re.M)))
	PY
}

orc_ci_orphan_report() {
	local n=0 f mapped
	mapped="$(_converter_mapped)"
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		grep -qxF "$f" <<< "$mapped" && continue
		grep -q "deliberately NOT mapped" "$CONVERTER" && grep -B3 -A3 'deliberately NOT mapped' "$CONVERTER" | grep -qF "$f" && continue
		n=$((n + 1))
	done <<< "$(_pipeline_structured)"
	printf '%s' "$n"
}

orc_ci_stale_entry() {
	local n=0 f produced
	produced="$(_pipeline_all_outputs)"
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		grep -qxF "$f" <<< "$produced" || n=$((n + 1))
	done <<< "$(_converter_mapped)"
	printf '%s' "$n"
}

orc_ci_parser_mismatch() {
	ORC_FILE="$CONVERTER" python3 - <<-'PY'
		import os, re, pathlib
		txt = pathlib.Path(os.environ["ORC_FILE"]).read_text()
		want = {"parseTap": ".tap", "parseJunitXml": ".xml", "parseGoJson": ".json"}
		bad = 0
		for f, p in re.findall(r"file:\s*'([^']+)'[^}]*?parser:\s*(\w+)", txt):
		    if p in want and not f.endswith(want[p]):
		        bad += 1
		print(bad)
	PY
}

orc_ci_relative_path() {
	local n
	n="$(grep -vE '^[[:space:]]*#' Makefile \
		| grep -oE 'GCP_CI_[A-Z_]*(DIR|PATH|ROOT)=[^ 	]*' \
		| grep -cvE '=(/|\$\(abspath|\$\(CURDIR\)|\$\{CURDIR\})' || true)"
	printf '%s' "${n:-0}"
}

orc_ci_unpinned() {
	local n
	n="$(grep -E '^[A-Z_]+_VERSION="' scripts/ci/install-ci-tools.sh \
		| sed -E 's/^[A-Z_]+_VERSION="([^"]*)".*/\1/' \
		| grep -cvE '^[0-9]+\.[0-9]+\.[0-9]+$' || true)"
	printf '%s' "${n:-0}"
}

# ---- meta -----------------------------------------------------------------
_ROOT_BATS_EXCLUDED='supercred-images.bats agent-trust-lifecycle.bats deployed-staleness.bats signalloom-flux-integration.bats signalloom-preflight.bats test-count-floor.bats'

# ── Registration by GLOB, which a basename grep structurally cannot see ──────
#
# Both meta oracles below asked "does some runner name this file?" and answered
# with a literal grep for the basename. Two runners do not name their files at
# all — they glob them:
#
#   Makefile:1365   $(wildcard test/terraform-*.bats)
#   Makefile:1542   GCP_TF_PROOFS = $(wildcard test/*-mutation-proof.sh)
#                   ...executed via GCP_TF_PROOFS_RUN at Makefile:1904
#
# So every terraform-*.bats suite and every *-mutation-proof.sh script IS
# invoked, and both oracles counted all of them as violations: 34 and 21
# respectively, at baseline, on every machine. A property that does not hold at
# baseline yields no verdict, so META-UNREGISTERED-SUITE, META-UNINVOKED-PROOF
# and META-PROOF-COMMENT-ONLY were recorded UNKNOWN and the whole harness
# exited 3 — three guards permanently unproven because the oracle could not read
# a wildcard. It was NOT a CI-VM condition, though it was first seen there: the
# counts are identical locally.
#
# The exemption is conditional on the glob still being in the Makefile rather
# than a standing exclusion list. Delete the wildcard and these files stop being
# registered, the oracle says so again immediately, and nobody has to remember
# to prune an allowlist.
_glob_registers() {
	grep -qF "$1" Makefile 2>/dev/null
}

orc_meta_unreg_suite() {
	local n=0 f base body
	body="$(sed 's/#.*//' "$PIPELINE")"
	# demo-pipeline.sh is the second runner of root suites, and it is the one
	# that names gcp-demo-pipeline.bats and supervise-port-forward-knobs.bats.
	if [ -r "$DEMO_PIPELINE" ]; then
		body+="$(printf '\n%s' "$(sed 's/#.*//' "$DEMO_PIPELINE")")"
	fi
	for f in test/*.bats; do
		[ -e "$f" ] || continue
		base="$(basename "$f")"
		case " $_ROOT_BATS_EXCLUDED " in *" $base "*) continue ;; esac
		case "$base" in
			terraform-*.bats)
				_glob_registers 'wildcard test/terraform-*.bats' && continue ;;
		esac
		grep -qF "$base" <<< "$body" || n=$((n + 1))
	done
	printf '%s' "$n"
}

# A proof script is invoked when some runner names it on a line that is not a
# comment. Derived here from the shape of the property, not from the guard.
orc_meta_uninvoked_proof() {
	local n=0 f base hit
	for f in test/*.sh; do
		[ -e "$f" ] || continue
		base="$(basename "$f")"
		case "$base" in
			*-mutation-proof.sh)
				_glob_registers 'wildcard test/*-mutation-proof.sh' && continue ;;
		esac
		hit=0
		while IFS= read -r cand; do
			[ -n "$cand" ] || continue
			[ "$(basename "$cand")" = "$base" ] && continue
			if grep -vE '^[[:space:]]*#' "$cand" 2>/dev/null | grep -qF "$base"; then hit=1; break; fi
		done < <(grep -rl --include='*.sh' --include='*.bats' --include='Makefile' -F "$base" \
				scripts test Makefile d2-signalloom 2>/dev/null)
		[ "$hit" -eq 1 ] || n=$((n + 1))
	done
	printf '%s' "$n"
}

orc_meta_unreg_spec() {
	local n=0 f base reg="test/acceptance/SPEC-REGISTRY.tsv"
	[ -f "$reg" ] || { printf '0'; return 0; }
	for f in test/acceptance/*.spec.ts; do
		[ -e "$f" ] || continue
		base="$(basename "$f")"
		grep -qF "$base" "$reg" || n=$((n + 1))
	done
	printf '%s' "$n"
}

# Test files that invoke kubectl's in-container run verb, beyond what the
# guard's allowlist records for them. The allowlist is re-read from the guard's
# data, not its logic.
orc_meta_exec_probe() {
	ORC_VERB="$(exec_verb)" python3 - <<-'PY'
		import os, re, pathlib, subprocess
		verb = os.environ["ORC_VERB"]
		guard = pathlib.Path("test/no-exec-probes-in-tests.bats").read_text()
		allow = {}
		for line in guard.split("\n"):
		    m = re.match(r'^\s*([A-Za-z0-9._/-]+)\|(\d+)\|', line)
		    if m:
		        allow[m.group(1)] = int(m.group(2))
		files = subprocess.run(
		    ["find", ".", "-name", ".git", "-prune", "-o", "-name", ".claude", "-prune",
		     "-o", "-name", ".worktrees", "-prune", "-o", "-name", "node_modules",
		     "-prune", "-o", "-name", "*.bats", "-print", "-o",
		     "-path", "./*/test/*.sh", "-print", "-o", "-path", "./test/*.sh", "-print"],
		    capture_output=True, text=True).stdout.split()
		pat = re.compile(r'kubectl(\s+[^\s;|&]+){0,6}\s+\b%s\b' % verb)
		bad = 0
		for f in sorted(set(x[2:] for x in files if x.startswith("./"))):
		    try:
		        txt = pathlib.Path(f).read_text()
		    except OSError:
		        continue
		    hits = 0
		    for line in txt.split("\n"):
		        line = re.sub(r'^\s*#.*', '', line)
		        line = re.sub(r'^\s*@test\s*"[^"]*"', '@test', line)
		        if pat.search(line):
		            hits += 1
		    if hits == 0:
		        continue
		    if allow.get(f) != hits:
		        bad += 1
		print(bad)
	PY
}

orc_kind_cmdsub() {
	ORC_FILE="scripts/create-kind-cluster.sh" python3 - <<-'PY'
		import os, re, pathlib
		txt = pathlib.Path(os.environ["ORC_FILE"]).read_text()
		body = re.search(r"<<[ ]?EOF\n(.*?)\nEOF", txt, re.S)
		seg = body.group(1) if body else ""
		print(len(re.findall(r'\$\(', seg)) + len(re.findall(r'`', seg)))
	PY
}

# Build steps in the demo-signalloom-up recipe that the CI pipeline does not
# actually invoke.
#
# The first version of this oracle shelled out to check-ci-build-parity.sh —
# which IS the guard for CI-BUILD-PARITY-SCRIPT. An oracle that runs the guard
# agrees with the guard by construction, including in its blind spots, so it
# reported "no violation" for a step the pipeline had genuinely stopped
# building and the case was filed as an unfaithful mutation. A guard cannot be
# its own oracle; that is a tautology with extra steps.
orc_ci_build_parity() {
	python3 - <<-'PY'
		import re, pathlib
		mk = pathlib.Path("Makefile").read_text()
		pipe = pathlib.Path("scripts/ci/vm-pipeline.sh").read_text()
		# Written-down decisions, mirrored from the checker's ALLOWED list: one is
		# runtime-only, one needs a source tree absent from the CI VM.
		ALLOWED = {"netassert-runner-image", "demo-signalloom-afm-up"}

		steps, inrecipe = [], False
		for line in mk.split("\n"):
		    if line.startswith("demo-signalloom-up:"):
		        inrecipe = True
		        continue
		    if not inrecipe:
		        continue
		    if not line.startswith("\t"):
		        if line.strip():
		            break
		        continue
		    body = re.sub(r'^\t+[@+-]*', '', line)
		    if body.lstrip().startswith("#"):
		        continue
		    m = re.search(r'\$\(MAKE\)[ \t]+([A-Za-z0-9_][A-Za-z0-9_.-]*)', body)
		    if m:
		        steps.append(m.group(1))

		# Comments are stripped from the pipeline before looking for invocations,
		# and that IS the property: a step named only inside a comment is built by
		# nothing. An oracle that skipped this would inherit the guard's blind spot
		# instead of measuring it.
		code = "\n".join(re.sub(r'#.*$', '', ln) for ln in pipe.split("\n"))
		missing = 0
		for s in steps:
		    if s in ALLOWED:
		        continue
		    if not re.search(r'\bmake[ \t]+(-[A-Za-z]+[ \t]+)*%s\b' % re.escape(s), code):
		        missing += 1
		print(missing)
	PY
}

# The same property for the recipe's SCRIPT steps, which the $(MAKE)-only oracle
# above cannot see any more than the guard could. Independently parsed, for the
# reason recorded above orc_ci_build_parity: an oracle that shells out to the
# checker inherits the checker's blind spots and certifies them.
#
# The verb is part of the identity here too. `agent-trust-local.sh down` is a
# teardown, and an oracle matching the path alone would score it as the bring-up.
orc_ci_parity_activation() {
	python3 - <<-'PY'
		import re, pathlib
		mk = pathlib.Path("Makefile").read_text()
		pipe = pathlib.Path("scripts/ci/vm-pipeline.sh").read_text()

		steps, inrecipe = [], False
		for line in mk.split("\n"):
		    if line.startswith("demo-signalloom-up:"):
		        inrecipe = True
		        continue
		    if not inrecipe:
		        continue
		    if not line.startswith("\t"):
		        if line.strip():
		            break
		        continue
		    body = re.sub(r'^\t+[@+-]*', '', line)
		    if body.lstrip().startswith("#"):
		        continue
		    m = re.search(r'\./(scripts/[A-Za-z0-9_.-]+\.sh)[ \t]+([A-Za-z0-9_-]+)', body)
		    if m:
		        steps.append((m.group(1), m.group(2)))

		code = "\n".join(re.sub(r'#.*$', '', ln) for ln in pipe.split("\n"))
		missing = 0
		for path, verb in steps:
		    if not re.search(r'\./%s[ \t]+%s\b' % (re.escape(path), re.escape(verb)), code):
		        missing += 1
		print(missing)
	PY
}

# Script steps the recipe runs AFTER its handover to signalloom-local.sh that the
# pipeline runs BEFORE its own. Counted separately from membership because the
# remedies differ and so does the failure: a missing activation fails fast, an
# early one snapshots inputs that are not active yet and hangs for ten minutes.
orc_ci_parity_activation_order() {
	python3 - <<-'PY'
		import re, pathlib
		mk = pathlib.Path("Makefile").read_text()
		pipe = pathlib.Path("scripts/ci/vm-pipeline.sh").read_text()
		ANCHOR = r'signalloom-local\.sh up'

		steps, inrecipe, anchor_at = [], False, None
		for n, line in enumerate(mk.split("\n")):
		    if line.startswith("demo-signalloom-up:"):
		        inrecipe = True
		        continue
		    if not inrecipe:
		        continue
		    if not line.startswith("\t"):
		        if line.strip():
		            break
		        continue
		    body = re.sub(r'^\t+[@+-]*', '', line)
		    if body.lstrip().startswith("#"):
		        continue
		    if anchor_at is None and re.search(ANCHOR, body):
		        anchor_at = n
		    m = re.search(r'\./(scripts/[A-Za-z0-9_.-]+\.sh)[ \t]+([A-Za-z0-9_-]+)', body)
		    if m:
		        steps.append((n, m.group(1), m.group(2)))

		lines = [re.sub(r'#.*$', '', ln) for ln in pipe.split("\n")]
		p_anchor = next((n for n, ln in enumerate(lines) if re.search(ANCHOR, ln)), None)
		bad = 0
		if anchor_at is not None and p_anchor is not None:
		    for n, path, verb in steps:
		        if n <= anchor_at:
		            continue
		        hit = next((i for i, ln in enumerate(lines)
		                    if re.search(r'\./%s[ \t]+%s\b'
		                                 % (re.escape(path), re.escape(verb)), ln)), None)
		        if hit is not None and hit < p_anchor:
		            bad += 1
		print(bad)
	PY
}

# ── Every case must have an oracle ──────────────────────────────────────────
#
# Attached by id, so this block is the only place the oracle layer touches.
attach_oracle RBAC-DANGLING-SA                  orc_rbac_dangling_sa
attach_oracle RBAC-DISCOVERY-UNGRANTED          orc_rbac_discovery
attach_oracle SIGN-REFERRERS-MODE               orc_sign_referrers
attach_oracle SIGN-BY-TAG                       orc_sign_by_tag
attach_oracle AUTHZ-NEW-UNGUARDED-LOCATION      orc_authz_unguarded
attach_oracle AUTHZ-SUPERCRED-MUTATION-REOPENED orc_authz_supercred
attach_oracle AUTHZ-ROUTE-COLLISION             orc_route_collision
attach_oracle KEYS-DIR-CONCAT                   orc_keys_concat
attach_oracle CI-ORPHAN-REPORT                  orc_ci_orphan_report
attach_oracle CI-STALE-CONVERTER-ENTRY          orc_ci_stale_entry
attach_oracle CI-PARSER-MISMATCH                orc_ci_parser_mismatch
attach_oracle CI-RELATIVE-PATH                  orc_ci_relative_path
attach_oracle CI-UNPINNED-VERSION               orc_ci_unpinned
attach_oracle META-UNREGISTERED-SUITE           orc_meta_unreg_suite
# Both proof-script cases assert the SAME property — "no proof script under
# test/ is uninvoked" — and differ only in how the orphan is disguised. One
# oracle, two mutations, which is the correct shape: the property is the thing
# with one definition.
attach_oracle META-UNINVOKED-PROOF              orc_meta_uninvoked_proof
attach_oracle META-PROOF-COMMENT-ONLY           orc_meta_uninvoked_proof
attach_oracle META-UNREGISTERED-SPEC            orc_meta_unreg_spec
attach_oracle META-EXEC-PROBE                   orc_meta_exec_probe
attach_oracle META-ALLOWLIST-COUNT-DRIFT        orc_meta_exec_probe
attach_oracle CI-BUILD-PARITY-REAL              orc_ci_build_parity
attach_oracle CI-BUILD-PARITY-SCRIPT            orc_ci_build_parity
attach_oracle CI-BUILD-PARITY-ACTIVATION        orc_ci_parity_activation
attach_oracle CI-BUILD-PARITY-ACTIVATION-ORDER  orc_ci_parity_activation_order
attach_oracle KIND-COMMAND-SUBSTITUTION         orc_kind_cmdsub

# ── Foreign-edit detection: content hashes, never mtimes ────────────────────
#
# This exists because the harness's operator misread the tree and reported it.
#
# During a run, `test/cosign-signing-consistency.bats` was observed with a fresh
# mtime and a 47-line working-tree diff. That was read as "a second agent is
# editing my worktree", stated as fact, and escalated. It was wrong, and the
# reasoning that produced it was the exact move this whole round exists to stamp
# out: an inference presented as a measurement.
#
# Two things make that misread easy, and both are properties of this tool:
#
#   * A mutation harness writes files constantly and by design. It runs in the
#     one condition where "this file just changed" carries no information at all.
#   * mtime is not evidence either way. `cp -p` PRESERVES timestamps, so a
#     restore leaves mtime untouched — measured: a full --only SIGN-BY-TAG run
#     changed neither the guard's nor the target's mtime. A harness that judged
#     foreignness by mtime would therefore miss its own writes AND flag
#     everyone else's.
#
# So the question "did something other than me change this file?" is answered
# from CONTENT, against a baseline taken before the first mutation, and split
# against the harness's own write log:
#
#   UNRESTORED  the harness wrote this path and failed to put it back. Its bug.
#   FOREIGN     the harness never wrote this path and it changed anyway. Someone
#               or something else did, and every verdict touching it is suspect.
#
# Never diagnose a foreign edit from a timestamp. Diagnose it from a hash, or say
# you do not know.
declare -a WATCH_PATHS=() WATCH_HASHES=()
FOREIGN=0

hash_of() {
	if [ -e "$1" ]; then sha256sum "$1" | cut -d' ' -f1; else printf 'ABSENT'; fi
}

watch_baseline() {
	local i p q seen
	for i in "${!C_ID[@]}"; do
		for p in "${C_GUARD[$i]}" "${C_TARGET[$i]}"; do
			if [ -z "$p" ]; then continue; fi
			seen=0
			for q in "${WATCH_PATHS[@]}"; do
				if [ "$q" = "$p" ]; then seen=1; fi
			done
			if [ "$seen" -eq 1 ]; then continue; fi
			WATCH_PATHS+=("$p")
			WATCH_HASHES+=("$(hash_of "$p")")
		done
	done
}

# Returns 0 when the tree is as it was, 1 when anything moved.
watch_verify() {
	local i p q want now wrote rc=0
	for i in "${!WATCH_PATHS[@]}"; do
		p="${WATCH_PATHS[$i]}"
		want="${WATCH_HASHES[$i]}"
		now="$(hash_of "$p")"
		if [ "$want" = "$now" ]; then continue; fi
		wrote=no
		for q in "${SNAP_PATHS[@]}"; do
			if [ "$q" = "$p" ]; then wrote=yes; fi
		done
		if [ "$wrote" = yes ]; then
			printf '  UNRESTORED  %s\n' "$p"
			printf '              the harness wrote this and did not put it back. Harness bug.\n'
			DIRTY_TREE=1
		else
			printf '  FOREIGN     %s\n' "$p"
			printf '              the harness never wrote this path, and it changed anyway.\n'
			printf '              baseline %s... now %s...\n' "${want:0:16}" "${now:0:16}"
			FOREIGN=$((FOREIGN + 1))
		fi
		rc=1
	done
	return $rc
}

# ── The engine ──────────────────────────────────────────────────────────────

record_unknown() {
	UNKNOWN=$((UNKNOWN + 1))
	UNKNOWNS+=("$1 — $2")
	printf '  UNKNOWN   %s\n' "$2"
}

record_unfaithful() {
	UNFAITHFUL=$((UNFAITHFUL + 1))
	UNFAITHFULS+=("$1 — $2")
	printf '  *** UNFAITHFUL MUTATION — HARNESS BUG, NOT A GUARD FINDING ***\n'
	printf '      %s\n' "$2"
}

# oracle_count <oracle-fn> — how many units violate the property right now.
#
# Prints the integer on stdout and returns non-zero when the oracle could not
# produce one. An oracle that crashes must never be read as "zero violations":
# that is the silent-empty-scan defect, and it would convert a broken oracle
# into a confident "this mutation injected nothing".
oracle_count() {
	local fn="$1" out
	err_clear
	out="$("$fn" 2>&1)" || { err_set "oracle exited non-zero: ${out}"; return 1; }
	case "$out" in
		''|*[!0-9]*) err_set "oracle printed a non-integer: ${out}"; return 1 ;;
	esac
	printf '%s' "$out"
}

# null_edit <path> — change the bytes of a file without changing its meaning.
#
# The generic anti-vacuity probe for oracles. An oracle that answers "did this
# file change?" rather than "is the property violated?" would call every
# mutation faithful, including one that injects nothing — the vacuous-check
# shape rebuilt inside the tool built to hunt it. A trailing newline moves the
# checksum and violates no property in any format this registry targets, so an
# oracle that reports a violation after one is measuring the wrong thing.
#
# What this does NOT catch, stated plainly rather than left to be assumed: an
# oracle that greps for the exact literal its mutation injects. That oracle is
# silent on a null edit and still proves nothing. A token-diff check against the
# oracle's own source was built for it and then removed — it fired on the
# legitimate case where the oracle covers more of the property than the guard
# NAMES, which is precisely the blind-spot detection that matters most here. A
# check that cries wolf on its most valuable case gets suppressed, so it is not
# shipped. The residual defence is review, and this paragraph is the brief for
# it: an oracle must state the PROPERTY, never the injection.
null_edit() {
	[ -e "$1" ] || return 1
	printf '\n' >>"$1"
}

prove() {
	local id="$1" cat="$2" kind="$3" guard="$4" filter="$5" target="$6" sig="$7" mut="$8" ctrl="${9:-}" oracle="${10:-}"

	printf '\n=== %-32s [%s]\n' "$id" "$cat"
	printf '    guard  : %s\n' "$guard"
	printf '    filter : %s\n' "${filter:-<whole suite>}"
	printf '    target : %s\n' "$target"
	printf '    oracle : %s\n' "${oracle:-<NONE>}"

	# -- Phase 0: the guard file must exist. ---------------------------------
	if [ ! -f "$guard" ]; then
		record_unknown "$id" "guard file does not exist: $guard"
		return 0
	fi

	# -- Phase 0b: no oracle, no verdict. ------------------------------------
	# A case without a property oracle cannot tell "the guard is blind" from "my
	# mutation injected nothing", and those have opposite repairs. It is allowed
	# to run and it is not allowed to produce a finding. The startup gate makes
	# this unreachable for registered cases; it stays because the self-test
	# drives prove() directly, and because a gate with no enforcement behind it
	# is the shape this whole file is about.
	if [ -z "$oracle" ]; then
		record_unknown "$id" "NO PROPERTY ORACLE registered — a green guard here cannot be told apart from a mutation that injected no defect, so no verdict is filed"
		return 0
	fi

	# -- Phase 1: the filter must select at least one test. ------------------
	# `bats --filter` matching nothing exits 0. Without this, a stale test name
	# in the registry reports every affected guard as decoration.
	local nsel
	nsel="$(selected_test_count "$kind" "$guard" "$filter")"
	if ! [ "$nsel" -ge 1 ] 2>/dev/null; then
		SEL_ERR="$(err_get)"
		if [ -n "$SEL_ERR" ]; then
			record_unknown "$id" "the test COUNTER failed, so selection was never measured — $SEL_ERR. This is a TOOLING fault, not a stale filter: do not go editing the filter."
		else
			record_unknown "$id" "filter selected ZERO tests (bats exits 0 on an empty selection, so this would otherwise read as a guard that never fires). The filter names no test in this suite — check for a renamed test."
		fi
		return 0
	fi
	printf '    selects: %s test(s)\n' "$nsel"

	# -- Phase 2: green baseline. -------------------------------------------
	# Requiring a clean green baseline collapses every "could not run" cause into
	# one check: if the guard cannot pass on an unmodified tree, nothing below it
	# means anything, whatever the reason.
	run_guard "$kind" "$guard" "$filter"
	if [ "$GUARD_STATUS" -ne 0 ]; then
		record_unknown "$id" "guard was NOT GREEN on an unmutated tree (exit $GUARD_STATUS) — the mutated run below would prove nothing"
		show "$GUARD_OUTPUT" '^not ok|^# ' 5 '      '
		return 0
	fi

	# -- Phase 2b: the property must HOLD before anything is injected. -------
	# If the oracle already reports violations on an unmutated tree, then either
	# the tree genuinely violates the property (in which case the guard being
	# green is the story, and it is not this case's story) or the oracle is
	# wrong. Either way nothing measured below means what it appears to.
	local base_viol
	if ! base_viol="$(oracle_count "$oracle")"; then
		record_unknown "$id" "the property oracle ($oracle) could not be evaluated on a clean tree — $(err_get)"
		return 0
	fi
	if [ "$base_viol" -ne 0 ]; then
		record_unknown "$id" "the property oracle ($oracle) reports $base_viol violation(s) BEFORE any mutation — the property does not hold at baseline, so a red guard below would not be evidence of detection"
		return 0
	fi

	# -- Phase 3: mutate, and prove the mutation landed. ---------------------
	snapshot "$target"
	local pre_sum post_sum
	pre_sum="$( [ -e "$target" ] && sha256sum "$target" | cut -d' ' -f1 || printf 'ABSENT' )"

	# -- Phase 2c: the oracle must not answer "did the file change?" ---------
	# Only meaningful for a target that already exists; the create-an-orphan
	# cases have nothing to null-edit and are skipped explicitly rather than
	# silently, so a skip cannot be mistaken for a pass.
	if null_edit "$target"; then
		local null_viol
		if ! null_viol="$(oracle_count "$oracle")"; then
			record_unknown "$id" "the property oracle ($oracle) could not be evaluated after a null edit — $(err_get)"
			restore_all
			return 0
		fi
		restore_all
		if [ "$null_viol" -ne 0 ]; then
			record_unfaithful "$id" "the property oracle ($oracle) reports $null_viol violation(s) after a NULL EDIT (one appended newline) to $target. It is detecting change, not defect, so it would bless a mutation that injects nothing. Fix the ORACLE. No verdict filed."
			return 0
		fi
	fi

	if ! "$mut"; then
		record_unknown "$id" "MUTATION FAILED TO APPLY (anchor missing) — this case tested nothing; the message above says which anchor"
		restore_all
		return 0
	fi

	post_sum="$( [ -e "$target" ] && sha256sum "$target" | cut -d' ' -f1 || printf 'ABSENT' )"
	if [ "$pre_sum" = "$post_sum" ]; then
		record_unknown "$id" "mutation exited 0 but did not change $target — nothing was injected"
		restore_all
		return 0
	fi

	# -- Phase 3b: the mutation must have injected an ACTUAL DEFECT. ---------
	# The checksum above proves only that bytes moved. This is the assertion
	# that was missing when SIGN-BY-TAG added a second image reference beside a
	# digest that was still there, violated nothing, and got a working guard
	# reported as one that does not fire.
	local mut_viol
	if ! mut_viol="$(oracle_count "$oracle")"; then
		record_unknown "$id" "the property oracle ($oracle) could not be evaluated after mutation — $(err_get)"
		restore_all
		return 0
	fi
	if [ "$mut_viol" -eq 0 ]; then
		record_unfaithful "$id" "$mut changed $target but the property oracle ($oracle) still reports 0 violations. The mutation injected no defect, so the guard had nothing to catch. FIX THE MUTATION — this is NOT evidence about the guard, and it is not filed as any kind of guard verdict."
		restore_all
		return 0
	fi
	printf '    injected: %s property violation(s), confirmed by %s\n' "$mut_viol" "$oracle"

	# -- Phase 4: the guard must now go red, for the RIGHT reason. -----------
	run_guard "$kind" "$guard" "$filter"
	local mutated_status="$GUARD_STATUS" mutated_output="$GUARD_OUTPUT"

	# -- Phase 5: restore, and require recovery. ----------------------------
	restore_all
	local restored_sum
	restored_sum="$( [ -e "$target" ] && sha256sum "$target" | cut -d' ' -f1 || printf 'ABSENT' )"
	if [ "$restored_sum" != "$pre_sum" ]; then
		record_unknown "$id" "RESTORE FAILED for $target (pre=$pre_sum now=$restored_sum) — the tree is dirty"
		return 0
	fi

	if [ "$mutated_status" -eq 0 ]; then
		# A finding — but WHICH finding is not yet known. Quote the observed green
		# output first, because that is the evidence and it is true regardless of
		# how the case classifies below.
		# The banner used to read "*** GUARD DID NOT FIRE ***" here, printed
		# BEFORE the classification below had run. So a guard that turned out to
		# be live with one narrow gap was announced under the same headline as a
		# guard that does nothing, and the summary counted both as "did not
		# fire". That is how this tool acquired a reputation for crying wolf —
		# and a tool that cries wolf gets suppressed rather than heeded, which is
		# the documented fate of this repository's migration-idempotency guard.
		# The verdict is now named only once, after it is known.
		printf '  GUARD STAYED GREEN on a confirmed defect (%s violation(s) injected).\n' "$mut_viol"
		printf '      classifying. Observed output:\n'
		show "$mutated_output" '' 20 '      | '

		# No control registered: say so, and do NOT claim decoration. "Did not
		# catch this mutation" is all that was measured.
		if [ -z "$ctrl" ]; then
			NOT_FIRED=$((NOT_FIRED + 1))
			UNCLASSIFIED=$((UNCLASSIFIED + 1))
			FINDINGS+=("UNCLASSIFIED|$id|$guard|$filter|$target")
			printf '      verdict: UNCLASSIFIED — no positive control is registered for this\n'
			printf '      case, so this run cannot distinguish a blind spot from decoration.\n'
			return 0
		fi

		# Positive control: the blunt version of the same defect. The tree was
		# restored in Phase 5, so this applies to a clean tree.
		printf '      applying positive control (%s) to classify...\n' "$ctrl"
		local c_pre c_post
		c_pre="$( [ -e "$target" ] && sha256sum "$target" | cut -d' ' -f1 || printf 'ABSENT' )"
		if ! "$ctrl"; then
			record_unknown "$id" "guard stayed green on the subtle mutation, but the POSITIVE CONTROL failed to apply (anchor missing) — blind spot and decoration cannot be told apart, so this is not reported as either"
			restore_all
			return 0
		fi
		c_post="$( [ -e "$target" ] && sha256sum "$target" | cut -d' ' -f1 || printf 'ABSENT' )"
		if [ "$c_pre" = "$c_post" ]; then
			record_unknown "$id" "positive control exited 0 but changed nothing — cannot classify this finding"
			restore_all
			return 0
		fi
		# The control gets the same faithfulness test as the mutation. A control
		# that injects no defect goes green for the honest reason, and would then
		# be read as "the guard missed the blunt form too" — manufacturing a
		# DECORATION verdict against a working guard out of nothing but a bad
		# control. That is the original defect wearing a different hat.
		local ctrl_viol
		if ! ctrl_viol="$(oracle_count "$oracle")" || [ "$ctrl_viol" -eq 0 ]; then
			record_unfaithful "$id" "the POSITIVE CONTROL ($ctrl) changed $target but the property oracle ($oracle) reports ${ctrl_viol:-no readable count} violation(s) — the control injects no defect, so this finding cannot be classified and none is filed. $(err_get)"
			restore_all
			return 0
		fi

		run_guard "$kind" "$guard" "$filter"
		local ctrl_status="$GUARD_STATUS" ctrl_output="$GUARD_OUTPUT"
		restore_all

		NOT_FIRED=$((NOT_FIRED + 1))
		if [ "$ctrl_status" -ne 0 ]; then
			BLIND=$((BLIND + 1))
			FINDINGS+=("BLIND-SPOT|$id|$guard|$filter|$target")
			printf '      verdict: BLIND SPOT — the control went RED (exit %s), so this guard\n' "$ctrl_status"
			printf '      IS live. It has a specific gap, not a missing capability:\n'
			show "$ctrl_output" '^not ok|^# ' 3 '      | '
		else
			DECOR=$((DECOR + 1))
			FINDINGS+=("DECORATION|$id|$guard|$filter|$target")
			printf '      verdict: DECORATION — the control ALSO exited 0. Both the subtle and\n'
			printf '      the blunt form of this defect passed. Observed control output:\n'
			show "$ctrl_output" '' 10 '      | '
		fi
		return 0
	fi

	# Red — but red for the injected defect, or red for something else? A guard
	# that goes red because the mutation broke its parser has not detected
	# anything, and reporting that as success is how a guard keeps its reputation
	# while losing its capability.
	if ! printf '%s\n' "$mutated_output" | grep -qE "$sig"; then
		record_unknown "$id" "guard went red (exit $mutated_status) but its output did not match the expected signature /$sig/ — it may be failing for a reason unrelated to the injected defect"
		show "$mutated_output" '^not ok|^# ' 6 '      | '
		return 0
	fi

	# -- Phase 6: green again, so the red was the mutation and not damage. ---
	run_guard "$kind" "$guard" "$filter"
	if [ "$GUARD_STATUS" -ne 0 ]; then
		record_unknown "$id" "guard did not recover after restore (exit $GUARD_STATUS) — the red above may have been collateral damage rather than detection"
		return 0
	fi

	FIRED=$((FIRED + 1))
	printf '  RED as required (exit %s), recovered green on restore\n' "$mutated_status"
	show "$mutated_output" '^not ok' 2 '      | '
	return 0
}

# ── Self-test: prove THIS harness can fail ──────────────────────────────────
#
# The harness is the thing that catches vacuous passes. A vacuous harness is the
# worst possible outcome here, so its verdict logic is exercised against
# synthetic guards whose correct verdict is known in advance. Each expectation
# below is asserted; a harness whose verdict logic breaks turns this red.

self_test() {
	local fix status out rc=0
	SELFTEST_N=0
	fix="$(mktemp -d)"

	# A guard that is pure decoration: its NAME claims the property and its body
	# never looks at the target. Named after the property on purpose — that is
	# the real-world shape (a check called "no FORBIDDEN tokens" that checks
	# nothing), and it also keeps the tautology check honest, since a token the
	# guard itself names is the property's vocabulary and not a smuggled answer.
	cat >"$fix/decoration.bats" <<-'BATS'
		@test "decoration guard: no FORBIDDEN or SNEAKY token (checks nothing)" {
			[ 1 -eq 1 ]
		}
	BATS
	# A guard that genuinely reads its target.
	cat >"$fix/real.bats" <<-BATS
		@test "real guard rejects FORBIDDEN" {
			if grep -q FORBIDDEN "$fix/target.txt"; then
				echo "found the forbidden token"
				false
			fi
		}
	BATS
	# A guard that is already failing before anything is injected.
	cat >"$fix/redbase.bats" <<-'BATS'
		@test "guard that is red before any mutation" {
			false
		}
	BATS
	# The same real guard, as a plain script. Until this fixture existed the `sh`
	# branch of run_guard and selected_test_count had no test and no registered
	# case: an unexercised code path inside the tool whose entire purpose is
	# finding unexercised checks.
	cat >"$fix/real-guard.sh" <<-SH
		#!/usr/bin/env bash
		if grep -q FORBIDDEN "$fix/target.txt"; then
		  echo "found the forbidden token"
		  exit 1
		fi
		exit 0
	SH
	printf 'clean content\n' >"$fix/target.txt"

	SNAP_PATHS=(); SNAP_KEYS=()

	expect() {   # <expected-verdict> <label> ... runs prove() and checks counters
		local want="$1" label="$2"; shift 2
		local f0=$FIRED b0=$BLIND d0=$DECOR c0=$UNCLASSIFIED u0=$UNKNOWN x0=$UNFAITHFUL got
		prove "$@" >/dev/null 2>&1 || true
		# The specific counters are tested BEFORE NOT_FIRED, because NOT_FIRED is
		# a total that every finding kind also increments. Testing it first would
		# collapse BLIND, DECOR and UNCLASSIFIED into one indistinguishable verdict
		# — a self-test that cannot tell apart the three outcomes it exists to
		# tell apart.
		if   [ "$FIRED"        -gt "$f0" ]; then got=FIRED
		elif [ "$BLIND"        -gt "$b0" ]; then got=BLIND
		elif [ "$DECOR"        -gt "$d0" ]; then got=DECOR
		elif [ "$UNCLASSIFIED" -gt "$c0" ]; then got=UNCLASSIFIED
		elif [ "$UNFAITHFUL"   -gt "$x0" ]; then got=UNFAITHFUL
		elif [ "$UNKNOWN"      -gt "$u0" ]; then got=UNKNOWN
		else got=NOTHING; fi
		SELFTEST_N=$((SELFTEST_N + 1))
		if [ "$got" = "$want" ]; then
			printf '  ok    %-52s -> %s\n' "$label" "$got"
		else
			printf '  FAIL  %-52s -> %s (expected %s)\n' "$label" "$got" "$want"
			rc=1
		fi
	}

	st_mut_real()    { py_sub "$fix/target.txt" 'clean content' 'FORBIDDEN content'; }
	st_mut_badanchor(){ py_sub "$fix/target.txt" 'anchor that is not present' 'x'; }
	st_mut_noop()    { return 0; }
	st_mut_wrongred(){ py_sub "$fix/target.txt" 'clean content' 'FORBIDDEN content'; }
	# A defect the real guard genuinely does not look for. Paired with st_mut_real
	# as the control, this is a guard with a blind spot rather than a dead one.
	st_mut_sneaky()  { py_sub "$fix/target.txt" 'clean content' 'SNEAKY content'; }
	# Changes the file and violates NOTHING. This is the SIGN-BY-TAG shape, and
	# before the oracle layer it was indistinguishable from a dead guard: the
	# anchor matched, the checksum moved, the guard stayed green, and the harness
	# announced that the guard did not fire.
	st_mut_harmless(){ py_sub "$fix/target.txt" 'clean content' 'perfectly fine content'; }

	# The property, stated independently of any guard: the target carries no
	# banned token. The real guard only ever looks for one of the two.
	st_oracle() {
		local n=0 line
		while IFS= read -r line; do
			case "$line" in *FORBIDDEN*|*SNEAKY*) n=$((n + 1)) ;; esac
		done <"$fix/target.txt"
		printf '%s' "$n"
	}
	# An oracle that answers "did this file change?" instead of "is the property
	# violated?" — here by counting blank lines, so ANY edit trips it, including
	# one that injects nothing. This is the lazy shape the null-edit probe
	# exists to reject, and it would otherwise certify every mutation as
	# faithful and hand back confident nonsense about every guard.
	st_oracle_change_detector() {
		local n=0 line
		while IFS= read -r line; do
			[ -n "$line" ] || n=$((n + 1))
		done <"$fix/target.txt"
		printf '%s' "$n"
	}
	# An oracle that cannot produce a number. Must never be read as "zero".
	st_oracle_broken() { printf 'not a number'; }
	# An oracle for a property that is already violated before anything is done.
	st_oracle_dirty()  { printf '2'; }

	printf '=== harness self-test =======================================\n'

	# show() must actually EMIT. It once printed nothing whatsoever for every
	# finding in a full run — sed rejected a prefix containing its own delimiter —
	# while every verdict above it stayed correct. Blank evidence under a correct
	# headline is indistinguishable from a guard that produced no output, and this
	# harness is not allowed to report a guard without quoting what it saw.
	local shown sline n_shown=0
	shown="$(show 'not ok 1 example failure
# a detail line
ok 2 should be filtered out' '^not ok|^# ' 5 '      | ')"
	while IFS= read -r sline; do
		case "$sline" in '      | '*) n_shown=$((n_shown + 1)) ;; esac
	done <<< "$shown"
	SELFTEST_N=$((SELFTEST_N + 1))
	if [ "$n_shown" -eq 2 ] && [[ "$shown" == *'not ok 1 example failure'* ]] \
	   && [[ "$shown" != *'should be filtered out'* ]]; then
		printf '  ok    %-52s -> 2 prefixed lines\n' "show() emits filtered, prefixed evidence"
	else
		printf '  FAIL  %-52s -> %s prefixed line(s): %q\n' \
			"show() emitted nothing, or lost the prefix/filter" "$n_shown" "$shown"
		rc=1
	fi

	# The diagnostic channel must survive a command substitution. It did not:
	# oracle_count and selected_test_count are both invoked as `v="$(fn)"`, so a
	# global set inside them died with the subshell and every UNKNOWN came out
	# with a blank reason — the one field an operator reads to tell a broken
	# guard from a broken VM. A blank reason under a correct verdict is the same
	# defect as blank evidence under a correct headline, which this file already
	# caught once in show().
	SELFTEST_N=$((SELFTEST_N + 1))
	err_clear
	st_probe_err() { err_set "diagnostic from inside a subshell"; printf '0'; }
	local st_probe_out
	st_probe_out="$(st_probe_err)"      # the exact shape that lost the message
	if [ "$(err_get)" = "diagnostic from inside a subshell" ] && [ "$st_probe_out" = "0" ]; then
		printf '  ok    %-52s -> reason survived\n' "diagnostic crosses the \$( ) subshell boundary"
	else
		printf '  FAIL  %-52s -> got %q\n' "diagnostic LOST crossing \$( )" "$(err_get)"
		rc=1
	fi
	# And the real caller must populate it too, or the channel is plumbed to
	# nothing: a working pipe with no writer reports exactly like a broken one.
	SELFTEST_N=$((SELFTEST_N + 1))
	err_clear
	st_probe_bad() { printf 'not-an-integer'; }
	if oracle_count st_probe_bad >/dev/null 2>&1; then
		printf '  FAIL  %-52s -> accepted a non-integer as a count\n' "oracle_count rejects a non-integer"
		rc=1
	elif case "$(err_get)" in *"non-integer"*) true ;; *) false ;; esac; then
		printf '  ok    %-52s -> reason recorded\n' "oracle_count explains a non-integer count"
	else
		printf '  FAIL  %-52s -> reason was %q\n' "oracle_count rejected silently" "$(err_get)"
		rc=1
	fi
	err_clear

	expect FIRED     "a real guard detects its defect" \
		ST-REAL self bats "$fix/real.bats" 'real guard rejects' \
		"$fix/target.txt" 'forbidden token|not ok' st_mut_real "" st_oracle

	expect UNCLASSIFIED "a finding with NO control is UNCLASSIFIED, not decoration" \
		ST-DECOR self bats "$fix/decoration.bats" 'decoration guard' \
		"$fix/target.txt" 'not ok' st_mut_real "" st_oracle

	expect UNKNOWN   "a mutation whose anchor is missing is UNKNOWN" \
		ST-BADANCHOR self bats "$fix/real.bats" 'real guard rejects' \
		"$fix/target.txt" 'not ok' st_mut_badanchor "" st_oracle

	expect UNKNOWN   "a mutation that changes nothing is UNKNOWN" \
		ST-NOOP self bats "$fix/real.bats" 'real guard rejects' \
		"$fix/target.txt" 'not ok' st_mut_noop "" st_oracle

	expect UNKNOWN   "a filter selecting zero tests is UNKNOWN, not green" \
		ST-ZEROSEL self bats "$fix/real.bats" 'NO_SUCH_TEST_NAME_XYZ' \
		"$fix/target.txt" 'not ok' st_mut_real "" st_oracle

	expect UNKNOWN   "a guard red at baseline is UNKNOWN" \
		ST-REDBASE self bats "$fix/redbase.bats" 'red before any mutation' \
		"$fix/target.txt" 'not ok' st_mut_real "" st_oracle

	expect UNKNOWN   "a missing guard file is UNKNOWN" \
		ST-NOGUARD self bats "$fix/does-not-exist.bats" 'anything' \
		"$fix/target.txt" 'not ok' st_mut_real "" st_oracle

	expect UNKNOWN   "red for an unexpected reason is UNKNOWN, not FIRED" \
		ST-WRONGRED self bats "$fix/real.bats" 'real guard rejects' \
		"$fix/target.txt" 'a signature that will never appear' st_mut_wrongred "" st_oracle

	# ── The classification the first real run got wrong ─────────────────────
	#
	# These four are the reason this self-test grew. A run that cannot tell a
	# blind spot from decoration will confidently call a working guard dead, and
	# it did: two guards were reported as "DECORATION" in exactly those words,
	# and both went red under a blunter control.

	expect BLIND     "guard missed the subtle defect but caught the control" \
		ST-BLIND self bats "$fix/real.bats" 'real guard rejects' \
		"$fix/target.txt" 'not ok' st_mut_sneaky st_mut_real st_oracle

	expect DECOR     "guard missed the control too — decoration, now measured" \
		ST-DECOR-CTRL self bats "$fix/decoration.bats" 'decoration guard' \
		"$fix/target.txt" 'not ok' st_mut_sneaky st_mut_real st_oracle

	expect UNKNOWN   "a control whose anchor is missing cannot classify -> UNKNOWN" \
		ST-CTRLBAD self bats "$fix/decoration.bats" 'decoration guard' \
		"$fix/target.txt" 'not ok' st_mut_sneaky st_mut_badanchor st_oracle

	expect FIRED     "the sh guard kind runs and detects its defect" \
		ST-SH self sh "$fix/real-guard.sh" '' \
		"$fix/target.txt" 'forbidden token' st_mut_real "" st_oracle

	expect UNKNOWN   "an unreadable sh guard is UNKNOWN, never a pass" \
		ST-SH-MISSING self sh "$fix/no-such-guard.sh" '' \
		"$fix/target.txt" 'forbidden token' st_mut_real "" st_oracle

	# ── The verdict this harness could not previously reach ─────────────────
	#
	# These are the reason the oracle layer exists. Before it, the four cases
	# below were INDISTINGUISHABLE from a guard that does not fire: the anchor
	# matched, the file changed, the checksum moved, the guard stayed green, and
	# the harness announced a finding against a guard that had done nothing
	# wrong. That is what happened to SIGN-BY-TAG, and a real guard nearly got
	# rewritten on the strength of it.

	expect UNFAITHFUL "a mutation that changes bytes but violates nothing" \
		ST-UNFAITHFUL self bats "$fix/real.bats" 'real guard rejects' \
		"$fix/target.txt" 'not ok' st_mut_harmless "" st_oracle

	expect UNFAITHFUL "a CONTROL that changes bytes but violates nothing" \
		ST-CTRL-UNFAITHFUL self bats "$fix/decoration.bats" 'decoration guard' \
		"$fix/target.txt" 'not ok' st_mut_sneaky st_mut_harmless st_oracle

	expect UNFAITHFUL "an oracle that fires on a NULL EDIT is rejected" \
		ST-NULLEDIT self bats "$fix/real.bats" 'real guard rejects' \
		"$fix/target.txt" 'not ok' st_mut_real "" st_oracle_change_detector

	expect UNKNOWN   "an oracle that cannot produce a number is never read as zero" \
		ST-ORACLE-BROKEN self bats "$fix/real.bats" 'real guard rejects' \
		"$fix/target.txt" 'not ok' st_mut_real "" st_oracle_broken

	expect UNKNOWN   "a property already violated at baseline yields no verdict" \
		ST-ORACLE-DIRTY self bats "$fix/real.bats" 'real guard rejects' \
		"$fix/target.txt" 'not ok' st_mut_real "" st_oracle_dirty

	expect UNKNOWN   "a case with NO oracle cannot produce a finding" \
		ST-NO-ORACLE self bats "$fix/decoration.bats" 'decoration guard' \
		"$fix/target.txt" 'not ok' st_mut_real "" ""

	# ── The foreign-edit detector must actually fire, and must not over-fire ──
	#
	# Both directions matter. A detector that never reports is the vacuous check
	# this file exists to ban; a detector that reports the harness's OWN writes as
	# foreign recreates the false alarm it was built to prevent.
	local fw="$fix/foreign.txt" fo="$fix/ours.txt"
	printf 'original\n' >"$fw"
	printf 'original\n' >"$fo"
	local sv_paths=("${WATCH_PATHS[@]}") sv_hashes=("${WATCH_HASHES[@]}")
	local sv_snap=("${SNAP_PATHS[@]}") sv_keys=("${SNAP_KEYS[@]}") sv_foreign=$FOREIGN sv_dirty=$DIRTY_TREE
	WATCH_PATHS=("$fw" "$fo"); WATCH_HASHES=("$(hash_of "$fw")" "$(hash_of "$fo")")
	SNAP_PATHS=("$fo"); SNAP_KEYS=("ignored")   # we "wrote" $fo, never touched $fw
	FOREIGN=0; DIRTY_TREE=0
	printf 'edited by someone else\n' >"$fw"    # foreign: not in our write log
	printf 'we changed this\n' >"$fo"           # ours: in our write log
	watch_verify >/dev/null 2>&1 || true
	SELFTEST_N=$((SELFTEST_N + 1))
	if [ "$FOREIGN" -eq 1 ] && [ "$DIRTY_TREE" -eq 1 ]; then
		printf '  ok    %-52s -> FOREIGN=1 UNRESTORED=1\n' "foreign edit detected, own write not misfiled"
	else
		printf '  FAIL  %-52s -> FOREIGN=%s DIRTY=%s (expected 1 and 1)\n' \
			"foreign-edit detector" "$FOREIGN" "$DIRTY_TREE"
		rc=1
	fi
	# And it must stay silent on a quiet tree.
	WATCH_PATHS=("$fw"); WATCH_HASHES=("$(hash_of "$fw")"); SNAP_PATHS=(); FOREIGN=0; DIRTY_TREE=0
	SELFTEST_N=$((SELFTEST_N + 1))
	if watch_verify >/dev/null 2>&1 && [ "$FOREIGN" -eq 0 ]; then
		printf '  ok    %-52s -> silent\n' "no false alarm when nothing changed"
	else
		printf '  FAIL  %-52s -> FOREIGN=%s\n' "foreign detector fired on an unchanged tree" "$FOREIGN"
		rc=1
	fi
	WATCH_PATHS=("${sv_paths[@]}"); WATCH_HASHES=("${sv_hashes[@]}")
	SNAP_PATHS=("${sv_snap[@]}"); SNAP_KEYS=("${sv_keys[@]}")
	FOREIGN=$sv_foreign; DIRTY_TREE=$sv_dirty

	# Restore proof: every fixture file is byte-identical after all of that.
	if [ "$(cat "$fix/target.txt")" = "clean content" ]; then
		SELFTEST_N=$((SELFTEST_N + 1))
		printf '  ok    %-52s -> restored\n' "target file restored after every verdict case"
	else
		printf '  FAIL  %-52s -> %s\n' "target file NOT restored" "$(cat "$fix/target.txt")"
		rc=1
	fi

	# Trap proof: kill a run mid-mutation and require the file to come back.
	#
	# $BASHPID, not $$. Inside a subshell `$$` still holds the PARENT's pid, so
	# `kill -TERM $$` here terminates the harness itself rather than the subshell
	# under test — which it did on the first run of this very case, taking the
	# whole self-test down with exit 130 and printing no verdict at all. A
	# self-test that kills its own runner reports nothing and looks like a hang.
	printf 'clean content\n' >"$fix/target.txt"
	(
		trap 'cp "$fix/snap.bytes" "$fix/target.txt"; exit 130' EXIT
		cp "$fix/target.txt" "$fix/snap.bytes"
		printf 'MUTATED AND ABANDONED\n' >"$fix/target.txt"
		kill -TERM "$BASHPID" 2>/dev/null
		sleep 5
	) >/dev/null 2>&1 || true
	if [ "$(cat "$fix/target.txt")" = "clean content" ]; then
		SELFTEST_N=$((SELFTEST_N + 1))
		printf '  ok    %-52s -> restored\n' "EXIT trap restores an ABORTED run"
	else
		printf '  FAIL  %-52s -> %s\n' "EXIT trap did NOT restore an aborted run" "$(cat "$fix/target.txt")"
		rc=1
	fi

	rm -rf "$fix"
	SNAP_PATHS=(); SNAP_KEYS=()
	# EVERY counter the self-test touched, or its verdicts leak into the real
	# run. UNFAITHFUL and UNFAITHFULS were missed when they were added, and the
	# three self-test cases carried straight into the summary: 22 cases ran and
	# 25 verdicts were reported. It surfaced only because the accounting check
	# below compares the two — without it, three fabricated harness findings
	# would have been filed against the estate, which is the same shape as
	# quoting a verdict nobody measured.
	FIRED=0; NOT_FIRED=0; UNKNOWN=0; FINDINGS=(); UNKNOWNS=()
	BLIND=0; DECOR=0; UNCLASSIFIED=0
	UNFAITHFUL=0; UNFAITHFULS=()

	printf '=============================================================\n'
	if [ "$rc" -ne 0 ]; then
		printf 'SELF-TEST FAILED: the harness does not classify outcomes correctly.\n'
		printf 'Nothing this tool reports about any guard can be trusted until this passes.\n'
		return 1
	fi
	# The count is COMPUTED, not typed. A hardcoded "all 10 behaviours verified"
	# stays at 10 while cases are added or silently skipped — a claim about
	# coverage that stops tracking the coverage, which is this repository's
	# signature defect written in a status line.
	if [ "$SELFTEST_N" -lt 10 ]; then
		printf 'SELF-TEST DEGENERATE: only %s behaviour(s) ran; expected at least 10.\n' "$SELFTEST_N"
		return 1
	fi
	printf 'self-test passed: %s harness behaviours verified.\n' "$SELFTEST_N"
	return 0
}

# ── Main ────────────────────────────────────────────────────────────────────

ONLY=""
MODE=run
while [ $# -gt 0 ]; do
	case "$1" in
		--list)      MODE=list ;;
		--self-test) MODE=selftest ;;
		--only)      ONLY="$2"; shift ;;
		-h|--help)   sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*)           printf 'unknown argument: %s\n' "$1"; exit 2 ;;
	esac
	shift
done

# Assert the harness's OWN mechanism. A registry that discovered zero cases must
# be a failure, not a pass — this is the tool that catches vacuous passes, and
# writing one would be the joke telling itself.
if [ "${#C_ID[@]}" -eq 0 ]; then
	printf 'FATAL: the case registry is EMPTY. A falsification harness with no cases\n'
	printf 'passes vacuously, which is the precise defect it exists to detect.\n'
	exit 2
fi

# Every case MUST carry a property oracle, and that oracle must exist as a
# function. This is the gate that makes an unfaithful mutation impossible to add
# QUIETLY: a new case without an oracle does not run and report "guard did not
# fire", it refuses to start and says why. Enforced here rather than inside
# register() so the message can name every offender in one pass instead of
# failing on whichever happened to be edited first.
MISSING_ORACLE=""
for i in "${!C_ID[@]}"; do
	if [ -z "${C_ORACLE[$i]}" ]; then
		MISSING_ORACLE="${MISSING_ORACLE}  ${C_ID[$i]} (no attach_oracle line)
"
	elif ! declare -F "${C_ORACLE[$i]}" >/dev/null 2>&1; then
		MISSING_ORACLE="${MISSING_ORACLE}  ${C_ID[$i]} (oracle '${C_ORACLE[$i]}' is not a defined function)
"
	fi
done
if [ -n "$MISSING_ORACLE" ]; then
	printf 'FATAL: case(s) registered without a usable property oracle:\n'
	printf '%s' "$MISSING_ORACLE"
	printf '\nAn oracle states the property INDEPENDENTLY of the guard and reports how\n'
	printf 'many units violate it. Without one, a case can prove that it edited a file\n'
	printf 'and cannot prove that it injected a DEFECT — so a guard that stays green\n'
	printf 'gets reported as broken when the mutation was the broken thing. That has\n'
	printf 'already happened here (SIGN-BY-TAG, 2026-08-16), and the accused guard was\n'
	printf 'correct. Add `attach_oracle <ID> <fn>` to the oracle block.\n'
	exit 2
fi

if [ "$MODE" = list ]; then
	printf '%-34s %-12s %s\n' ID CATEGORY GUARD
	for i in "${!C_ID[@]}"; do
		printf '%-34s %-12s %s :: %s\n' "${C_ID[$i]}" "${C_CAT[$i]}" "${C_GUARD[$i]}" "${C_FILTER[$i]}"
	done
	printf '\n%s case(s) registered.\n' "${#C_ID[@]}"
	exit 0
fi

if [ "$MODE" = selftest ]; then
	self_test
	exit $?
fi

printf '=== guard falsification proof ================================\n'
printf 'repo   : %s\n' "$REPO_ROOT"
printf 'HEAD   : %s\n' "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
printf 'cases  : %s registered\n' "${#C_ID[@]}"

# The self-test runs FIRST, every time. A harness whose verdict logic is broken
# reports confident nonsense about twenty guards, and the most alarming message
# it can produce is the one a broken harness produces most easily.
if ! self_test; then
	printf '\nAborting: the harness failed its own self-test.\n'
	exit 2
fi

# Record the working-tree state so the restore claim is evidence, not assertion.
TREE_BEFORE="$(git status --porcelain 2>/dev/null | sort)"

# Content baseline for every guard and target, taken before the first mutation.
# This is what separates "the harness wrote it" from "something else did" at the
# end of the run, without ever consulting a timestamp.
watch_baseline
if [ "${#WATCH_PATHS[@]}" -eq 0 ]; then
	printf 'FATAL: the foreign-edit baseline covers ZERO paths — it would report a\n'
	printf 'clean tree no matter what happened to it.\n'
	exit 2
fi
printf 'watching: %s guard/target path(s) by content hash\n' "${#WATCH_PATHS[@]}"

RAN=0
for i in "${!C_ID[@]}"; do
	if [ -n "$ONLY" ] && ! printf '%s' "${C_ID[$i]}" | grep -qE "$ONLY"; then
		continue
	fi
	RAN=$((RAN + 1))
	prove "${C_ID[$i]}" "${C_CAT[$i]}" "${C_KIND[$i]}" "${C_GUARD[$i]}" \
	      "${C_FILTER[$i]}" "${C_TARGET[$i]}" "${C_SIG[$i]}" "${C_MUT[$i]}" \
	      "${C_CTRL[$i]}" "${C_ORACLE[$i]}"
done

restore_all
TREE_AFTER="$(git status --porcelain 2>/dev/null | sort)"

printf '\n=== summary =================================================\n'
printf 'cases run          : %s\n' "$RAN"
printf 'guard FIRED        : %s\n' "$FIRED"
printf 'guard DID NOT FIRE : %s   <-- findings\n' "$NOT_FIRED"
printf '  of which BLIND SPOT   : %s   guard IS live; control went red, this shape slipped through\n' "$BLIND"
printf '  of which DECORATION   : %s   guard stayed green even for the blunt control\n' "$DECOR"
printf '  of which UNCLASSIFIED : %s   no control registered; blind spot vs decoration not measured\n' "$UNCLASSIFIED"
printf 'UNFAITHFUL MUTATION: %s   <-- HARNESS bug: injected no defect. No verdict filed.\n' "$UNFAITHFUL"
printf 'UNKNOWN            : %s   <-- harness could not run these; neither pass nor fail\n' "$UNKNOWN"

# The accounting must be complete. Every case that ran landed in exactly one
# bucket, and if the buckets do not sum to the number of cases run then a case
# fell through prove() without a verdict — which reads, from the summary alone,
# exactly like a case that passed.
ACCOUNTED=$((FIRED + NOT_FIRED + UNFAITHFUL + UNKNOWN))
MISCOUNTED=0
if [ "$ACCOUNTED" -ne "$RAN" ]; then
	printf '\n*** ACCOUNTING ERROR: %s case(s) ran but %s verdict(s) were recorded.\n' \
		"$RAN" "$ACCOUNTED"
	printf 'Either a case reached no verdict, or a verdict was counted twice. Both are\n'
	printf 'fatal to the report: an unrecorded case reads exactly like a passing one,\n'
	printf 'and a double-counted one invents a finding against a guard nobody measured.\n'
	# Its OWN flag. Folding this into DIRTY_TREE reported "the harness did not
	# restore the tree" directly underneath a restore proof stating that all 31
	# watched paths were byte-identical — two contradictory claims in one run,
	# which is how a real tree-corruption warning stops being believed.
	MISCOUNTED=1
fi

printf '\n--- restore proof ---\n'
if watch_verify; then
	printf 'all %s watched path(s) hash identical to their pre-run baseline.\n' "${#WATCH_PATHS[@]}"
fi
if [ "$TREE_BEFORE" = "$TREE_AFTER" ]; then
	printf 'git status is byte-identical before and after. Tree restored.\n'
else
	printf '*** TREE NOT RESTORED — git status changed across the run ***\n'
	diff <(printf '%s\n' "$TREE_BEFORE") <(printf '%s\n' "$TREE_AFTER") | sed 's/^/  /' || true
	# A harness that dirties the tree is a HARNESS defect, and it gets its own
	# flag rather than being added to NOT_FIRED. Folding it into the guard-finding
	# counter would report a harness bug as though a guard had failed to fire —
	# the same category error this whole round exists to stamp out.
	DIRTY_TREE=1
fi

if [ "${#UNFAITHFULS[@]}" -gt 0 ]; then
	printf '\n--- UNFAITHFUL MUTATIONS (defects in THIS HARNESS, not in any guard) ---\n'
	printf '%s\n' "${UNFAITHFULS[@]}" | sed 's/^/  /'
	printf '\nEach of these edited its target and injected no violation of the property.\n'
	printf 'The guard had nothing to detect, so nothing was learned about the guard.\n'
	printf 'Fix the MUTATION. Never widen or rewrite a guard on the strength of one of\n'
	printf 'these — the accusation was never made.\n'
fi

if [ "${#UNKNOWNS[@]}" -gt 0 ]; then
	printf '\n--- UNKNOWN: could not be run (NEITHER a pass NOR a finding) ---\n'
	printf '%s\n' "${UNKNOWNS[@]}" | sed 's/^/  /'
	printf '\n%s of %s case(s) produced no measurement. Those guards are UNPROVEN by\n' \
		"$UNKNOWN" "$RAN"
	printf 'this run: nothing here says they work and nothing here says they do not.\n'
	printf 'An UNKNOWN that persists is a case quietly contributing nothing, which is\n'
	printf 'the same shape as the dead guards this harness exists to find. The count\n'
	printf 'is expected to be ZERO; every entry above needs a cause, not a shrug.\n'
	printf '\nCauses seen on the CI VM but not locally are usually environmental — a\n'
	printf 'tool missing from the VM image, or a guard that is red there at baseline.\n'
	printf 'The reason text above distinguishes those; read it before assuming a\n'
	printf 'guard regressed.\n'
fi

if [ "${#FINDINGS[@]}" -gt 0 ]; then
	printf '\n--- GUARDS THAT DID NOT FIRE ---\n'
	printf '  %-13s %-28s %s\n' VERDICT ID 'GUARD :: FILTER :: TARGET'
	for f in "${FINDINGS[@]}"; do
		printf '  %s\n' "$f" | tr '|' '\t'
	done
	printf '\nEach had its defect injected and the guard exited 0. Read the verdict\n'
	printf 'column — the three are different defects with different repairs:\n'
	printf '  BLIND SPOT   the guard works; this shape slips past it. Widen the check.\n'
	printf '  DECORATION   the guard did not fire even for the blunt control. Rewrite it.\n'
	printf '  UNCLASSIFIED not measured. Register a positive control and re-run before\n'
	printf '               drawing any conclusion about this guard at all.\n'
fi

if [ "$FOREIGN" -ne 0 ]; then
	printf '\n%s watched path(s) changed during the run and this harness did not write\n' "$FOREIGN"
	printf 'them. Something else did. Every verdict above that touched one of those\n'
	printf 'paths was measured against a tree nobody has a record of, so none of them\n'
	printf 'are safe to quote. Re-run on a quiet tree.\n'
	printf '\nNote what this does NOT say: it names the paths and the hashes, and it\n'
	printf 'does not name a culprit. "A second agent is editing my worktree" has been\n'
	printf 'asserted here once already on weaker evidence than this, and it was wrong.\n'
	exit 5
fi
if [ "$DIRTY_TREE" -ne 0 ]; then
	printf '\nThe harness did not restore the tree. Nothing it reported can be trusted\n'
	printf 'until that is fixed, and the working tree needs inspecting by hand.\n'
	exit 4
fi
# Exit codes are checked in order of what has to be fixed FIRST, but every
# condition is PRINTED regardless of which one owns the exit status. The
# previous ordering returned 1 for "a guard did not fire" and never printed the
# "N cases could not be run" line at all when both were true — so on the CI VM,
# where both were true, the eight unrunnable cases were represented in the final
# verdict by nothing. A condition that decides nothing must still be said out
# loud; silence about it is how "could not run" drifts into meaning "fine".
EXIT_CODE=0
if [ "$UNKNOWN" -gt 0 ]; then
	printf '\n%s case(s) could not be run. That is NOT a pass — those guards are\n' "$UNKNOWN"
	printf 'unproven, and the count is expected to be zero. Fix them.\n'
	EXIT_CODE=3
fi
if [ "$NOT_FIRED" -gt 0 ]; then
	printf '\n%s guard(s) stayed green on a CONFIRMED defect (%s blind spot, %s decoration,\n' \
		"$NOT_FIRED" "$BLIND" "$DECOR"
	printf '%s unclassified). Each injection was verified by its property oracle, so the\n' "$UNCLASSIFIED"
	printf 'defect was really there in every case counted here.\n'
	EXIT_CODE=1
fi
if [ "$UNFAITHFUL" -gt 0 ]; then
	printf '\n%s mutation(s) injected no defect. That is a defect in THIS FILE. Until it\n' "$UNFAITHFUL"
	printf 'is fixed those cases test nothing, and no guard has been accused of anything.\n'
	EXIT_CODE=6
fi
# Assigned LAST so it wins. These conditions are printed in ascending order of
# how fundamental they are and the exit status is the deepest one, because a run
# whose verdicts do not add up cannot be trusted to have counted the shallower
# problems correctly either.
if [ "$MISCOUNTED" -ne 0 ]; then
	printf '\nThe verdict count does not match the case count, so this run is void\n'
	printf 'regardless of what any individual verdict above says.\n'
	EXIT_CODE=7
fi
if [ "$EXIT_CODE" -ne 0 ]; then
	exit $EXIT_CODE
fi
printf '\nAll %s cases red as required, and the tree is clean.\n' "$RAN"
