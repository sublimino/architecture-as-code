#!/usr/bin/env bats
#
# Control-flow tests for scripts/gcp-tf/demo-pipeline.sh.
#
# Stubs on PATH — make, kubectl, bats, bun, uv, go, sudo, sleep and a stub
# supervise-port-forward — let the script execute its REAL sequencing with no
# cloud, no cluster and no network. Every stub invocation is appended to one
# call log in order, and that ORDER is most of what is asserted here: the
# pipeline's correctness is almost entirely a claim about what happens before
# what, and a claim that can only be checked by a forty-minute VM run is a claim
# that is never checked.
#
# What each section pins, and why it is worth a test:
#
#   NO HAND-COPY   scripts/ci/vm-pipeline.sh reproduces the body of the
#                  `demo-signalloom-up` recipe by hand and that copy has drifted
#                  FOUR times, the fourth invisible to the guard written for the
#                  first three. The guard here is DERIVED from the Makefile, not
#                  written as a list, because a list is the same artefact as the
#                  copy: it drifts the moment someone edits one and not the other.
#
#   ADJACENCY      agent-trust-local.sh must run immediately after
#                  signalloom-local.sh, with nothing in between. Delegating to
#                  the Makefile is what makes that structurally unbreakable from
#                  the pipeline, so the assertion is on the recipe.
#
#   THE TRAP       under `set -e` a failing final command in an EXIT trap
#                  replaces the status the script asked for. This repo has
#                  already lost a run with 8/8 green stages to exactly that, so
#                  it is not enough to check that pass exits 0 — the test that
#                  matters mutates the trap and shows a green run turning red.
#
#   TERMINAL STATE an aborted run must say ABORTED in a file, and a real verdict
#                  must never be overwritten. "Reports present, no summary" was
#                  read as a pass twice in one session on 2026-08-13.
#
#   NO TEARDOWN    the demo must be standing when the script returns, on the
#                  success path AND on the failure path.
#
#   PUBLISH        0.0.0.0 because the operator arrives over an IAP tunnel to
#                  the internal IP; dashboard Nginx on 8080 is the human-access
#                  entrypoint. Acceptance tests separately retain Envoy :30754.
#
# Every structural guard below is paired with a MUTATION test that introduces
# the defect on a COPY and requires the guard to go red. A guard nobody has
# watched fail is a guard nobody has tested.

