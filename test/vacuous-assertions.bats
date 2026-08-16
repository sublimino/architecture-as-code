#!/usr/bin/env bats
#
# Prove that scripts/check-vacuous-assertions.sh can fail.
#
# A linter for checks that cannot fail is the single worst thing to ship without
# a failure proof, because its green output is a claim about the quality of
# every other check in the tree. If it silently matches nothing, it launders the
# exact defect it was written to find. So every rule below is driven with an
# injected violation and required to go RED, then with the violation removed and
# required to go GREEN — the red half is the assertion that matters.
#
# Three shapes are tested for each rule:
#
#   RED      the violation is present  -> exit 1, and the output NAMES the rule
#            and the file. "Exit 1" alone is not enough: a script that fails for
#            an unrelated reason also exits 1.
#   GREEN    the violation is removed  -> exit 0.
#   CONTROL  a near-miss that must NOT fire. Every rule here has a legitimate
#            lookalike (`--for=condition=ready pod/x` is CORRECT; a status check
#            alongside an output check is CORRECT), and a rule that cannot tell
#            them apart gets switched off within a week of landing.
#
# Everything runs against a fixture tree in BATS_TEST_TMPDIR. Nothing in this
# file writes to the repository — the scanner is a read-only guard and its own
# proof must not be the thing that violates that.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
	script="$repo_root/scripts/check-vacuous-assertions.sh"
	allowlist="$repo_root/scripts/vacuous-assertions.allow"

	fixture="$BATS_TEST_TMPDIR/tree"
	mkdir -p "$fixture"

	# An allowlist that is empty by default, so a fixture finding is not
	# accidentally suppressed by the repo's real one.
	empty_allow="$BATS_TEST_TMPDIR/empty.allow"
	: >"$empty_allow"
}

# Write a bats fixture, appending if the file already exists. Body on stdin.
#
# The `@test` token is assembled with printf at runtime, and that is not style.
# bats preprocesses this file before executing it, rewriting every line that
# looks like `@test "..." {` into its internal `bats_test_function ... ;
# test_x() {` form — INCLUDING inside a quoted heredoc. Fixtures written the
# obvious way therefore landed on disk as preprocessed bats internals, so the
# scanner found no @test in them at all and every RED test in this file passed
# green. Observed, not theorised: tests 5, 13, 24 and 28 all reported "no
# findings" over a fixture that was nothing but findings.
#
# That is precisely the defect this suite exists to catch, arriving through the
# test harness rather than the code under test, and it is the reason the RED
# assertions here check for the RULE NAME in the output and not merely exit 1.
bats_fixture() { # file name  (body on stdin)
	local file="$1" name="$2"
	{
		printf '@%s "%s" {\n' test "$name"
		cat
		printf '}\n\n'
	} >>"$file"
}

# Run the scanner over the fixture tree with the fixture allowlist.
#
# `export`, not a `VAR=x run ...` prefix: `run` is a shell FUNCTION, so a
# prefix assignment sets a shell variable in the caller rather than putting it
# in the child process's environment, and the scanner would silently fall back
# to the real repo root.
scan() {
	export VACUOUS_REPO_ROOT="$fixture"
	export VACUOUS_ALLOWLIST="${1:-$empty_allow}"
	run "$script" "$fixture"
}

# ── The mechanism itself ────────────────────────────────────────────────────

@test "VACUOUS the script exists and is executable" {
	# Mechanism-presence. Every other test here shells out to $script; if it
	# were missing they would fail for that reason and read as rule failures.
	[ -f "$script" ]
	[ -x "$script" ]
}

@test "VACUOUS an empty directory is exit 2, not exit 0" {
	# THE test in this file. A scanner that finds nothing because it read
	# nothing must not report the same code as one that read the tree and
	# cleared it. Collapsing those two is the defect this whole script exists
	# to remove, so it must not contain it.
	mkdir -p "$BATS_TEST_TMPDIR/nothing"
	VACUOUS_ALLOWLIST="$empty_allow" run "$script" "$BATS_TEST_TMPDIR/nothing"
	[ "$status" -eq 2 ]
	[[ "$output" == *"CANNOT SCAN"* ]]
	[[ "$output" == *"EMPTY"* ]]
	[[ "$output" == *"NOT a pass"* ]]
}

