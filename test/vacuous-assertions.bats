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
	[[ "$output" == *"no VAC001-VAC008 findings"* ]]
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

# ── VAC007: a loop fed by a mapfile whose command's status was discarded ────
#
# The shape that got past the six-rule version. `mapfile -t arr < <(cmd)`
# discards cmd's status; mapfile succeeds having read zero lines; the `for` over
# `arr` runs zero times; every check in the body reports nothing. Found in
# assert_openbao_accepts_spire_jwt_keys, which passed with KUBECONFIG=/nonexistent
# while this scanner cleared all 623 files around it.
#
# The CONTROLs matter more here than for any other rule, because the bare shape
# is ordinary bash and occurs 26 times in this repo. A rule that fires on all of
# them is a rule that gets switched off.

@test "VAC007 RED on an unguarded mapfile feeding a verification loop" {
	cat >"$fixture/staleness.sh" <<'SH'
main() {
	local requested=()
	mapfile -t requested < <(source_id_workloads)
	local workload
	for workload in "${requested[@]}"; do
		check_workload "$workload"
	done
}
SH
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC007"* ]]
	[[ "$output" == *"staleness.sh"* ]]
	[[ "$output" == *"runs zero times"* ]]
}

@test "VAC007 RED names the loop line, not just the mapfile line" {
	# The mapfile is not the defect on its own — the pairing is. A finding that
	# does not say which loop goes empty makes the reader re-derive the argument
	# every time, and a rule people have to re-derive is a rule they mute.
	cat >"$fixture/staleness.sh" <<'SH'
check_all() {
	mapfile -t items < <(list_items)
	for i in "${items[@]}"; do
		verify "$i" || return 1
	done
}
SH
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"the loop at line 3"* ]]
}

@test "VAC007 RED does not need a trailing || to fire" {
	# THE point of the rule's shape. mapfile succeeds whether or not the command
	# did, so the status is discarded with the `||` and without it. A rule keyed
	# on `|| return 1` would be nearly a no-op in this tree: of the 26
	# process-substitution mapfiles here only two carry one, both are benign, and
	# the one real defect has none.
	cat >"$fixture/nopipe.sh" <<'SH'
gate() {
	mapfile -t keys < <(kubectl get secrets -o name)
	for k in "${keys[@]}"; do
		[ -n "$k" ] || return 1
	done
}
SH
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC007"* ]]
}

@test "VAC007 CONTROL does not fire when the array is splatted into arguments" {
	# An empty array here means "no extra arguments". gcloud still runs and still
	# fails on its own merits, so nothing is silenced. This is what six of the
	# unguarded sites in this repo do, including all four in
	# scripts/gcp-tf/demo-up.sh.
	cat >"$fixture/args.sh" <<'SH'
vm_ssh() {
	local args=()
	mapfile -t args < <(gcloud_common)
	gcloud compute ssh "$INSTANCE_NAME" "${args[@]}" --command="$1"
}
SH
	scan
	[ "$status" -eq 0 ]
}