setup() {
	repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	script="$repo/scripts/gcp-tf/demo-pipeline.sh"
	makefile="$repo/Makefile"
	fixtures="$repo/test/fixtures/gcp-demo-pipeline"

	# Presence before behaviour: a suite that drives a script which was never
	# written reports whatever the shell does with a missing file, and reads as a
	# pass in at least two of the shapes this repo has been bitten by.
	[ -f "$script" ]
	[ -f "$makefile" ]
	[ -d "$fixtures" ]

	# HOME is redirected because the script prepends ${HOME}/.local/bin,
	# ${HOME}/.local/go/bin, /usr/local/go/bin and ${GOPATH}/bin to PATH before
	# anything else. With the real HOME those directories can contain real
	# binaries that would win over the stubs — a suite silently testing against a
	# real `go` or a real `bats` is the sort of green that means nothing. Putting
	# the stubs in ${HOME}/.local/bin makes the script's own prepend the thing
	# that guarantees they are found first.
	export HOME="$BATS_TEST_TMPDIR/home"
	stubdir="$HOME/.local/bin"
	mkdir -p "$stubdir"

	local n
	for n in make kubectl bats bun bunx uv go node npx sudo curl nc sleep git; do
		# git is deliberately NOT stubbed: the script git-inits the work dir
		# because Kustomize needs .git as a path-traversal boundary, and a stub
		# would make that step unexercised. Listed here so the omission is
		# visible rather than looking like a gap.
		[ "$n" = git ] && continue
		cp "$fixtures/stub-cmd" "$stubdir/$n"
	done
	cp "$fixtures/stub-supervise-port-forward" "$stubdir/supervise-port-forward"
	chmod +x "$stubdir"/*

	PATH="$stubdir:$PATH"
	export PATH

	LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$LOG"
	export STUB_CALL_LOG="$LOG"

	work="$BATS_TEST_TMPDIR/work"
	reports="$BATS_TEST_TMPDIR/reports"
	make_fake_repo "$work"

	# ── Neutralise the AMBIENT DEMO_* environment before setting our own ──────
	#
	# This suite runs as stage 1r of scripts/gcp-tf/demo-pipeline.sh, and
	# scripts/gcp-tf/demo-up.sh:1821 exports ELEVEN DEMO_* variables into the
	# environment that stage inherits. The driver under test reads the same
	# names, so any one this setup does not override is silently supplied by the
	# run that is executing us.
	#
	# DEMO_SUMMARY_FILE was the one that bit, and it bit invisibly for months.
	# demo-pipeline.sh:141 is
	#     SUMMARY_FILE="${DEMO_SUMMARY_FILE:-${REPORT_DIR}/summary.json}"
	# so an explicit DEMO_SUMMARY_FILE OUTRANKS the DEMO_REPORT_DIR this setup
	# carefully points at a sandbox. On the CI VM the driver-under-test therefore
	# wrote its verdict to the OUTER run's summary path and left
	# "$reports/summary.json" absent, and every assertion that reads it failed —
	# while `run bash "$script"` still exited 0, because nothing had gone wrong
	# from the driver's point of view. Nine tests red on the VM, all 43 green on
	# any developer box, for two years' worth of "environmental flake".
	#
	# Reproduced deterministically before this fix was written:
	#     DEMO_SUMMARY_FILE=/tmp/x.json bats test/gcp-demo-pipeline.bats -> 9 failures
	#                                   bats test/gcp-demo-pipeline.bats -> 0 failures
	# which is exactly the nine the VM reported.
	#
	# It also means the suite was WRITING to the live run's summary file. A test
	# clobbering the verdict of the pipeline running it is a worse bug than the
	# red stage that revealed it.
	#
	# Unset as a CLASS rather than naming the eleven: the next variable added to
	# demo-up.sh must not be able to reintroduce this, and a hand list is the
	# artefact that omits by default.
	local _demo_var
	while IFS= read -r _demo_var; do
		[ -n "$_demo_var" ] || continue
		unset "$_demo_var"
	done < <(compgen -v | grep '^DEMO_' || true)

	export DEMO_WORK_DIR="$work"
	export DEMO_REPORT_DIR="$reports"
	export DEMO_PIPELINE_LOG="$BATS_TEST_TMPDIR/pipeline.log"
	export DEMO_STAGE_TIMEOUT_SECONDS=30
	export DEMO_CHROME_BIN=/bin/true
	export DEMO_SUPERVISE_BIN="$stubdir/supervise-port-forward"
	export DEMO_PF_STATE_DIR="$BATS_TEST_TMPDIR/pf-state"
	export DEMO_CONVERT_BIN="$BATS_TEST_TMPDIR/no-such-converter"
}

# A minimal tree with exactly the paths the script cd's into or executes. Only
# the shapes it actually touches: everything reached through `make`, `bats`,
# `bun`, `uv` or `go` is covered by the PATH stubs, so the tree only needs the
# directories and the handful of repo-relative scripts invoked as ./paths.
make_fake_repo() {
	local root="$1"
	mkdir -p "$root/scripts/ci" \
		"$root/test/acceptance/node_modules/@playwright" \
		"$root/d2-signalloom/test" \
		"$root/d2-signalloom/apps/dashboard-signalloom" \
		"$root/d2-signalloom/apps/fe-signalloom/src" \
		"$root/tools/demo-console"

	local f
	for f in scripts/ci/install-ci-tools.sh \
		scripts/setup.sh \
		scripts/acceptance-test.sh \
		scripts/check-flux-substitution.sh \
		scripts/check-vacuous-assertions.sh \
		test/guard-falsification-proof.sh \
		d2-signalloom/test/audit-guard-reintroduction-proof.sh \
		d2-signalloom/test/seam-guard-mutation-proof.sh; do
		cat >"$root/$f" <<-STUB
			#!/usr/bin/env bash
			printf '%s %s\n' "$f" "\$*" >>"\${STUB_CALL_LOG:-/dev/null}"
			exit 0
		STUB
		chmod +x "$root/$f"
	done
}

# ─── Call-log helpers ────────────────────────────────────────────────────────
#
# first_line fails loudly when a pattern is absent instead of returning an empty
# string. An ordering assertion built on two empty line numbers compares 0 with
# 0 and passes — the vacuous-green shape this repo has a whole lint for.

first_line() {
	local n
	n="$(grep -nE -m1 -- "$1" "$LOG" | cut -d: -f1)"
	if [ -z "$n" ]; then
		echo "pattern never appeared in the call log: $1" >&2
		echo "--- call log ---" >&2
		cat "$LOG" >&2
		return 1
	fi
	printf '%s' "$n"
}

assert_before() {
	local a b first second
	first="$(first_line "$1")" || return 1
	second="$(first_line "$2")" || return 1
	a="$first"; b="$second"
	if [ "$a" -ge "$b" ]; then
		echo "expected [$1] (line $a) to come BEFORE [$2] (line $b)" >&2
		cat "$LOG" >&2
		return 1
	fi
}

assert_absent() {
	# `run grep` with the status pinned to exactly 1, never `-ne 0`: grep exits 1
	# for "ran fine, matched nothing" and 2 for "could not read the file", so
	# `-ne 0` reports a MISSING LOG as "the forbidden call did not happen" — a
	# pass earned by scanning nothing. The log is proven present first.
	[ -f "$LOG" ]
	run grep -nE -- "$1" "$LOG"
	if [ "$status" -ne 1 ]; then
		echo "expected [$1] to be ABSENT from the call log; grep status=$status" >&2
		echo "$output" >&2
		return 1
	fi
}

# The tee'd stdout of the script is written by a process-substitution child the
# shell does not wait for, so a bare read of the log immediately after the run
# can race the final flush. Bounded retry rather than a fixed sleep.
log_contains() {
	local i
	for i in $(seq 1 40); do
		grep -qF -- "$1" "$DEMO_PIPELINE_LOG" 2>/dev/null && return 0
		sleep 0.05 2>/dev/null || true
	done
	echo "not found in pipeline log: $1" >&2
	cat "$DEMO_PIPELINE_LOG" >&2 2>/dev/null || true
	return 1
}

summary_field() {
	# Deliberately not jq: the script writes this file without jq precisely
	# because the early-abort case is the one where jq is missing, and a reader
	# that needs jq could not verify that case.
	sed -n "s/.*\"$1\": *\"\\([^\"]*\\)\".*/\\1/p" "$reports/summary.json" | head -1
}

