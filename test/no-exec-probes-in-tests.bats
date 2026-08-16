#!/usr/bin/env bats
#
# `kubectl exec` may not be used to probe from inside a container in a test
# file, unless the file is on the allowlist below with a stated reason.
#
# The defect this pins, quoted from the engineering note that catalogued it:
#
#   `[ "$status" -ne 0 ]` as an auth-rejection test. The container is
#   distroless; `kubectl exec ... wget` always failed with "executable not
#   found". It passed identically whether auth existed or not.
#
#   Four sibling tests failed visibly for that reason. This one PASSED -- and
#   it was the auth test. The images were correctly hardened; the tests were
#   never updated. The passing one was the dangerous one.
#
# Reproduced against the live cluster on 2026-08-16, both endpoints of the same
# distroless cardvault pod:
#
#   $ kubectl -n inf-signalloom exec pod/cardvault-79f88dc795-hcb89 -- \
#       wget -q -O- http://localhost:8080/api/v1/cards
#   OCI runtime exec failed: exec: "wget": executable file not found in $PATH
#   exit = 1                      <-- "auth rejected the request"
#
#   $ kubectl -n inf-signalloom exec pod/cardvault-79f88dc795-hcb89 -- \
#       wget -q -O- http://localhost:8080/healthz
#   OCI runtime exec failed: exec: "wget": executable file not found in $PATH
#   exit = 1                      <-- an endpoint with NO auth at all
#
# Identical. No assertion on that exit status can tell the two apart, so the
# security property was never under test. Hardening an image is supposed to be
# safe; here it silently disarmed the test that guarded the hardening.
#
# The rule is therefore about the SHAPE of the evidence, not about kubectl:
# a probe whose failure mode is indistinguishable from its success mode is not
# a test. Probing a network endpoint from OUTSIDE the container -- port-forward
# plus a real HTTP status code -- cannot degrade that way, because there is no
# in-container binary to go missing.
#
# Three verdicts are available for an occurrence:
#
#   converted  - it probed a network endpoint; it now port-forwards and asserts
#                a real status code. See d2-signalloom/test/supercred-demo.bats
#                `port_forward_wait` for the reference pattern.
#   probe pod  - it inspected a filesystem or process table; it now uses a
#                debug pod, or reads the fact from the Kubernetes API.
#   allowlisted- it cannot survive either move, or exec IS the thing under
#                test. It stays, and the reason is written down below.
#
# ── On the shape of this guard itself ────────────────────────────────────────
#
# Two failure modes were found while writing it, both of the kind this
# repository keeps hitting, and both are pinned by tests further down:
#
#   1. Scanning ABSOLUTE paths made the guard's scope depend on the checkout
#      directory. This branch is developed in a worktree at
#      .worktrees/osramp-demo/test/r1-ban-exec-probes/, so a `*/test/*.sh`
#      pattern matched every script in scripts/ -- 51 extra hits that do not
#      exist when the same commit is checked out at ~/src/cp/osramp-demo. A
#      guard that reports differently depending on where it was cloned is not
#      a guard. Paths are matched relative to the repo root.
#
#   2. Tightening the pattern to kill a false positive introduced a false
#      NEGATIVE: `kubectl -n fe-signalloom exec ...` stopped matching, because
#      the intermediate token was an unquoted bare word. That silently dropped
#      two live occurrences in a suite CI stage 7 runs. Hence the paired
#      positive/negative fixtures in the two "recognises"/"does not confuse"
#      tests: the pattern is exercised against known inputs on every run, so
#      it can never quietly stop matching the thing it exists to find.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
}

# The verb is assembled from a variable rather than written literally so that
# this file scores zero hits against its own pattern. Spelling it out would
# force this file onto its own allowlist, and a self-exemption is the one entry
# nobody would ever question.
exec_verb() { printf 'exec'; }

# `kubectl [tok]{0,6} <verb>` on a single line.
#
# The token class excludes ; | and & so the match cannot run across a command
# boundary -- that is what stopped `KUBECTL_BIN="$dir/kubectl" bash "$shim"
# exec ...` in test/supercred-image-visibility.bats from being reported as a
# kubectl exec. It is a shim invocation that merely mentions both words.
exec_probe_pattern() {
	printf 'kubectl([[:space:]]+[^[:space:];|&]+){0,6}[[:space:]]+\\b%s\\b' "$(exec_verb)"
}