@test "VACUOUS a path that does not exist is exit 2" {
	VACUOUS_ALLOWLIST="$empty_allow" run "$script" "$BATS_TEST_TMPDIR/no-such-dir"
	[ "$status" -eq 2 ]
	[[ "$output" == *"no such path"* ]]
}

@test "VACUOUS a clean fixture tree is exit 0 and says what it scanned" {
	bats_fixture "$fixture/clean.bats" "a real assertion" <<'BODY'
	run echo hello
	[ "$status" -eq 0 ]
	[ "$output" = "hello" ]
BODY
	scan
	[ "$status" -eq 0 ]
	[[ "$output" == *"no VAC001-VAC006 findings"* ]]
}

@test "VACUOUS the scanner never modifies what it scans" {
	# VERIFY AND FAIL, NEVER REPAIR. A guard in this repo has already shipped
	# that auto-fixed what it detected: CI went green, the guard passed, and the
	# broken component stayed broken because nothing ever went red.
	bats_fixture "$fixture/dirty.bats" "hollow" <<'BODY'
	run some_command
BODY
	local before after
	before="$(cksum "$fixture/dirty.bats")"
	scan
	[ "$status" -eq 1 ]
	after="$(cksum "$fixture/dirty.bats")"
	[ "$before" = "$after" ]
}

# ── VAC001: >= 0 on a counter in a readiness expression ─────────────────────

@test "VAC001 RED on an inline readyExpr gated by observedGeneration >= 0" {
	cat >"$fixture/rs.yaml" <<'YAML'
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
spec:
  inputsFrom:
    - readyExpr: status.observedGeneration >= 0
YAML
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC001"* ]]
	[[ "$output" == *"rs.yaml"* ]]
}

@test "VAC001 RED on a BLOCK readyExpr, which a line-oriented grep misses" {
	# This is the form that shipped five times. `grep 'readyExpr.*>= 0'` does
	# not see it, because the expression is on a following line.
	cat >"$fixture/block.yaml" <<'YAML'
spec:
  dependsOn:
    - readyExpr: |
        status.observedGeneration >= 0
YAML
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC001"* ]]
	[[ "$output" == *"block.yaml"* ]]
}

@test "VAC001 GREEN once the expression asserts something real" {
	cat >"$fixture/rs.yaml" <<'YAML'
spec:
  dependsOn:
    - readyExpr: status.observedGeneration == metadata.generation
YAML
	scan
	[ "$status" -eq 0 ]
}

# ── VAC002: --for=condition=ready on a kind with no Ready condition ─────────

@test "VAC002 RED on --for=condition=ready against a Deployment" {
	cat >"$fixture/wait.sh" <<'SH'
kubectl -n demo wait deployment/openbao --for=condition=ready --timeout=5m
SH
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC002"* ]]
	[[ "$output" == *"wait.sh"* ]]
}

@test "VAC002 CONTROL does not fire on a Pod, which HAS a Ready condition" {
	# The rule keys on the resource kind, not on the string. Without this the
	# rule would flag every correct wait in the tree and get deleted.
	cat >"$fixture/wait.sh" <<'SH'
kubectl -n demo wait pod/openbao-0 --for=condition=ready --timeout=5m
kubectl wait --for=condition=Ready nodes --all --timeout=3m
SH
	scan
	[ "$status" -eq 0 ]
}

@test "VAC002 CONTROL does not fire on a comment describing the trap" {
	# scripts/supercred-demo.sh documents this exact anti-pattern in a comment.
	# Flagging the warning is how a linter teaches people to ignore it.
	cat >"$fixture/wait.sh" <<'SH'
# wait_rollout, not wait_k8s_ready: `kubectl wait --for=condition=ready
# deployment/openbao` never returns, because a Deployment has no Ready condition.
kubectl -n demo rollout status deployment/openbao --timeout=5m
SH
	scan
	[ "$status" -eq 0 ]
}

@test "VAC002 GREEN once the condition is one the kind actually reports" {
	cat >"$fixture/wait.sh" <<'SH'
kubectl -n demo wait deployment/openbao --for=condition=Available --timeout=5m
SH
	scan
	[ "$status" -eq 0 ]
}

# ── VAC003: the only assertion is a negative status check ───────────────────