summary_number() {
	sed -n "s/.*\"$1\": *\\([0-9-]*\\).*/\\1/p" "$reports/summary.json" | head -1
}

# ─── The recipe, DERIVED from the Makefile ───────────────────────────────────
#
# Both halves of the no-hand-copy guard read the recipe rather than a written
# list, for the reason stated at the top of this file.

recipe_body() {
	# Recipe lines are the tab-indented block after the target line, minus
	# comments. `demo-signalloom-up: healthcheck` itself is excluded because it
	# is not tab-indented — the prerequisite is not a step.
	sed -n '/^demo-signalloom-up:/,/^[^\t#]/p' "$makefile" \
		| grep -E '^	' \
		| grep -vE '^	#' \
		| sed 's/^	*//' \
		| grep -vE '^$'
}

# The identifier each recipe step would have to be re-invoked BY, if someone
# hand-copied the recipe into the pipeline: the make target for `$(MAKE) X`
# lines, and the script path for direct invocations.
recipe_step_identifiers() {
	recipe_body | sed -e 's/^\$(MAKE)[[:space:]]*//' \
		-e 's/^[A-Z_]*=[^[:space:]]*[[:space:]]*//' \
		-e 's/[[:space:]].*$//' \
		| grep -vE '^$'
}

# The script with comments removed. A guard that matched comments would fire on
# the paragraphs below that NAME these steps in order to explain the rule.
script_code() {
	sed 's/#.*//' "${1:-$script}"
}

# ═══ Static properties ═══════════════════════════════════════════════════════

@test "DEMOPIPE the script is executable and shellcheck clean" {
	[ -x "$script" ]
	command -v shellcheck >/dev/null || skip "shellcheck not installed"
	run shellcheck "$script"
	[ "$status" -eq 0 ]
}

@test "DEMOPIPE the recipe extraction is non-trivial before anything is derived from it" {
	# Assert the mechanism. An extraction that returned nothing would make both
	# halves of the no-hand-copy guard pass over an empty set — a guard against
	# vacuous passes, passing vacuously. This assertion has already earned its
	# place in this repo more than once.
	run recipe_step_identifiers
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -ge 8 ]
	[[ "$output" == *"push-local-signalloom"* ]]
	[[ "$output" == *"./scripts/signalloom-local.sh"* ]]
	[[ "$output" == *"./scripts/agent-trust-local.sh"* ]]
}

@test "DEMOPIPE NOHANDCOPY the pipeline invokes no step of the demo-signalloom-up recipe" {
	local step copied=""
	while IFS= read -r step; do
		[ -n "$step" ] || continue
		if script_code | grep -qF -- "$step"; then
			copied="${copied}${step} "
		fi
	done < <(recipe_step_identifiers)

	if [ -n "$copied" ]; then
		echo "scripts/gcp-tf/demo-pipeline.sh invokes recipe step(s) directly:"
		echo "  $copied"
		echo ""
		echo "That is the hand-copy that has drifted four times in vm-pipeline.sh."
		echo "Call 'make demo-signalloom-up' and let the Makefile be the source of"
		echo "truth. If a step genuinely must be lifted out, delete it from the"
		echo "recipe as well — a step in two places is a step in neither."
		false
	fi
}

@test "DEMOPIPE NOHANDCOPY the pipeline DOES call the recipe by name" {
	# The other direction, and it is not decoration: a script that invokes none
	# of the steps AND does not call the target passes the test above perfectly
	# while building no estate at all.
	#
	# LINE-ANCHORED to an invocation, and that is the whole content of this fix.
	# The first version matched `make demo-signalloom-up` anywhere outside a
	# comment, which the progress line
	#
	#   echo "==> [5/8] Bringing up the full Signal Loom estate (make demo-signalloom-up)..."
	#
	# satisfies perfectly. The falsification harness deleted the real invocation
	# and this test stayed GREEN, matching the echo — prose parsed as an
	# invocation, which is the same defect class as a guard that greps its own
	# source. A statement site is the only thing that proves a call.
	script_code | grep -qE '^[[:space:]]*(retry [0-9]+ )?"\$MAKE_BIN"[[:space:]]+demo-signalloom-up[[:space:]]*$'
}