# Match a single file, emitting `line:text`.
#
# Whole-line comments and the quoted description of an @test line are stripped
# first: a file that DISCUSSES the pattern is not a file that USES it. Three
# comments in supercred-demo.bats explain at length why exec cannot work
# against a distroless image, and two @test names in
# test/supercred-demo-stun.bats are literally "kubectl exec noise is kept out
# of the success evidence blocks". Flagging those would push people to delete
# the explanations, which are the most valuable text in either file.
#
# Only the description is removed from an @test line, not the whole line, so an
# invocation sharing that line is still caught.
scan_file() {
	sed -e 's/^[[:space:]]*#.*//' \
	    -e 's/^[[:space:]]*@test[[:space:]]*"[^"]*"/@test/' "$1" |
		grep -nE "$(exec_probe_pattern)" || true
}

# Every test file in the repo, as paths relative to repo_root: all *.bats
# anywhere, plus *.sh living inside a test/ directory.
#
# scripts/ is deliberately NOT in scope. scripts/supercred-demo.sh and friends
# exec into OpenBao and SPIRE as their actual job -- that is the product's
# behaviour, not a test probing it, and test/supercred-demo-stun.bats already
# tests that behaviour through a kubectl stub.
test_files() {
	cd "$repo_root" || return 1
	{
		find . -name .git -prune -o -name .claude -prune -o -name .worktrees -prune -o -name node_modules -prune -o -name '*.bats' -print
		find . -name .git -prune -o -name .claude -prune -o -name .worktrees -prune -o -name node_modules -prune -o -path './*/test/*.sh' -print
		find . -name .git -prune -o -name .claude -prune -o -name .worktrees -prune -o -path './test/*.sh' -print
	} 2>/dev/null | sed 's#^\./##' | sort -u
}

# `path:line:text` for every occurrence in the tree.
exec_probe_hits() {
	local f
	while read -r f; do
		[ -f "$repo_root/$f" ] || continue
		scan_file "$repo_root/$f" | while IFS= read -r hit; do
			printf '%s:%s\n' "$f" "$hit"
		done
	done < <(test_files)
}

# ── Allowlist ────────────────────────────────────────────────────────────────
#
# Format: path|count|reason
#
# The COUNT is load-bearing. Allowlisting a path outright would hand that file
# a blanket exemption, and the next exec probe added to it -- including one of
# exactly the shape this guard exists to ban -- would inherit the pass. Pinning
# the number means a new occurrence in an already-listed file is still a
# failure, and it also fails when an occurrence is removed without the entry
# being updated, so the numbers cannot drift into fiction.
#
# Every entry below was checked against the image it execs into. The question
# is never "is exec convenient here" but "can this probe's failure be told
# apart from the property failing".
allowlist() {
	cat <<-'ENTRIES'
	d2-osramp-apps/test/osramp.bats|9|4 are `nats pub` into a nats-box tooling pod and 5 are `psql` inside the postgres Pod, whose image is postgres:18 (ships psql and a shell; it is not and will not be distroless). Neither is defect-shaped: every assertion is on returned CONTENT (assert_line --partial "$TASK_ID", or [[ "$DB_RECORD_CHECK" == *...* ]]), never on the exec exit status, so a failed exec yields empty output and fails visibly. Converting the psql calls would swap the image's own client for a host psql that is not installed on this machine or on the CI VM, making a working check unrunnable. NOTE: the whole suite currently runs nowhere in CI and the osramp-apps stack is not deployed, so none of this could be exercised -- see the report accompanying this commit.
	test/vacuous-assertions.bats|3|FIXTURES, not probes. This is the vacuous-assertion lint's own falsification suite, and these three lines are deliberately-written examples of the exec-probe shape, fed to that lint to prove it reports them. They are string literals inside heredocs describing a defect; no kubectl runs. Two guards written in parallel by different agents collided here -- one guard's fixtures are the other's violations -- and neither could see it, because the collision only exists once both are in the same tree. Kept at count 3 rather than a bare path exemption for the reason this file's whole allowlist is counted: a path-only entry would hand the next real probe added to this file a free pass.
	d2-signalloom/test/supercred-demo.bats|1|`bao kv get` inside deployment/openbao. The openbao image ships a shell and the bao CLI, and the assertion is on the JSON payload ('"username": "cardvault-svc-account"'), not on the exit status. Reasoned through at length in the test's own comment, which contrasts it with the distroless cardvault/policy-engine probes in the same file that WERE converted to port-forward.
	d2-signalloom/test/supercred-demo-api.bats|1|Counts demo-script processes by reading /proc/[0-9]*/cmdline inside the runner pod. A pod's process table is not exposed by the Kubernetes API and is not reachable from a debug pod without shareProcessNamespace, so this check cannot survive either move. Its silent-degradation hole -- the `|| echo unavailable` fallback comparing equal to itself -- is fixed in the same commit by asserting the probe returned a number before comparing.
	d2-signalloom/test/test-1-runtime.bats|2|Asserts the pod's own EGRESS is blocked by NetworkPolicy, which is only observable from inside that pod's network namespace; a port-forward exercises ingress from the host and would test the opposite direction. Already correctly built: the first exec is an explicit positive control (`python -c 'import socket'` must succeed) so the egress assertion below it cannot pass on a broken exec. This is the shape the whole guard is arguing for.
	olly-replica/test/olly.bats|2|`rpk topic list` inside redpanda-0. rpk is the Redpanda admin CLI and ships in the redpanda image; the broker's topic list has no HTTP equivalent exposed by this deployment. Assertions are on topic names in the output, not on the exit status.
	ENTRIES
}