@test "VAC003 RED when a test asserts only that something failed" {
	# The shipped defect: the container was distroless, so the kubectl exec
	# under test always failed with "executable not found". The test passed
	# identically whether the authorisation it claimed to prove existed or not.
	bats_fixture "$fixture/auth.bats" "the agent may not read the vault path" <<'BODY'
	run kubectl exec -n demo pod/agent -- wget -qO- http://vault/v1/secret
	[ "$status" -ne 0 ]
BODY
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC003"* ]]
	[[ "$output" == *"auth.bats"* ]]
	[[ "$output" == *"including the command not existing"* ]]
}

@test "VAC003 CONTROL does not fire when the test also asserts WHY it failed" {
	bats_fixture "$fixture/auth.bats" "the agent may not read the vault path" <<'BODY'
	run kubectl exec -n demo pod/agent -- wget -qO- http://vault/v1/secret
	[ "$status" -ne 0 ]
	[[ "$output" == *"permission denied"* ]]
BODY
	scan
	[ "$status" -eq 0 ]
}

@test "VAC003 CONTROL does not fire on a status check used as one disjunct" {
	# `[ "$output" = "0" ] || [ "$status" -ne 0 ]` examines the output and is
	# a correct idiom for "grep -c found nothing". An unanchored rule flagged it.
	bats_fixture "$fixture/count.bats" "no references remain" <<'BODY'
	run grep -c 'forbidden' file.txt
	[ "$output" = "0" ] || [ "$status" -ne 0 ]
BODY
	scan
	[ "$status" -eq 0 ]
}

@test "VAC003 GREEN once the failure signature is asserted" {
	bats_fixture "$fixture/auth.bats" "the agent may not read the vault path" <<'BODY'
	[ -f "$manifest" ]
	run kubectl exec -n demo pod/agent -- wget -qO- http://vault/v1/secret
	[ "$status" -eq 8 ]
BODY
	scan
	[ "$status" -eq 0 ]
}

# ── VAC004: tautologies ─────────────────────────────────────────────────────

@test "VAC004 RED on a comparison with the same operand both sides" {
	cat >"$fixture/taut.sh" <<'SH'
[ "$version" = "$version" ]
SH
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC004"* ]]
	[[ "$output" == *"same operand"* ]]
}

@test "VAC004 RED on -n over a literal" {
	cat >"$fixture/taut.sh" <<'SH'
[ -n "$(echo x)" ]
SH
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC004"* ]]
	[[ "$output" == *"true by construction"* ]]
}

@test "VAC004 RED on -ge 0 over a count" {
	cat >"$fixture/taut.sh" <<'SH'
[ "$(grep -c pattern file)" -ge 0 ]
SH
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC004"* ]]
	[[ "$output" == *"never returns a negative"* ]]
}

@test "VAC004 RED on -ge 0 over a status" {
	cat >"$fixture/taut.sh" <<'SH'
[ "$status" -ge 0 ]
SH
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC004"* ]]
}

@test "VAC004 RED when || true swallows the assertion" {
	cat >"$fixture/taut.sh" <<'SH'
[ "$count" -eq 3 ] || true
SH
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC004"* ]]
	[[ "$output" == *"swallows the failure"* ]]
}

@test "VAC004 CONTROL does not fire on || true after a non-assertion" {
	# `rm -f x || true` and `grep ... || true` in a data pipeline are normal and
	# correct. The rule fires only when an ASSERTION is the thing being swallowed.
	cat >"$fixture/taut.sh" <<'SH'
rm -f /tmp/scratch || true
excluded="$(grep -v '^$' list.txt || true)"
SH
	scan
	[ "$status" -eq 0 ]
}

@test "VAC004 GREEN once the comparison compares two different things" {
	cat >"$fixture/taut.sh" <<'SH'
[ "$actual" = "$expected" ]
SH
	scan
	[ "$status" -eq 0 ]
}

# ── VAC005: a test with no assertion at all ────────────────────────────────

@test "VAC005 RED on a test body that only runs commands" {
	# The real finding: d2-osramp-apps/test/osramp.bats "uptime check: NATS"
	# was two `run verify` lines and nothing else. It passed whether NATS was
	# running, absent, or the cluster unreachable.
	bats_fixture "$fixture/uptime.bats" "uptime check: NATS" <<'BODY'
	DEBUG_DETIK="true"

	run verify "'status' is 'running' for pods named 'nats'"
	run verify "there is 1 service named 'nats'"
BODY
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC005"* ]]
	[[ "$output" == *"passes unconditionally"* ]]
}