@test "VAC007 CONTROL does not fire when the count is checked" {
	cat >"$fixture/guarded.sh" <<'SH'
gate() {
	mapfile -t keys < <(spire_jwt_svid_keys "$ns")
	((${#keys[@]} > 0)) || {
		printf 'refusing to compare: SPIRE returned no keys\n' >&2
		return 1
	}
	for k in "${keys[@]}"; do
		verify "$k" || return 1
	done
}
SH
	scan
	[ "$status" -eq 0 ]
}

@test "VAC007 CONTROL a comment between the mapfile and its guard is not a defect" {
	# The window counts CODE lines. scripts/supercred-images.sh:205 has a correct
	# `((${#args[@]})) || return 0` ten lines below its mapfile, behind a
	# nine-line comment explaining the docker failure that motivated it. A naive
	# six-LINE window calls that a defect and is wrong.
	cat >"$fixture/commented.sh" <<'SH'
gate() {
	mapfile -t args < <(source_id_build_args "$image")
	# Return with NO output when there are no args, rather than falling through
	# to printf. `printf '%s\n'` runs its format once even with zero arguments,
	# so an image with no marker emitted a single blank line here; mapfile in
	# the caller turned that into a one-element array holding "", and docker
	# received an empty positional argument alongside the build context:
	#
	#   docker: 'docker build' requires 1 argument   (it had been handed two)
	#
	# Every SuperCred image failed to build, starting at cardvault:local.
	((${#args[@]})) || return 0
	for a in "${args[@]}"; do
		validate "$a" || return 1
	done
}
SH
	scan
	[ "$status" -eq 0 ]
}

@test "VAC007 CONTROL does not fire on a re-expansion of shell state" {
	# `printf '%s\n' "${AGENTS[@]}"` re-emits an array the script already holds.
	# There is no external state, no status worth propagating, and nothing
	# discarded. scripts/signalloom-agents.sh does exactly this, twice.
	cat >"$fixture/reexpand.sh" <<'SH'
pick() {
	mapfile -t picked < <(printf '%s\n' "${AGENTS[@]}")
	for entry in "${picked[@]}"; do
		create_agent "$entry" || return 1
	done
}
SH
	scan
	[ "$status" -eq 0 ]
}

@test "VAC007 CONTROL does not fire on a here-string or a file redirect" {
	# Neither has a command whose status could be discarded. `mapfile <<<"$var"`
	# reads a variable the caller already has, and `mapfile <file` reads a file
	# the shell itself opens — a failure to open is a failure of the redirect,
	# which the shell DOES report.
	cat >"$fixture/redirects.sh" <<'SH'
compare() {
	mapfile -t spire_keys <<<"$spire_out"
	for k in "${spire_keys[@]}"; do
		[ -n "$k" ] || return 1
	done
	mapfile -t offenders </tmp/audit.txt
	for o in "${offenders[@]}"; do
		report "$o" || return 1
	done
}
SH
	scan
	[ "$status" -eq 0 ]
}

@test "VAC007 CONTROL a same-named array in an unrelated function is not the loop" {
	# The forward scan stops at the end of the enclosing body. Without that, an
	# arg-builder would borrow the `for` from whatever function happened to come
	# next and report a defect neither one has.
	cat >"$fixture/separate.sh" <<'SH'
build_args() {
	local args=()
	mapfile -t args < <(source_id_build_args "$image")
	docker build "${args[@]}" -t "$image" .
}

validate_all() {
	local args=(a b c)
	for a in "${args[@]}"; do
		validate "$a" || return 1
	done
}
SH
	scan
	[ "$status" -eq 0 ]
}

@test "VAC007 GREEN once the empty case is refused" {
	cat >"$fixture/staleness.sh" <<'SH'
main() {
	local requested=()
	mapfile -t requested < <(source_id_workloads)
	if [ "${#requested[@]}" -eq 0 ]; then
		printf 'CANNOT VERIFY: the workload list came back EMPTY\n' >&2
		exit 2
	fi
	local workload
	for workload in "${requested[@]}"; do
		check_workload "$workload"
	done
}
SH
	scan
	[ "$status" -eq 0 ]
}

# ── VAC008: `cmd | grep -q` under pipefail, where the status is a verdict ───
#
# Every rule above describes a check that CANNOT FAIL. This one describes a
# check that can report the OPPOSITE OF THE TRUTH: `grep -q` exits at its first
# match, the producer takes SIGPIPE, and pipefail promotes 141 to the
# pipeline's status, so the pipeline answers FALSE PRECISELY WHEN IT MATCHES.
#
# ─── Why these proofs are STATIC, and must stay that way ───────────────────
#
# The obvious way to test this rule is to trigger the inversion and watch a
# guard get it wrong. That test would PASS WHILE TRIGGERING NOTHING under the
# Claude Code Bash tool, whose shell has SIGPIPE set to SIG_IGN
# (`grep SigIgn /proc/self/status` -> 0000000000001000, bit 12 = signal 13).
# Ignored dispositions are inherited, so the identical pipeline returns 0 there
# and 141 inside `bash -c`. A runtime proof of this rule can therefore be
# exactly the vacuous shape the rule exists to catch, reproduced inside the
# rule's own suite.
#
# So the RED/GREEN/CONTROL proofs below drive the SCANNER over fixture text and
# never execute a fixture. The one behavioural test is the MECHANISM control
# immediately below, and it refuses unless it actually observed the inversion.

@test "VAC008 MECHANISM the inversion is real, or this rule has no subject" {
	# The positive control for the rule's entire premise. A negative result is
	# worthless until the mechanism is known to have been exercised, so "it did
	# not invert" FAILS here rather than passing quietly.
	#
	# `bash -c` is load-bearing, not style: see the note above. Every real
	# script is a nested shell at the default disposition, so the mechanism is
	# live everywhere it matters and invisible in the one place — the harness
	# shell — where no script is ever run.
	run bash -c 'set -o pipefail; { echo MARKER; seq 1 300000; } | grep -Fq MARKER; echo "rc=$?"'
	[ "$status" -eq 0 ]
	[[ "$output" == *"rc=141"* ]]
}

@test "VAC008 RED on a refusal gated by a piped grep -q" {
	cat >"$fixture/setup-gate.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
verify_infra() {
  if ! kubectl -n flux-system get resourceset infra -o jsonpath='{.spec.inputs}' | grep -q 'tenant'; then
    echo "ERROR: infra was never activated" >&2
    exit 2
  fi
}
SH
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC008"* ]]
	[[ "$output" == *"setup-gate.sh"* ]]
	[[ "$output" == *"MATCH reports as no-match"* ]]
}

@test "VAC008 RED says WHY the status is a verdict, not merely that it is one" {
	# A finding that does not name the refusal makes the reader re-derive the
	# argument, and a rule people re-derive is a rule they mute.
	cat >"$fixture/gate.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
check() {
  kubectl api-resources -o name | grep -Eq '^networkpolicies$' || {
    echo 'UNVERIFIED: NetworkPolicy API unavailable' >&2
    return 1
  }
}
SH
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"the || / && block refuses at line"* ]]
}

@test "VAC008 RED on a bare pipeline under errexit" {
	# The earliest form of the bao-spire-proof defect: nothing branches on it,
	# so errexit makes the status the whole script's verdict.
	cat >"$fixture/proof.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
kubectl -n demo logs job/negative | grep -Fq 'denied as expected'
SH
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC008"* ]]
	[[ "$output" == *"errexit is set"* ]]
}

@test "VAC008 RED on a function's trailing pipeline, which returns its status" {
	cat >"$fixture/publishing.sh" <<'SH'
#!/usr/bin/env bash
set -o pipefail
remote_is_publishing() {
  remote_run "ss -ltn" | grep -q PUBLISHING
}
SH
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"last statement of the enclosing function"* ]]
}

@test "VAC008 RED in a Makefile, where pipefail comes from SHELL and not from set" {
	# A Makefile never says `set -o pipefail`. `SHELL = env bash -o pipefail`
	# puts every recipe under it, and a rule that only looks for the `set` form
	# reads the whole file as unaffected.
	cat >"$fixture/Makefile" <<'MK'
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

guard:
	@printf '%s' '$(ENV)' | grep -Eq '^demo-[1-9][0-9]*$$' || { \
		echo "ERROR: bad ENV"; \
		exit 2; \
	}
MK
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC008"* ]]
	[[ "$output" == *"Makefile"* ]]
}

@test "VAC008 CONTROL does not fire without pipefail" {
	# Without pipefail the pipeline reports grep's status, which is the answer
	# actually being asked for. There is no defect here at all.
	cat >"$fixture/nopf.sh" <<'SH'
#!/usr/bin/env bash
set -eu
gate() {
  kubectl get pods | grep -q Running || return 1
}
SH
	scan
	[ "$status" -eq 0 ]
}

@test "VAC008 CONTROL does not fire when the status only picks between two actions" {
	# THE control that decides whether this rule survives contact with the tree.
	# The bare shape occurs 77 times here under pipefail; 64 of them look like
	# this. An inversion reinstalls a tool that was already installed, or
	# rebuilds a cluster that already existed — wasteful, loud, self-correcting.
	# A rule that fires on all 77 is a rule somebody switches off in a week.
	cat >"$fixture/branchy.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
ensure_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "$name"; then
    echo "reusing $name"
  else
    kind create cluster --name "$name"
  fi
}
ensure_go() {
  if ! go version 2>/dev/null | grep -q "go${GO_VERSION}"; then
    install_go
  fi
}
SH
	scan
	[ "$status" -eq 0 ]
}