@test "DEMOPIPE NOHANDCOPY MUTATION deleting the recipe call is detected" {
	# The paired positive for the fix above. Without it, "the guard is now
	# line-anchored" is a claim about a regex rather than about behaviour.
	local mutant="$BATS_TEST_TMPDIR/nocall.sh"
	sed 's/^retry 2 "\$MAKE_BIN" demo-signalloom-up$/true/' "$script" >"$mutant"

	# The mutation landed: present in the original, absent from the mutant.
	run grep -c '^retry 2 "\$MAKE_BIN" demo-signalloom-up$' "$script"
	[ "$output" -eq 1 ]
	run grep -c '^retry 2 "\$MAKE_BIN" demo-signalloom-up$' "$mutant"
	[ "$output" -eq 0 ]

	# The echo line survives the mutation, so a guard that matched prose would
	# still be green here. This asserts it is not.
	run grep -c 'make demo-signalloom-up' "$mutant"
	[ "$output" -ge 1 ]

	run bash -c "sed 's/#.*//' '$mutant' | grep -qE '^[[:space:]]*(retry [0-9]+ )?\"\\\$MAKE_BIN\"[[:space:]]+demo-signalloom-up[[:space:]]*\$'"
	[ "$status" -ne 0 ]
}

@test "DEMOPIPE NOHANDCOPY MUTATION the guard fires on a script that copies a step" {
	local mutant="$BATS_TEST_TMPDIR/mutant.sh" step
	step="$(recipe_step_identifiers | head -1)"
	[ -n "$step" ]
	cp "$script" "$mutant"
	printf '\n"$MAKE_BIN" %s\n' "$step" >>"$mutant"

	local copied=""
	while IFS= read -r s; do
		[ -n "$s" ] || continue
		if script_code "$mutant" | grep -qF -- "$s"; then copied="${copied}${s} "; fi
	done < <(recipe_step_identifiers)

	# The mutation landed, and it landed on the step it was aimed at.
	[ -n "$copied" ]
	[[ "$copied" == *"$step"* ]]
}

@test "DEMOPIPE NOHANDCOPY MUTATION a comment naming a step does NOT fire the guard" {
	# The paired negative. Without comment stripping this guard would fire on the
	# paragraphs in demo-pipeline.sh that explain the ordering rule by naming
	# agent-trust-local.sh — a guard that fires on the correct change teaches
	# people to ignore it, which is its own kind of decorative.
	local mutant="$BATS_TEST_TMPDIR/commented.sh"
	cp "$script" "$mutant"
	printf '\n# see ./scripts/agent-trust-local.sh up for the ordering rule\n' >>"$mutant"

	local copied=""
	while IFS= read -r s; do
		[ -n "$s" ] || continue
		if script_code "$mutant" | grep -qF -- "$s"; then copied="${copied}${s} "; fi
	done < <(recipe_step_identifiers)
	[ -z "$copied" ]
}

# ═══ The agent-trust adjacency rule ══════════════════════════════════════════

@test "DEMOPIPE ADJACENCY agent-trust-local.sh runs immediately after signalloom-local.sh" {
	# The rule: agent-trust-local.sh snapshots its sibling ResourceSets' inputs,
	# does its own fleet refresh (which reapplies the declarative `inputs: []`),
	# then restores the snapshot — so it has to OBSERVE those inputs active.
	# Anything inserted between the two is a window in which the ten-minute
	# flux-system reconcile blanks them first; the snapshot restores nothing,
	# signalloom-infra never goes Ready, and preflight_bao waits its full 600s.
	# Moving agent-trust earlier is worse than omitting it: a fast failure
	# becomes a ten-minute hang.
	#
	# Asserted on the RECIPE because delegating is what enforces it — there is no
	# room in the pipeline to insert anything, by construction.
	local body idx=0 sl_idx=-1 at_idx=-1 line
	while IFS= read -r line; do
		case "$line" in
			*"./scripts/signalloom-local.sh up"*)  sl_idx=$idx ;;
			*"./scripts/agent-trust-local.sh up"*) at_idx=$idx ;;
		esac
		idx=$((idx + 1))
	done < <(recipe_body)

	# Both present — an absent step would leave both at -1 and satisfy any naive
	# difference check.
	[ "$sl_idx" -ge 0 ]
	[ "$at_idx" -ge 0 ]
	[ "$at_idx" -eq $((sl_idx + 1)) ]
}

@test "DEMOPIPE ADJACENCY MUTATION inserting a step between the two is detected" {
	local mutant="$BATS_TEST_TMPDIR/Makefile.mutant"
	# Insert a step between the two script invocations, which is the exact defect.
	awk '{ print } /\.\/scripts\/signalloom-local\.sh up/ { print "\t$(MAKE) something-inserted" }' \
		"$makefile" >"$mutant"

	# The mutation landed where it was aimed.
	run grep -c 'something-inserted' "$mutant"
	[ "$output" -eq 1 ]

	local idx=0 sl_idx=-1 at_idx=-1 line
	while IFS= read -r line; do
		case "$line" in
			*"./scripts/signalloom-local.sh up"*)  sl_idx=$idx ;;
			*"./scripts/agent-trust-local.sh up"*) at_idx=$idx ;;
		esac
		idx=$((idx + 1))
	done < <(sed -n '/^demo-signalloom-up:/,/^[^\t#]/p' "$mutant" \
		| grep -E '^	' | grep -vE '^	#' | sed 's/^	*//' | grep -vE '^$')

	[ "$sl_idx" -ge 0 ]
	[ "$at_idx" -ge 0 ]
	[ "$at_idx" -ne $((sl_idx + 1)) ]
}