allowlist_paths() { allowlist | cut -d'|' -f1; }

# ── The guard ────────────────────────────────────────────────────────────────

@test "EXECBAN the scanner sees a non-empty universe of test files" {
	# A scanner that scans nothing passes vacuously, which is the defect class
	# this repository keeps hitting -- a Playwright spec matching no testMatch,
	# a bats suite no runner invokes, an EXCLUDED_BATS parse that returned
	# build output. The floor is well under the ~70 present so it does not
	# become a maintenance tax, but far above zero.
	local count
	count="$(test_files | wc -l)"
	echo "test files in scope: $count"
	[ "$count" -gt 40 ]
}

@test "EXECBAN the scanner still recognises an exec probe" {
	# The mechanism assertion, and the reason it exists: while writing this
	# guard, a tightened pattern silently stopped matching
	# `kubectl -n fe-signalloom exec deployment/fe-signalloom -- ...` because
	# the namespace was an unquoted bare word. Two live occurrences in a suite
	# CI stage 7 runs vanished from the report and the guard went green.
	#
	# Every spelling in the tree is exercised here against a synthetic file, so
	# the pattern is proven to work on inputs this test controls rather than
	# only on whatever the corpus happens to contain today.
	local v fixture
	v="$(exec_verb)"
	fixture="$BATS_TEST_TMPDIR/positive.bats"
	{
		printf 'kubectl %s $POD -- nats pub tasks.purl "$MESSAGE"\n' "$v"
		printf '  kubectl %s postgres --namespace backend -- psql task_archive\n' "$v"
		printf '  run kubectl -n "$NAMESPACE_BAO" %s deployment/openbao -- bao kv get\n' "$v"
		printf '  run kubectl -n fe-signalloom %s deployment/fe-signalloom -- python -c x\n' "$v"
		printf '  run kubectl -n "${NS}" %s redpanda-0 -c redpanda -- rpk topic list\n' "$v"
		printf '  local CMD=(kubectl %s $(get-pod-reference bar) -- nats pub tasks.input)\n' "$v"
		printf '  out="$(kubectl -n "$ns" %s -i svc/pg -- psql)"\n' "$v"
	} >"$fixture"

	local found expected=7
	found="$(scan_file "$fixture" | wc -l)"
	echo "matched $found of $expected known spellings"
	scan_file "$fixture"
	[ "$found" -eq "$expected" ]
}

@test "EXECBAN the scanner does not confuse discussion or lookalikes with use" {
	# The other half of the same proof. Over-matching is not harmless: it would
	# force the deletion of the comments explaining why exec cannot work
	# against a distroless image, which are the most useful text in the files
	# that carry them.
	local v fixture
	v="$(exec_verb)"
	fixture="$BATS_TEST_TMPDIR/negative.bats"
	{
		printf '# scripts/supercred-demo.sh seeds OpenBao via `kubectl %s deployment/openbao -- bao kv put`\n' "$v"
		printf '\t# so `kubectl %s ... wget` can never work against them.\n' "$v"
		printf '@test "kubectl %s noise is kept out of the success evidence blocks" {\n' "$v"
		printf '@test "kubectl %s noise is preserved on the failure paths" {\n' "$v"
		printf '  run env KUBECTL_BIN="$dir/kubectl" bash "$shim" %s somenode crictl\n' "$v"
		printf '  run env KUBECTL_BIN="$dir/kubectl" bash -c "bash '"'"'$shim'"'"' %s somenode"\n' "$v"
		printf '  kubectl get pods -A | grep nats && ./other %s thing\n' "$v"
		printf '  kubectl logs $(kubectl get pods -n frontend -o name) -c processor\n'
	} >"$fixture"

	local found
	found="$(scan_file "$fixture" | wc -l)"
	echo "false positives: $found"
	scan_file "$fixture"
	[ "$found" -eq 0 ]
}