@test "VAC005 CONTROL does not fire on a skipped test" {
	bats_fixture "$fixture/uptime.bats" "uptime check: NATS" <<'BODY'
	skip "needs a cluster"
	run verify "'status' is 'running' for pods named 'nats'"
BODY
	scan
	[ "$status" -eq 0 ]
}

@test "VAC005 CONTROL does not fire on a bare command that can fail" {
	# In bats a bare non-zero command fails the test, so `grep -q` IS an
	# assertion even though it is not written as one. Treating it otherwise
	# would flag a large and correct part of this tree.
	bats_fixture "$fixture/bare.bats" "the manifest names the image" <<'BODY'
	grep -q 'image: demo' manifest.yaml
BODY
	scan
	[ "$status" -eq 0 ]
}

@test "VAC005 GREEN once the run results are checked" {
	bats_fixture "$fixture/uptime.bats" "uptime check: NATS" <<'BODY'
	run verify "'status' is 'running' for pods named 'nats'"
	[ "$status" -eq 0 ]
BODY
	scan
	[ "$status" -eq 0 ]
}

# ── VAC006: run with no $status / $output check ────────────────────────────

@test "VAC006 RED when run is followed by real work but never examined" {
	# Distinct from VAC005: this body DOES contain failable commands, so it is
	# not unconditional — but the `run` line in it asserts nothing, and the
	# thing it was added to check is unchecked.
	bats_fixture "$fixture/mixed.bats" "the rollout completes" <<'BODY'
	[ -f "$manifest" ]
	run kubectl rollout status deployment/demo
	grep -q 'kind: Deployment' "$manifest"
BODY
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC006"* ]]
	[[ "$output" == *"never fails the test"* ]]
}

@test "VAC006 CONTROL does not fire when \$output is examined" {
	bats_fixture "$fixture/mixed.bats" "the rollout completes" <<'BODY'
	[ -f "$manifest" ]
	run kubectl rollout status deployment/demo
	[[ "$output" == *"successfully rolled out"* ]]
BODY
	scan
	[ "$status" -eq 0 ]
}

@test "VAC006 CONTROL does not fire when a bats-assert helper is used" {
	bats_fixture "$fixture/mixed.bats" "the rollout completes" <<'BODY'
	[ -f "$manifest" ]
	run kubectl rollout status deployment/demo
	assert_success
BODY
	scan
	[ "$status" -eq 0 ]
}

@test "VAC006 GREEN once the status is checked" {
	bats_fixture "$fixture/mixed.bats" "the rollout completes" <<'BODY'
	[ -f "$manifest" ]
	run kubectl rollout status deployment/demo
	[ "$status" -eq 0 ]
BODY
	scan
	[ "$status" -eq 0 ]
}

# ── The allowlist ───────────────────────────────────────────────────────────

@test "ALLOW an entry with a stated reason suppresses its finding" {
	bats_fixture "$fixture/hollow.bats" "deliberately hollow" <<'BODY'
	run some_command
BODY
	cat >"$BATS_TEST_TMPDIR/a.allow" <<'ALLOW'
VAC005 | hollow.bats | deliberately hollow | fixture for the allowlist proof
ALLOW
	scan "$BATS_TEST_TMPDIR/a.allow"
	[ "$status" -eq 0 ]
	[[ "$output" == *"fixture for the allowlist proof"* ]]
	[[ "$output" == *"1 allowlisted"* ]]
}

@test "ALLOW an entry naming a file that no longer exists FAILS" {
	# A stale exception reads as reviewed-and-accepted while describing nothing,
	# and pre-approves whatever takes that name next.
	bats_fixture "$fixture/clean.bats" "real" <<'BODY'
	[ 1 -eq 2 ] || true
	true
BODY
	rm -f "$fixture/clean.bats"
	bats_fixture "$fixture/ok.bats" "real" <<'BODY'
	run echo x
	[ "$status" -eq 0 ]
BODY
	cat >"$BATS_TEST_TMPDIR/a.allow" <<'ALLOW'
VAC005 | deleted-file.bats | whatever | the file was removed months ago
ALLOW
	scan "$BATS_TEST_TMPDIR/a.allow"
	[ "$status" -eq 1 ]
	[[ "$output" == *"no longer exists"* ]]
	[[ "$output" == *"no longer describes this tree"* ]]
}