# ═══ The trap ════════════════════════════════════════════════════════════════

@test "DEMOPIPE TRAP captures rc first and ends with an explicit exit of it" {
	# The structural half. The behavioural half is the mutation test below.
	local body
	body="$(sed -n '/^on_pipeline_exit()/,/^}/p' "$script")"
	[ -n "$body" ]

	# First statement is the capture.
	run bash -c "printf '%s\n' \"\$1\" | grep -vE '^\s*#|^\s*\$' | sed -n '2p'" _ "$body"
	[[ "$output" == *'local rc=$?'* ]]

	# Last statement is the explicit exit.
	run bash -c "printf '%s\n' \"\$1\" | grep -vE '^\s*#|^\s*\$' | tail -2 | head -1" _ "$body"
	[[ "$output" == *'exit "$rc"'* ]]

	# Every cleanup call inside the trap tolerates its own failure.
	run bash -c "printf '%s\n' \"\$1\" | grep -c 'write_terminal_summary \"\$rc\" || true'" _ "$body"
	[ "$output" -eq 1 ]
}

@test "DEMOPIPE TRAP REGRESSION MUTATION a trap without the explicit exit corrupts a green verdict" {
	# On 2026-08-14 a run with 8/8 green stages was reported as a failure because
	# the last command of an EXIT trap was a false test and `set -e` handed its
	# status to the shell. This proves the assertion above measures the mechanism
	# rather than an accident of layout: on a COPY the trap's closing
	# `exit "$rc"` becomes a condition that evaluates false.
	local mutant="$BATS_TEST_TMPDIR/trapmutant.sh"
	sed '0,/^  exit "\$rc"$/s//  [ "$PIPELINE_PHASE" = "impossible-phase" ]/' \
		"$script" >"$mutant"
	chmod +x "$mutant"

	# The mutation landed, and only on the trap: counted at the statement site,
	# because the header comments also contain the string and matching those
	# would let a no-op sed report success.
	run grep -c '^  exit "\$rc"$' "$script"
	[ "$output" -eq 1 ]
	run grep -c '^  exit "\$rc"$' "$mutant"
	[ "$output" -eq 0 ]

	# Mutant: an otherwise-passing run reports failure.
	run bash "$mutant"
	[ "$status" -ne 0 ]
	[ "$(summary_field outcome)" = "PASS" ]

	# Paired positive on the real script, same scenario: still 0, and that is
	# what makes the mutant's non-zero attributable to the mutation.
	rm -rf "$reports"
	: >"$LOG"
	run bash "$script"
	[ "$status" -eq 0 ]
	[ "$(summary_field outcome)" = "PASS" ]
}

# ═══ The happy path ══════════════════════════════════════════════════════════

@test "DEMOPIPE PASS a clean run exits 0 and records a PASS verdict" {
	run bash "$script"
	[ "$status" -eq 0 ]
	[ -f "$reports/summary.json" ]
	[ "$(summary_field outcome)" = "PASS" ]
	[ "$(summary_field overall)" = "PASS" ]
	[ "$(summary_number failed)" -eq 0 ]
	[ "$(summary_number total_stages)" -ge 20 ]
}

@test "DEMOPIPE ORDER cheap static gates run before any cluster work" {
	run bash "$script"
	[ "$status" -eq 0 ]
	# The dashboard unit suite, the bats gates and the language suites all
	# precede `make cluster`. Catching a lockfile desync here costs seconds;
	# catching it after bring-up costs the bring-up.
	assert_before '^bats .*acceptance-spec-coverage\.bats' '^make cluster$'
	assert_before '^bun run test' '^make cluster$'
	assert_before '^go test' '^make cluster$'
	assert_before '^uv run' '^make cluster$'
}

@test "DEMOPIPE ORDER the bring-up sequence is cluster, registry, keys, foundation, bootstrap" {
	run bash "$script"
	[ "$status" -eq 0 ]
	assert_before '^make cluster$'               '^make registry$'
	assert_before '^make registry$'              '^make signing-keys$'
	assert_before '^make signing-keys$'          '^make push-local-foundation$'
	assert_before '^make push-local-foundation$' '^make bootstrap-local$'
	assert_before '^make bootstrap-local$'       'kubectl .*wait kustomization/flux-system'
	assert_before 'kubectl .*wait kustomization/flux-system' '^make demo-signalloom-up$'
}

@test "DEMOPIPE ORDER install-ci-tools runs before setup.sh" {
	# Reversing them makes setup.sh compile crane from source before the pinned
	# pre-built binary would ever have been considered.
	run bash "$script"
	[ "$status" -eq 0 ]
	assert_before 'install-ci-tools\.sh' 'scripts/setup\.sh'
}