@test "VAC008 CONTROL does not fire on a pipeline quoted as data" {
	# `remote_run "... | grep -q ..."` is a command string executed by another
	# host's shell under its own options, and a sed replacement in a mutation
	# harness is the text being substituted. Neither is a pipeline of this file,
	# and reporting one names a line that contains no pipeline at all.
	cat >"$fixture/quoted.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
probe() {
  remote_run "ss -ltn 2>/dev/null | grep -q ':8080 ' && echo UP || echo DOWN" || return 1
}
del_gate() { mutate 's#^  printf "$lane" | grep -Eq "$PATTERN" && return 0$#  false#'; }
SH
	scan
	[ "$status" -eq 0 ]
}

@test "VAC008 CONTROL does not fire on the second bar of ||" {
	# `grep -Fq PAT file || grep -Fq PAT other` reads FILES. There is no
	# producer and no status to lose, and a naive `\| grep` flags it.
	cat >"$fixture/orbar.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
validate() {
  grep -Fq 'spire-server' "$controllers" || grep -Fq 'spire-agent' "$agent" || return 1
}
SH
	scan
	[ "$status" -eq 0 ]
}

@test "VAC008 RED on a real pipe that shares its line with a file-reading ||" {
	# The regression test for a clause that was deleted. An exclusion keyed on
	# `||` appearing ANYWHERE in the line skipped this whole statement, so a
	# genuine piped verdict with a file-reading fallback went unreported. The
	# detector's `[^|]` handles the second bar without swallowing the first.
	#
	# Found by deleting each clause of the rule in turn and asking which
	# deletions no test objected to. This one nothing objected to, because it
	# was doing no work that the detector was not already doing — and one thing
	# the detector was NOT doing, which was losing findings.
	cat >"$fixture/both.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
gate() {
  kubectl get pods | grep -q Running || grep -Fq 'fallback' "$cache" || return 1
}
SH
	scan
	[ "$status" -eq 1 ]
	[[ "$output" == *"VAC008"* ]]
	[[ "$output" == *"both.sh"* ]]
}

@test "VAC008 CONTROL does not fire on a grep that reads to EOF" {
	# The repo's own earlier fix (071b989f) was `grep -q` -> `grep >/dev/null`.
	# Without -q grep consumes the whole stream, so the producer never takes
	# SIGPIPE and the pipeline's status is the honest one. Flagging this would
	# flag the fix.
	cat >"$fixture/toeof.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
gate() {
  kubectl get pods | grep -F Running >/dev/null || return 1
  docker exec node ctr images ls -q | awk -v i="$img" '$1 == i { f = 1 } END { exit !f }' || return 1
}
SH
	scan
	[ "$status" -eq 0 ]
}

@test "VAC008 GREEN once the producer's output is captured first" {
	# The fix form. No pipe, so no early close, no SIGPIPE, and the producer's
	# status is preserved in the assignment where it can be handled on purpose.
	cat >"$fixture/fixed.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
verify_infra() {
  local inputs
  inputs="$(kubectl -n flux-system get resourceset infra -o jsonpath='{.spec.inputs}' 2>/dev/null || true)"
  if ! grep -q 'tenant' <<<"$inputs"; then
    echo "ERROR: infra was never activated" >&2
    exit 2
  fi
}
SH
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