@test "ALLOW an entry whose anchored line is gone FAILS" {
	bats_fixture "$fixture/hollow.bats" "renamed since the exception was written" <<'BODY'
	run some_command
BODY
	cat >"$BATS_TEST_TMPDIR/a.allow" <<'ALLOW'
VAC005 | hollow.bats | the old test name | anchored on a name that has changed
ALLOW
	scan "$BATS_TEST_TMPDIR/a.allow"
	[ "$status" -eq 1 ]
	[[ "$output" == *"anchored line is gone"* ]]
}

@test "ALLOW an entry that suppresses nothing FAILS" {
	# The sharpest of the three. The code it excused has been fixed, and the
	# entry now silently pre-approves the next occurrence.
	bats_fixture "$fixture/fixed.bats" "was hollow, now checks its result" <<'BODY'
	run some_command
	[ "$status" -eq 0 ]
BODY
	cat >"$BATS_TEST_TMPDIR/a.allow" <<'ALLOW'
VAC005 | fixed.bats | was hollow | this was fixed, so the entry is dead
ALLOW
	scan "$BATS_TEST_TMPDIR/a.allow"
	[ "$status" -eq 1 ]
	[[ "$output" == *"suppresses nothing"* ]]
	[[ "$output" == *"dead pre-approval"* ]]
}

@test "ALLOW an entry with no stated reason FAILS" {
	bats_fixture "$fixture/hollow.bats" "hollow" <<'BODY'
	run some_command
BODY
	cat >"$BATS_TEST_TMPDIR/a.allow" <<'ALLOW'
VAC005 | hollow.bats | hollow
ALLOW
	scan "$BATS_TEST_TMPDIR/a.allow"
	[ "$status" -eq 1 ]
	[[ "$output" == *"malformed entry"* ]]
}

@test "ALLOW an entry does not suppress a different rule in the same file" {
	# One entry excuses one finding. Matching on file alone would let a single
	# line pre-approve every future defect in that file.
	bats_fixture "$fixture/two.bats" "hollow" <<'BODY'
	run some_command
BODY
	bats_fixture "$fixture/two.bats" "swallowed" <<'BODY'
	[ "$count" -eq 3 ] || true
	true
BODY
	cat >"$BATS_TEST_TMPDIR/a.allow" <<'ALLOW'
VAC005 | two.bats | hollow | only the hollow one is excused
ALLOW
	scan "$BATS_TEST_TMPDIR/a.allow"
	[ "$status" -eq 1 ]
	# The VAC004 finding survives.
	[[ "$output" == *"swallows the failure"* ]]
	# The VAC005 one does not. Asserted on the FINDING's message rather than on
	# the string "VAC005", because the allowlist's own "allowed: VAC005 ..."
	# line names the rule too — the first version of this assertion failed on
	# that and would have been "fixed" by weakening it.
	[[ "$output" != *"passes unconditionally"* ]]
	[[ "$output" == *"only the hollow one is excused"* ]]
}

# ── The real tree ───────────────────────────────────────────────────────────

@test "VACUOUS the repository itself has no vacuous assertions" {
	# The gate. Everything above proves the scanner works; this is the scanner
	# doing its job, and it is here as well as in the CI pipeline so a local
	# `bats test/vacuous-assertions.bats` catches a regression before push.
	run "$script"
	if [ "$status" -ne 0 ]; then
		echo "$output"
	fi
	[ "$status" -eq 0 ]
}

@test "VACUOUS the shipped allowlist is present and every entry is live" {
	# The file may legitimately contain only comments. What must not happen is
	# it going missing, because then a future entry has nowhere to land and the
	# staleness checks above never run against anything real.
	[ -f "$allowlist" ]
	# Covered by the previous test's exit 0 -- a stale entry is exit 1 -- but
	# asserted separately so a failure names the allowlist rather than the tree.
	run "$script"
	[ "$status" -eq 0 ]
	[[ "$output" != *"no longer describes this tree"* ]]
}