@test "DEMOPIPE ORDER staleness is proven before anything asserts against the running system" {
	# On 2026-08-13 a fully-tested fix was reported working while the pods
	# answering requests predated all 22 of its commits. Every test was green;
	# every one tested the source tree. This ordering is what makes the runtime
	# and browser stages mean anything about this checkout.
	run bash "$script"
	[ "$status" -eq 0 ]
	assert_before '^make demo-signalloom-test$'     '^make check-deployed-staleness$'
	assert_before '^make check-deployed-staleness$' 'check-flux-substitution\.sh'
	assert_before '^make check-deployed-staleness$' '^bats .*api-adversarial\.bats'
	assert_before '^make check-deployed-staleness$' 'acceptance-test\.sh'
	# `make -C d2-signalloom test` globs d2-signalloom/test/*.bats, which includes
	# runtime.bats, test-1-runtime.bats and api-route-liveness.bats — cluster
	# suites, whatever the stage number suggests. vm-pipeline.sh runs it as stage
	# 1, ahead of the staleness proof; here it comes after, because a cluster
	# suite that runs before 6b produces a result that cannot be attributed to
	# the tree under test.
	assert_before '^make check-deployed-staleness$' '^make -C d2-signalloom test$'
}

@test "DEMOPIPE ORDER the demo is published before the browser stages drive it" {
	# acceptance-test.sh REUSES an existing listener on 30754 and only kills the
	# forwards it started itself, so publishing first means the browser stages
	# exercise the exact endpoint the operator will open. Published afterwards,
	# the handed-over URL is the one thing in the run that nothing tested.
	run bash "$script"
	[ "$status" -eq 0 ]
	assert_before '^supervise up ' 'acceptance-test\.sh'
}

# ═══ Publishing ══════════════════════════════════════════════════════════════

@test "DEMOPIPE PUBLISH forwards human access to dashboard Nginx on 8080" {
	run bash "$script"
	[ "$status" -eq 0 ]

	# Observed argument vector and environment, not a grep of the source: a port
	# number in a comment would satisfy a source grep perfectly.
	run grep -E '^supervise up ' "$LOG"
	[ "$status" -eq 0 ]

	# state-dir namespace service LOCAL REMOTE probe-path owner-pid
	[[ "$output" == *" fe-signalloom dashboard-signalloom 8080 8080 / "* ]]
	[[ "$output" == *"PF_ADDRESS=[0.0.0.0]"* ]]
	[[ "$output" == *"PF_PROBE_URL=[http://127.0.0.1:8080/]"* ]]
	[[ "$output" != *"cluster-envoy"* ]]
	[[ "$output" != *"30754"* ]]
}

@test "DEMOPIPE PUBLISH the forward outlives this process by being owned by pid 1" {
	# supervise-port-forward stops itself when its owner dies — the guard that
	# stops a hard-killed CI job orphaning a kubectl. A demo inverts that: the
	# forward must survive this script, so the owner is init.
	run bash "$script"
	[ "$status" -eq 0 ]
	run grep -E '^supervise up ' "$LOG"
	[[ "$output" == *" / 1 "* ]]
}

@test "DEMOPIPE PUBLISH 8080 and 0.0.0.0 are the DEFAULTS, not merely reachable values" {
	# The tests above run with the defaults in force, but a future edit could
	# make them defaults in name only. Human access terminates at dashboard Nginx;
	# the IAP tunnel connects to the internal IP, so loopback is unreachable.
	grep -qE 'DASHBOARD_LOCAL_PORT="\$\{DEMO_DASHBOARD_LOCAL_PORT:-8080\}"' "$script"
	grep -qE 'DASHBOARD_BIND_ADDRESS="\$\{DEMO_DASHBOARD_BIND_ADDRESS:-0\.0\.0\.0\}"' "$script"
	grep -qE 'PF_OWNER_PID="\$\{DEMO_PF_OWNER_PID:-1\}"' "$script"
}

@test "DEMOPIPE PUBLISH leaves acceptance Gateway forwarding on 30754" {
	local acceptance="$repo/scripts/acceptance-test.sh"
	grep -q 'gateway_local_port=30754' "$acceptance"
	grep -qE 'DASHBOARD_LOCAL_PORT="\$\{DEMO_DASHBOARD_LOCAL_PORT:-8080\}"' "$script"
}

@test "DEMOPIPE PUBLISH does not discover an Envoy data plane" {
	# Publishing names the stable dashboard Service directly; an Envoy discovery
	# result must not affect the human handover.
	export STUB_GATEWAY_SVC="ingress cluster-envoy"
	run bash "$script"
	[ "$status" -eq 0 ]
	run grep -F "supervise up $DEMO_PF_STATE_DIR fe-signalloom dashboard-signalloom 8080 8080 / 1" "$LOG"
	[ "$status" -eq 0 ]
}