@test "EXECBAN no test file outside the allowlist probes with kubectl exec" {
	local offenders="" hit path
	while IFS= read -r hit; do
		[ -n "$hit" ] || continue
		path="${hit%%:*}"
		grep -qxF "$path" <<<"$(allowlist_paths)" && continue
		offenders="${offenders}${hit}"$'\n'
	done < <(exec_probe_hits)

	if [ -n "$offenders" ]; then
		# Assembled, not spelled out, for the reason exec_verb() exists: this
		# line is code rather than a comment, so a literal here would make the
		# guard report itself. It did exactly that on first run, which is a
		# tidy demonstration that the scanner reads what is executed and not
		# what is merely discussed.
		echo "kubectl $(exec_verb) used as a probe in test file(s) with no allowlist entry:"
		echo "$offenders"
		echo "A probe that runs INSIDE the container fails identically whether the"
		echo "property holds or not the moment the image is hardened -- distroless"
		echo "images have no shell, no wget and no curl. Port-forward from outside"
		echo "and assert a real HTTP status code (see port_forward_wait in"
		echo "d2-signalloom/test/supercred-demo.bats), use a debug pod, or read the"
		echo "fact from the Kubernetes API."
		echo ""
		echo "If it genuinely cannot move, add it to allowlist() in this file with"
		echo "the count and a reason naming the image and what the assertion reads."
		false
	fi
}

@test "EXECBAN every allowlisted file still exists" {
	# A stale exemption is worse than none: it reads as "reviewed and accepted"
	# while describing nothing, and would silently pre-approve a file of that
	# name if one were reintroduced later.
	local stale="" path
	while read -r path; do
		[ -n "$path" ] || continue
		[ -f "$repo_root/$path" ] || stale="${stale}${path} "
	done < <(allowlist_paths)

	if [ -n "$stale" ]; then
		echo "allowlist names file(s) that do not exist: $stale"
		echo "Remove them so the allowlist keeps describing reality."
		false
	fi
}

@test "EXECBAN every allowlist entry states a reason" {
	# An exemption without a reason is an accident wearing a decision's
	# clothes. The length floor is deliberate: "legacy", "needed" and "TODO"
	# are not reasons, and a one-word entry is how an allowlist becomes a
	# rubber stamp.
	local bad="" line path reason
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		path="$(cut -d'|' -f1 <<<"$line")"
		reason="$(cut -d'|' -f3- <<<"$line")"
		[ "${#reason}" -ge 60 ] || bad="${bad}${path} "
	done < <(allowlist)

	if [ -n "$bad" ]; then
		echo "allowlist entries with a missing or too-thin reason: $bad"
		echo "Say which image is exec'd into, what the assertion actually reads,"
		echo "and why the check cannot be made from outside the container."
		false
	fi
}

@test "EXECBAN every allowlisted file has exactly its recorded number of occurrences" {
	# Without this, an allowlist entry is a blanket exemption and the next exec
	# probe added to that file inherits the pass -- including one of exactly
	# the shape this guard exists to ban.
	local drift="" line path expected actual
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		path="$(cut -d'|' -f1 <<<"$line")"
		expected="$(cut -d'|' -f2 <<<"$line")"
		[ -f "$repo_root/$path" ] || continue
		actual="$(scan_file "$repo_root/$path" | wc -l)"
		[ "$actual" -eq "$expected" ] || \
			drift="${drift}${path} (recorded ${expected}, found ${actual})"$'\n'
	done < <(allowlist)

	if [ -n "$drift" ]; then
		echo "allowlisted occurrence counts no longer match the files:"
		echo "$drift"
		echo "A higher count means a NEW exec probe was added to an already-"
		echo "exempt file: convert it, or raise the number and extend the reason."
		echo "A lower count means one was removed or converted: lower the number,"
		echo "so the allowlist keeps describing reality rather than folklore."
		false
	fi
}

@test "EXECBAN the allowlist is not vacuous" {
	# The scanner could break in a way that matches nothing -- a bad regex, an
	# empty file list, a sed that eats every line -- and every test above would
	# then pass while enforcing nothing at all. The allowlist records that this
	# tree HAS known occurrences, so finding none means the scanner is broken,
	# not that the tree is clean.
	#
	# If the last allowlisted occurrence is ever legitimately converted, this
	# test has to be updated by hand. That is intended: retiring the guard's
	# own evidence should be a deliberate act, not a silent one.
	local total recorded
	total="$(exec_probe_hits | wc -l)"
	recorded="$(allowlist | awk -F'|' '{s+=$2} END{print s+0}')"
	echo "occurrences found: $total, recorded in allowlist: $recorded"
	[ "$total" -gt 0 ]
	[ "$total" -eq "$recorded" ]
}