@test "DEMOPIPE PUBLISH a supervisor that cannot establish the forward fails the stage" {
	export STUB_SUPERVISE_RC=1
	run bash "$script"
	[ "$status" -ne 0 ]
	[ "$(summary_field outcome)" = "FAIL" ]
}

@test "DEMOPIPE HANDOVER the run prints the URL, the Dex user and the password" {
	run bash "$script"
	[ "$status" -eq 0 ]
	log_contains "http://dashboard.osramp.acme.local:8080/"
	log_contains "demo-user@signalloom.local"
	log_contains "Password:  demo-user"
	# And machine-readably, so the hand-off does not depend on scraping a log.
	[ "$(summary_field demo_url)" = "http://dashboard.osramp.acme.local:8080/" ]
	[ "$(summary_field demo_user)" = "demo-user@signalloom.local" ]
	[ "$(summary_field demo_password)" = "demo-user" ]
}

@test "DEMOPIPE HANDOVER the demo password matches the bcrypt hash Dex actually ships" {
	# Exporting the wrong DEX_DEMO_PASSWORD in CI silently broke every Dex
	# password grant, and it surfaced as an authentication error rather than as a
	# configuration one. The two files must agree, so the test reads both.
	local dex="$repo/d2-signalloom/infra/inf-signalloom/base/dex.yaml"
	[ -f "$dex" ]
	grep -q 'bcrypt("demo-user")' "$dex"
	grep -q 'email: demo-user@signalloom.local' "$dex"
	grep -qE 'DEX_DEMO_PASSWORD="\$\{DEX_DEMO_PASSWORD:-demo-user\}"' "$script"
}

# ═══ Never tear the demo down ════════════════════════════════════════════════

@test "DEMOPIPE NOTEARDOWN a passing run tears nothing down" {
	run bash "$script"
	[ "$status" -eq 0 ]
	assert_absent '^make teardown'
	assert_absent 'kind delete'
	assert_absent '^supervise down'
}

@test "DEMOPIPE NOTEARDOWN a FAILING run leaves the demo standing too" {
	# The debugging case, and the one an operator actually needs: three red
	# stages and a live cluster beats a green report and nothing to look at.
	export STUB_FAIL_MATCH='^bats .*api-adversarial'
	run bash "$script"
	[ "$status" -ne 0 ]
	[ "$(summary_field outcome)" = "FAIL" ]
	assert_absent '^make teardown'
	assert_absent '^supervise down'
	# Still published.
	run grep -cE '^supervise up ' "$LOG"
	[ "$output" -eq 1 ]
}

@test "DEMOPIPE NOTEARDOWN --recreate is the ONLY path to a teardown" {
	run bash "$script" --recreate
	[ "$status" -eq 0 ]
	run grep -cE '^make teardown' "$LOG"
	[ "$output" -eq 1 ]
	# And it happens before the cluster is created, not after the demo is built.
	assert_before '^make teardown' '^make cluster$'
}

@test "DEMOPIPE NOTEARDOWN MUTATION the guard fires on an unconditional teardown" {
	# Proves the assertion above is measuring behaviour rather than the absence
	# of a make stub. On a COPY the teardown is hoisted out of the conditional.
	local mutant="$BATS_TEST_TMPDIR/teardown-mutant.sh"
	sed 's/^if ((RECREATE)); then$/if true; then/' "$script" >"$mutant"
	chmod +x "$mutant"
	run grep -c '^if true; then$' "$mutant"
	[ "$output" -eq 1 ]

	run bash "$mutant"
	[ "$status" -eq 0 ]
	run grep -cE '^make teardown' "$LOG"
	[ "$output" -ge 1 ]
}

# ═══ Terminal-state honesty ══════════════════════════════════════════════════

@test "DEMOPIPE ABORT a run that dies before the stage list writes an ABORTED verdict" {
	# "Reports present, no summary" is what an abort, a pass whose collection
	# failed, and a run that never started all look like. On 2026-08-13 that
	# ambiguity was read as a pass twice in one session.
	export STUB_FAIL_MATCH='^make cluster$'
	run bash "$script"
	[ "$status" -ne 0 ]
	[ -f "$reports/summary.json" ]
	[ "$(summary_field outcome)" = "ABORTED" ]
	[ "$(summary_field overall)" = "ABORTED" ]
	[ "$(summary_field phase)" = "create-cluster" ]
	[[ "$(cat "$reports/summary.json")" == *"NOT a test result"* ]]
	# It never reached the estate, and it says so rather than implying a demo.
	assert_absent '^make demo-signalloom-up$'
	grep -q '"demo_published": false' "$reports/summary.json"
}

@test "DEMOPIPE ABORT a missing work dir exits 2 and still writes a verdict" {
	export DEMO_WORK_DIR="$BATS_TEST_TMPDIR/definitely-not-here"
	run bash "$script"
	[ "$status" -eq 2 ]
	[ "$(summary_field outcome)" = "ABORTED" ]
	[ "$(summary_number exit_code)" -eq 2 ]
}

@test "DEMOPIPE ABORT the abort writer is jq-free" {
	# The tool installers are what put jq on the box, so the early-abort case
	# this writer exists for is precisely the case where jq is absent. A writer
	# that shells out to jq would produce no verdict in the one situation it was
	# built for.
	local body
	body="$(sed -n '/^write_terminal_summary()/,/^}/p' "$script")"
	[ -n "$body" ]
	run bash -c "printf '%s\n' \"\$1\" | grep -c 'jq'" _ "$body"
	[ "$output" -eq 0 ]

	# And behaviourally: abort with jq removed from PATH entirely.
	rm -f "$stubdir/jq"
	export STUB_FAIL_MATCH='^make cluster$'
	PATH="$stubdir:/usr/bin:/bin" run bash "$script"
	[ "$status" -ne 0 ]
	[ "$(summary_field outcome)" = "ABORTED" ]
}

@test "DEMOPIPE ABORT a real verdict is NEVER overwritten by the trap" {
	# A completed run — pass or fail — must be reported exactly as it reported
	# itself. An abort-time writer that clobbers a real result turns a known
	# outcome into an unknown one, which is strictly worse than saying nothing.
	mkdir -p "$reports"
	printf '{"outcome":"SENTINEL","overall":"SENTINEL"}\n' >"$reports/summary.json"

	export STUB_FAIL_MATCH='^make cluster$'
	run bash "$script"
	[ "$status" -ne 0 ]
	[ "$(summary_field outcome)" = "SENTINEL" ]
}

@test "DEMOPIPE ABORT MUTATION removing the overwrite guard does clobber a real verdict" {
	# The paired positive: without it, the test above cannot tell a working guard
	# from a writer that never runs.
	local mutant="$BATS_TEST_TMPDIR/clobber.sh"
	# Targets ${SUMMARY_FILE}, which is what write_terminal_summary now guards
	# on. It read ${REPORT_DIR}/summary.json until the summary path became
	# injectable (demo-up.sh sends DEMO_SUMMARY_FILE so the driver's
	# GCP_TF_DEMO_SUMMARY_NAME cannot name a file this script never writes).
	#
	# The landed-check below is why that rename surfaced here as a red test
	# instead of a silent one: a sed whose pattern stops matching is a no-op that
	# exits 0, so without it this mutation test would have gone on "passing"
	# while mutating nothing at all.
	sed 's#^  \[\[ -f "\${SUMMARY_FILE}" \]\] && return 0$#  :#' \
		"$script" >"$mutant"
	chmod +x "$mutant"
	# The mutation landed. Asserted against the ORIGINAL, so a pattern that stops
	# matching fails here rather than downstream.
	run grep -c '\${SUMMARY_FILE}" \]\] && return 0' "$script"
	[ "$output" -eq 1 ]
	run grep -c '\${SUMMARY_FILE}" \]\] && return 0' "$mutant"
	[ "$output" -eq 0 ]

	mkdir -p "$reports"
	printf '{"outcome":"SENTINEL","overall":"SENTINEL"}\n' >"$reports/summary.json"
	export STUB_FAIL_MATCH='^make cluster$'
	run bash "$mutant"
	[ "$status" -ne 0 ]
	[ "$(summary_field outcome)" = "ABORTED" ]
}

# ═══ Carried-over CI environment ═════════════════════════════════════════════

@test "DEMOPIPE ENV observability is off and the wait statistics are collected" {
	# kube-prometheus-stack and trivy-system are not dependencies of any demo
	# slice and dominate bring-up time. WAIT_STAT_FILE is the one that was lost
	# for months: scripts/lib/wait.sh emits a ranked deadline statistic per wait
	# and appends it nowhere unless this is set, so the signal the library exists
	# to produce was discarded on every run.
	grep -qE 'ENABLE_OBSERVABILITY="\$\{ENABLE_OBSERVABILITY:-false\}"' "$script"
	grep -qE 'WAIT_STAT_FILE="\$\{WAIT_STAT_FILE:-\$\{REPORT_DIR\}/wait-stats\.txt\}"' "$script"

	# Behaviourally: both are exported into the environment the stages see.
	run bash -c "set -a; source <(grep -E '^export (ENABLE_OBSERVABILITY|DEX_DEMO_PASSWORD)=' '$script'); echo \"\$ENABLE_OBSERVABILITY \$DEX_DEMO_PASSWORD\""
	[ "$output" = "false demo-user" ]
}

# ═══ Registration ════════════════════════════════════════════════════════════

@test "DEMOPIPE this suite is invoked by the pipeline it tests" {
	# A bats suite that no runner names provides zero regression protection,
	# however green it is by hand: 33 suites in this repo sat in exactly that
	# state. The demo pipeline runs this file among its static gates, and
	# d2-signalloom/test/bats-registry-coverage.bats treats demo-pipeline.sh as a
	# runner so the registration is checked rather than assumed.
	script_code | grep -qF 'test/gcp-demo-pipeline.bats'

	local registry="$repo/d2-signalloom/test/bats-registry-coverage.bats"
	[ -f "$registry" ]
	grep -qF 'scripts/gcp-tf/demo-pipeline.sh' "$registry"
}
