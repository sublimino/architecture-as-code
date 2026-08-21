#!/usr/bin/env bats
#
# The REMOTE test surface: the lane exercised over the tailnet, from here.
#
# Named `terraform-*.bats` so `make gcp-tf-validate`'s glob registers it on the
# commit that lands it. A hand-maintained list is what once left 33 suites in
# this repo passing and unasked, and this suite in particular must not be
# forgettable: it is the only thing that tests the surface a human actually uses.
#
# ─── What this suite is FOR ────────────────────────────────────────────────
#
# `demo-up.sh test` asserts against the estate over 127.0.0.1 on the VM.
# `demo-up.sh ts-test` asserts the five things that only exist BETWEEN the
# operator and that estate: the tailnet node, a real TLS certificate for the
# MagicDNS name, Dex's issuer, a token minted across the wire, and an
# authenticated API call through the same nginx a browser uses.
#
# So the tests below are overwhelmingly about FAILURE. A remote suite that
# passes when the lane is healthy is easy; the whole value is that it goes red,
# specifically, when the lane is not serving — and never, ever skips. This repo
# has shipped the opposite twice: a bats suite that all-skipped locally and read
# as green, and four Playwright specs that matched no project and were skipped
# with exit 0 and no warning. Every assertion here is written against that.
#
# ─── Everything runs against stubs ─────────────────────────────────────────
#
# No tailnet, no network, no credentials. `tailscale`, `getent` and `curl` are
# all injected or on PATH, so the real control flow in demo-up.sh executes and
# the answers are the test's to choose.

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export REPO_ROOT
	export MAKEFILE="${REPO_ROOT}/Makefile"
	export DRIVER_SRC="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"
	export FIXTURES="${REPO_ROOT}/test/fixtures/gcp-tf-tailscale"
}

# Every target this suite owns, written once so a target added to the family
# cannot be added to half the assertions.
REMOTE_TARGETS="gcp-tf-ts-test gcp-tf-test-surfaces gcp-tf-test-both"

setup() {
	[ -f "${MAKEFILE}" ]
	[ -f "${DRIVER_SRC}" ]
	[ -x "${DRIVER_SRC}" ]
	[ -f "${FIXTURES}/stub-curl-remote" ]

	# ─── The mechanism must be PRESENT before its behaviour is asserted ────
	#
	# Without this, a driver that had lost the remote surface entirely would
	# reach every test below and fail them for the wrong reason — or worse,
	# pass the static ones. A correct test can run against a tree that does not
	# contain the thing under test; grep for it first.
	grep -q 'cmd_ts_test()' "${DRIVER_SRC}" || {
		echo "the driver has no cmd_ts_test — every assertion in this suite would be about nothing"
		return 1
	}
	grep -q 'write_surface_receipt' "${DRIVER_SRC}" || {
		echo "the driver files no surface receipt — the both-surfaces tests would be vacuous"
		return 1
	}

	ENV_KEY="demo-7"
	root="${BATS_TEST_TMPDIR}/repo"
	stubdir="${BATS_TEST_TMPDIR}/bin"
	ts_json="${BATS_TEST_TMPDIR}/ts-status.json"
	surfaces="${BATS_TEST_TMPDIR}/surfaces"
	driver="${root}/scripts/gcp-tf/demo-up.sh"

	TS_HOST="sl-${ENV_KEY}"
	TS_FQDN="${TS_HOST}.example-tailnet.ts.net"
	BASE="https://${TS_FQDN}"
	ISSUER="${BASE}/dex"

	mkdir -p "${stubdir}" "${root}/scripts/gcp-tf" "${root}/scripts/lib" "${root}/deploy/gcp" "${surfaces}"
	cp "${DRIVER_SRC}" "${driver}"
	chmod +x "${driver}"

	# ── The driver's library must resolve, or nothing below tests anything ────
	#
	# demo-up.sh sources scripts/lib/wait.sh via a path relative to its OWN
	# location. Copying the driver alone into a fixture tree gives it a layout
	# where that source fails, and it dies at line 118 before parsing a single
	# argument:
	#
	#   demo-up.sh: line 118: .../scripts/gcp-tf/../lib/wait.sh: No such file or directory
	#
	# Every one of the 30 REMOTE/SURFACES/TIMING tests below then failed with a
	# non-zero status and empty output — which reads as thirty independent
	# behavioural failures and is one missing file. They were red for this
	# reason before the AFM work landed and were briefly attributed to it;
	# the failure set is byte-identical either side of that merge.
	#
	# Copied rather than symlinked so the fixture stays a self-contained tree,
	# and copied as a DIRECTORY so a library gaining a second file does not
	# silently reintroduce this. Commit 3344670 reached the same conclusion for
	# the mutated-driver suites — "run mutated drivers in a layout where their
	# library resolves" — and this is that fix aimed at this suite.
	cp -a "${REPO_ROOT}/scripts/lib/." "${root}/scripts/lib/"

	# Presence before behaviour. If the library ever moves, this says so here
	# rather than as thirty assertion failures that name the wrong subject.
	[ -f "${root}/scripts/lib/wait.sh" ] || {
		echo "fixture is missing scripts/lib/wait.sh — the driver cannot source its library"
		return 1
	}

	for s in tailscale getent; do
		cp "${FIXTURES}/stub-${s}" "${stubdir}/${s}"
		chmod +x "${stubdir}/${s}"
	done
	cp "${FIXTURES}/stub-curl-remote" "${stubdir}/curl-remote"
	chmod +x "${stubdir}/curl-remote"

	write_ts_status "${TS_HOST}" true

	export PATH="${stubdir}:${PATH}"
	export STUB_TS_STATUS_JSON="${ts_json}"
	export STUB_RESOLVABLE="${TS_FQDN}"

	export GCP_TF_DEMO_REPO_ROOT="${root}"
	export GCP_TF_DEMO_ENV="${ENV_KEY}"
	export GCP_TF_HANDOFF_DIR="${root}/deploy/gcp"
	export GCP_TF_DEMO_SURFACE_DIR="${surfaces}"
	export GCP_TF_DEMO_CURL="${stubdir}/curl-remote"

	# Healthy by default. Each test states only the thing it is about.
	export STUB_CURL_OIDC_ISSUER="${ISSUER}"
	export STUB_CURL_TOKEN_ISS="${ISSUER}"
}

write_ts_status() { # write_ts_status <hostname> <online true|false>
	local host="$1" online="$2"
	jq -n --arg h "$host" --arg d "${host}.example-tailnet.ts.net." --argjson on "$online" \
		'{Self: {HostName: "operator-laptop", DNSName: "operator-laptop.example-tailnet.ts.net.",
		         TailscaleIPs: ["100.64.0.1"], Online: true},
		  MagicDNSSuffix: "example-tailnet.ts.net",
		  Peer: {"nodekey:aaa": {HostName: $h, DNSName: $d,
		                         TailscaleIPs: ["100.64.0.9"], Online: $on}}}' \
		>"${ts_json}"
}

write_ts_status_without_node() {
	jq -n '{Self: {HostName: "operator-laptop", DNSName: "operator-laptop.example-tailnet.ts.net.",
	               TailscaleIPs: ["100.64.0.1"], Online: true},
	        MagicDNSSuffix: "example-tailnet.ts.net", Peer: {}}' >"${ts_json}"
}

# write_receipt <surface> <outcome> [age-seconds]
write_receipt() {
	local surface="$1" outcome="$2" age="${3:-10}"
	jq -n --arg s "$surface" --arg e "${ENV_KEY}" --arg o "$outcome" \
		--argjson ep "$(($(date +%s) - age))" \
		'{schema: "signalloom.surface.receipt/v1", surface: $s, env: $e, outcome: $o,
		  commit: "abc1234", branch: "test", detail: ("synthetic " + $s),
		  written_at: "2026-08-20T00:00:00+00:00", written_epoch: $ep,
		  checks_total: 1, checks_failed: 0, checks: []}' \
		>"${surfaces}/${ENV_KEY}.${surface}.json"
}

run_driver() { run "${driver}" "$@"; }
run_make() { run make -C "${REPO_ROOT}" "$@"; }

# Apply a sed expression to the driver copy under test, and PROVE it applied.
#
# A sed expression that matches nothing exits 0 and changes nothing, so the
# mutation test that follows would run against correct code and pass — a
# mutation proof proving the opposite of what it claims. This repo has shipped
# exactly that shape.
mutate() {
	local before after
	before="$(md5sum <"${driver}")"
	sed -i "$1" "${driver}"
	after="$(md5sum <"${driver}")"
	[ "$before" != "$after" ] || {
		echo "the mutation '$1' matched nothing — the test that follows would be vacuous"
		return 1
	}
}

# ─── Static properties ──────────────────────────────────────────────────────

@test "REMOTE the driver is still shellcheck clean with the remote surface in it" {
	command -v shellcheck >/dev/null || skip "shellcheck not installed"
	run shellcheck "${DRIVER_SRC}"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "REMOTE the driver dispatches both new subcommands" {
	run grep -cE '^  (ts-test|test-surfaces)\)' "${DRIVER_SRC}"
	[ "$status" -eq 0 ]
	[ "$output" = "2" ]
}

@test "REMOTE the remote surface hardcodes no tailnet, URL or node name" {
	# The URL must come from `tailscale status --json`, never from this file. A
	# literal tailnet suffix here would promise a URL under a tailnet the
	# operator may not be on, and would silently outlive a tailnet rename.
	#
	# COMMENTS ARE STRIPPED FIRST, and that is not a loosening. The first
	# version of this test grepped the raw file and went red on a worked
	# example inside a pre-existing comment block — a guard firing on the prose
	# that documents the rule rather than on any code that breaks it. This repo
	# has shipped that shape more than once: a forbidden-literal grep matching
	# the file that holds the pattern reads exactly like a real leak. What is
	# being asserted is that no EXECUTABLE line carries a tailnet literal.
	run bash -c "sed 's/[[:space:]]*#.*$//' '${DRIVER_SRC}' | grep -nE 'taild4da3|[.]ts[.]net|https://sl-'"
	[ "$status" -ne 0 ]

	# ... and the guard is proven able to fire, so a future refactor that broke
	# the comment-stripping into a no-op cannot leave it silently passing.
	run bash -c "printf 'url=https://sl-demo-1.taild4da3.ts.net\\n' | sed 's/[[:space:]]*#.*\$//' | grep -nE 'taild4da3|[.]ts[.]net|https://sl-'"
	[ "$status" -eq 0 ]
}

@test "REMOTE the receipt directory is gitignored, so a receipt cannot block a deploy" {
	# A REGRESSION TEST for a defect this change actually shipped and
	# test/terraform-demo-driver.bats caught.
	#
	# demo-up.sh REFUSES to deliver from a dirty working tree. The first version
	# of this work wrote receipts into an untracked demo-surfaces/ at the repo
	# root, so filing one made the tree dirty and the very next `demo-up.sh up`
	# refused — a test surface that broke the deploy path by observing it.
	#
	# Asserted against the real repository, not a fixture, because the fixture's
	# .gitignore is a copy and a copy can be right while the original is wrong.
	run git -C "${REPO_ROOT}" check-ignore -q demo-surfaces/
	[ "$status" -eq 0 ] || {
		echo "demo-surfaces/ is not gitignored — filing a receipt will dirty the tree and block the next delivery"
		return 1
	}

	# Paired positive, so a blanket ignore that swallowed the whole repo could
	# not satisfy the check above.
	run git -C "${REPO_ROOT}" check-ignore -q Makefile
	[ "$status" -ne 0 ]
}

@test "REMOTE the surface binds no local port, so lanes cannot clash on one" {
	# Every request is outbound. A fixed local port would make two lanes
	# collide the moment they ran at once, which is the specific concurrency
	# hazard this surface was required to avoid.
	run grep -nE 'ts_test|cmd_ts_test' "${DRIVER_SRC}"
	[ "$status" -eq 0 ]
	run bash -c "sed -n '/^cmd_ts_test()/,/^}/p' '${DRIVER_SRC}' | grep -nE 'local-host-port|--bind|listen|nc -l'"
	[ "$status" -ne 0 ]
}

@test "REMOTE every receipt path carries the environment key" {
	# Four lanes, two surfaces, eight files, no collisions. A fixed filename
	# here would make concurrent lanes overwrite each other's evidence.
	run bash -c "grep -nE 'SURFACE_DIR}/' '${DRIVER_SRC}' | grep -v 'ENV_KEY'"
	[ "$status" -ne 0 ]
}

@test "REMOTE no check can only ever pass" {
	# The structural anti-vacuity property, and it replaced a grep for the word
	# `skip` that was decoration twice over: bash has no `skip` construct, so
	# the pattern could only ever match prose — and it did, matching a printf
	# that says the surface does not skip.
	#
	# What actually matters is that every check has BOTH outcomes wired. A
	# check written with a pass path and no fail path is a check that cannot
	# fail, which is this repo's most-repeated defect. There must therefore be
	# at least as many `ts_check fail` call sites as `ts_check ok` ones.
	local ok fail
	ok="$(grep -c 'ts_check ok' "${DRIVER_SRC}")"
	fail="$(grep -c 'ts_check fail' "${DRIVER_SRC}")"
	[ "$ok" -gt 0 ]
	[ "$fail" -ge "$ok" ] || {
		echo "${ok} pass paths but only ${fail} fail paths — some check cannot go red"
		return 1
	}
}

# ─── The Make contract ──────────────────────────────────────────────────────

@test "REMOTE every remote target exists as a real make target" {
	for t in ${REMOTE_TARGETS}; do
		run_make -n "$t" ENV=demo-1
		[ "$status" -ne 2 ] || {
			echo "no such target: $t"
			return 1
		}
	done
}

@test "REMOTE every remote target is declared .PHONY" {
	for t in ${REMOTE_TARGETS}; do
		run grep -qx ".PHONY: ${t}" "${MAKEFILE}"
		[ "$status" -eq 0 ] || {
			echo "${t} is not .PHONY"
			return 1
		}
	done
}

@test "REMOTE every remote target appears in make help" {
	run_make help
	[ "$status" -eq 0 ]
	for t in ${REMOTE_TARGETS}; do
		[[ "$output" == *"$t"* ]] || {
			echo "${t} is missing from help"
			return 1
		}
	done
}

@test "REMOTE every remote target refuses to run without ENV and says so" {
	for t in ${REMOTE_TARGETS}; do
		run make -C "${REPO_ROOT}" "$t"
		[ "$status" -ne 0 ]
		[[ "$output" == *"ENV is required"* ]]
	done
}

@test "REMOTE every remote target rejects a production-shaped key" {
	for t in ${REMOTE_TARGETS}; do
		run make -C "${REPO_ROOT}" "$t" ENV=prod-1
		[ "$status" -ne 0 ]
		[[ "$output" == *"not a valid environment key"* ]]
	done
}

@test "REMOTE ts-test does NOT require impersonation, unlike its siblings" {
	# The deliberate difference in the family, and it is load-bearing rather
	# than an oversight: this surface makes no gcloud call, and requiring a
	# credential the real user journey does not use would mean the journey
	# could only be tested by someone who is not living it.
	run_make -n gcp-tf-ts-test ENV=demo-1
	[ "$status" -eq 0 ]
	[[ "$output" != *"impersonat"* ]]
	# The sibling that DOES need cloud access still guards it, so this test
	# cannot pass by the guard having been deleted everywhere.
	run bash -c "grep -A3 '^gcp-tf-demo-test:' '${MAKEFILE}'"
	[[ "$output" == *"impersonation"* ]]
}

# ─── The remote surface: it goes red, and it goes red SPECIFICALLY ──────────

@test "REMOTE a healthy lane passes every check and files a receipt" {
	run_driver ts-test
	[ "$status" -eq 0 ]
	[[ "$output" == *"REMOTE PASS"* ]]
	[ -f "${surfaces}/${ENV_KEY}.tailnet.json" ]
	run jq -r '.outcome' "${surfaces}/${ENV_KEY}.tailnet.json"
	[ "$output" = "PASS" ]
	# Six checks or more, and the count is asserted rather than assumed: a
	# receipt saying PASS over zero checks is the failure this whole file is
	# written against.
	run jq -r '.checks_total' "${surfaces}/${ENV_KEY}.tailnet.json"
	[ "$output" -ge 6 ]
}

@test "REMOTE a lane whose node is absent FAILS and is not reported as a skip" {
	write_ts_status_without_node
	run_driver ts-test
	[ "$status" -ne 0 ]
	[[ "$output" == *"NOT REACHABLE"* ]]
	[[ "$output" == *"not a reason to skip"* ]]
	[[ "$output" != *"REMOTE PASS"* ]]
}

@test "REMOTE an offline node FAILS distinctly from an absent one" {
	write_ts_status "${TS_HOST}" false
	run_driver ts-test
	[ "$status" -ne 0 ]
	[[ "$output" == *"OFFLINE"* ]]
}

@test "REMOTE a node that is up but NOT SERVING fails, and says exactly that" {
	# THE ci-lane case, and the one the brief called out: connection refused on
	# :443 because `tailscale serve` was never configured. A generic "request
	# failed" here sends an operator looking at the cluster.
	export STUB_CURL_RC=7
	run_driver ts-test
	[ "$status" -eq 1 ]
	[[ "$output" == *"NOT SERVING"* ]]
	[[ "$output" == *"tailscale serve"* ]]
	[[ "$output" == *"make gcp-tf-ts-up ENV=${ENV_KEY}"* ]]
	[[ "$output" == *"REMOTE FAIL"* ]]
}

@test "REMOTE a TLS failure is named as a certificate problem, not a dead lane" {
	export STUB_CURL_RC=60
	run_driver ts-test
	[ "$status" -eq 1 ]
	[[ "$output" == *"certificate verification FAILED"* ]]
	[[ "$output" == *"HTTPS Certificates"* ]]
}

@test "REMOTE a 502 at the health path is distinguished from a dead node" {
	export STUB_CURL_READYZ_CODE=502
	run_driver ts-test
	[ "$status" -eq 1 ]
	[[ "$output" == *"502"* ]]
	[[ "$output" == *"VM-side forward"* ]]
}

@test "REMOTE a Dex issuing for ANOTHER origin fails, and names the bouncing login" {
	# The assertion the on-VM suite structurally cannot make. Everything else
	# on the page is green in this state: nginx answers, Dex answers, the
	# certificate verifies. Only the login is broken, and only from here.
	export STUB_CURL_OIDC_ISSUER="http://localhost:8080/dex"
	run_driver ts-test
	[ "$status" -eq 1 ]
	[[ "$output" == *"LOGIN WILL BOUNCE"* ]]
	[[ "$output" == *"http://localhost:8080/dex"* ]]
}

@test "REMOTE a token issued by another origin fails even when discovery is right" {
	# Discovery and the minted token are separate assertions on purpose: a Dex
	# that advertises one issuer and stamps another is a real misconfiguration,
	# and asserting only the discovery document would miss it.
	export STUB_CURL_TOKEN_ISS="https://somewhere-else.example/dex"
	run_driver ts-test
	[ "$status" -eq 1 ]
	[[ "$output" == *"somewhere-else.example"* ]]
}

@test "REMOTE a 200 with no id_token is a failure, not a pass" {
	export STUB_CURL_TOKEN_NO_ID=1
	run_driver ts-test
	[ "$status" -eq 1 ]
	[[ "$output" == *"no id_token"* ]]
}

@test "REMOTE an API that answers 200 to an ANONYMOUS caller fails" {
	# The check that stops the suite from certifying an open API. A run that
	# only ever sent the bearer would call this healthy.
	export STUB_CURL_API_ANON_CODE=200
	run_driver ts-test
	[ "$status" -eq 1 ]
	[[ "$output" == *"with no credentials"* ]]
}

@test "REMOTE an API that 502s to an AUTHENTICATED caller fails" {
	export STUB_CURL_API_AUTH_CODE=502
	run_driver ts-test
	[ "$status" -eq 1 ]
	[[ "$output" == *"no live backend"* ]]
}

@test "REMOTE an unaskable check is recorded as failed, never as skipped" {
	# When no token could be minted, the authenticated call cannot be made. The
	# only honest answer is a failure: a question not asked is not a question
	# answered, and silently dropping it would shrink the denominator until the
	# suite passed by having measured less.
	export STUB_CURL_TOKEN_CODE=503
	run_driver ts-test
	[ "$status" -eq 1 ]
	[[ "$output" == *"could not be asked"* ]]
	[[ "$output" == *"not a question answered"* ]]

	# ─── Asserting the MESSAGE is not asserting the OUTCOME ───────────────
	#
	# The first version of this test stopped at the two string matches above,
	# and test/tailnet-remote-mutation-proof.sh found the hole: flipping that
	# call site from `ts_check fail` to `ts_check ok` left both strings intact
	# and the exit status non-zero anyway (the token check itself still fails),
	# so the suite stayed green while the surface had quietly stopped counting
	# an unanswered question as a failure. That is the denominator-shrinking
	# defect this repo keeps meeting: a suite that passes by measuring less.
	#
	# So the RECEIPT is read, and the specific check's recorded status is what
	# is asserted.
	run jq -r '.checks[] | select(.name == "API answers an authenticated caller") | .status' \
		"${surfaces}/${ENV_KEY}.tailnet.json"
	[ "$status" -eq 0 ]
	[ "$output" = "fail" ]
}

@test "REMOTE ts-test runs with no hand-off and no credentials at all" {
	# The property that makes this the user's journey rather than an operator's.
	# There is no handoff file in the fixture tree and no operator SA anywhere.
	[ ! -f "${root}/deploy/gcp/${ENV_KEY}.handoff.json" ]
	run_driver ts-test
	[ "$status" -eq 0 ]
	[[ "$output" == *"deriving the node name"* ]]
}

# ─── Fence headroom, so a slowing lane is visible before it fails ──────────

@test "TIMING every check reports its elapsed time against its fence" {
	# The instrumentation hole this closes is scripts/ci/vm-pipeline.sh's: it
	# announces a stage and its timeout and never prints what the stage took,
	# so the outer fences are unmeasured and nobody can state the headroom.
	run_driver ts-test
	[ "$status" -eq 0 ]
	# Every check line carries a [Ns/Ns N%] budget stamp.
	local stamped
	stamped="$(printf '%s\n' "$output" | grep -cE '^  PASS .*\[[0-9]+\.[0-9]{3}s/[0-9]+s [0-9]+%\]')"
	[ "$stamped" -ge 6 ] || {
		echo "only ${stamped} check lines carry a budget stamp"
		return 1
	}
	[[ "$output" == *"TIMING:"* ]]
	[[ "$output" == *"of a 20s fence"* ]]
}

@test "TIMING the receipt records per-check elapsed and the fence" {
	# On disk, not just on screen — a number that scrolls past cannot be
	# compared against next week's run. This is what makes "the lane got slower
	# after the 16-to-8 vCPU resize" a statement anyone can check.
	run_driver ts-test
	[ "$status" -eq 0 ]

	run jq -r '.fence_seconds' "${surfaces}/${ENV_KEY}.tailnet.json"
	[ "$output" = "20" ]

	# Every check row carries its own budget accounting.
	run jq -r '[.checks[] | select(has("elapsed_ms") and has("budget_used_percent"))] | length' \
		"${surfaces}/${ENV_KEY}.tailnet.json"
	[ "$output" -ge 6 ]

	# ─── PRESENCE IS NOT CORRECTNESS ──────────────────────────────────────
	#
	# The check above only proves the KEYS exist, and
	# test/tailnet-remote-mutation-proof.sh found the hole: hardcoding the
	# values to 0 left every key in place and the test stayed green, so the
	# receipt would have recorded a perfect run of instantaneous checks
	# forever. A timing field that is always zero is worse than no field —
	# it looks like evidence.
	#
	# Summed rather than asserted per row, because a check that does no I/O
	# genuinely can complete inside a millisecond and round to 0. The run as
	# a whole cannot.
	run jq -r '[.checks[].elapsed_ms] | add' "${surfaces}/${ENV_KEY}.tailnet.json"
	[ "$output" -gt 0 ] || {
		echo "every check recorded 0ms — the timing is present but measuring nothing"
		return 1
	}

	# The slowest check is named, so cluster-debug-style ranking needs no parsing.
	run jq -r '.slowest_check' "${surfaces}/${ENV_KEY}.tailnet.json"
	[ -n "$output" ]
	[ "$output" != "null" ]
}

@test "TIMING a check near its fence WARNS and still passes" {
	# The threshold mirrors scripts/lib/wait.sh's 60% deliberately. It must warn
	# and NOT fail: a slow check that answered correctly is a latency signal,
	# and failing on it would turn that into a fabricated outage.
	export GCP_TF_DEMO_TS_TEST_WARN_PERCENT=0
	run_driver ts-test
	[ "$status" -eq 0 ]
	[[ "$output" == *"of its 20s budget"* ]]
	[[ "$output" == *"time out first if the lane slows down"* ]]
	[[ "$output" == *"REMOTE PASS"* ]]
}

@test "TIMING the warn threshold is not fired by a fast healthy run" {
	# The paired negative. Without it the test above would pass just as happily
	# against a driver that warned unconditionally, and a warning that always
	# fires is one nobody reads.
	run_driver ts-test
	[ "$status" -eq 0 ]
	[[ "$output" != *"of its 20s budget"* ]]
}

@test "TIMING a failing run still reports how long it took" {
	# A run that failed slowly and one that failed instantly are different
	# diagnoses — degraded versus absent — so the timing line is printed on
	# FAIL too, not only on the happy path.
	export STUB_CURL_RC=7
	run_driver ts-test
	[ "$status" -eq 1 ]
	[[ "$output" == *"TIMING:"* ]]
}

# ─── The both-surfaces property ─────────────────────────────────────────────

@test "SURFACES both present and passing is the only way to pass" {
	write_receipt on-vm PASS
	write_receipt tailnet PASS
	run_driver test-surfaces
	[ "$status" -eq 0 ]
	[[ "$output" == *"BOTH SURFACES PASSED"* ]]
}

@test "SURFACES a run that exercised only the tailnet is NOT a pass" {
	write_receipt tailnet PASS
	run_driver test-surfaces
	[ "$status" -ne 0 ]
	[[ "$output" == *"MISSING"* ]]
	[[ "$output" == *"on-vm"* ]]
	[[ "$output" == *"NOT PROVEN"* ]]
}

@test "SURFACES a run that exercised only the VM is NOT a pass" {
	write_receipt on-vm PASS
	run_driver test-surfaces
	[ "$status" -ne 0 ]
	[[ "$output" == *"MISSING"* ]]
	[[ "$output" == *"NOT PROVEN"* ]]
}

@test "SURFACES neither surface having run is NOT a pass" {
	run_driver test-surfaces
	[ "$status" -ne 0 ]
	[[ "$output" == *"NOT PROVEN"* ]]
}

@test "SURFACES a failing surface is not laundered by a passing sibling" {
	write_receipt on-vm PASS
	write_receipt tailnet FAIL
	run_driver test-surfaces
	[ "$status" -ne 0 ]
	[[ "$output" == *"NOT PROVEN"* ]]
}

@test "SURFACES a receipt older than the age limit does not vouch for the lane" {
	write_receipt on-vm PASS 999999
	write_receipt tailnet PASS
	run_driver test-surfaces
	[ "$status" -ne 0 ]
	[[ "$output" == *"STALE"* ]]
}

@test "SURFACES a receipt naming another environment is rejected, not counted" {
	write_receipt on-vm PASS
	write_receipt tailnet PASS
	jq '.env = "demo-99"' "${surfaces}/${ENV_KEY}.on-vm.json" >"${surfaces}/tmp" &&
		mv "${surfaces}/tmp" "${surfaces}/${ENV_KEY}.on-vm.json"
	run_driver test-surfaces
	[ "$status" -ne 0 ]
	[[ "$output" == *"demo-99"* ]]
}

@test "SURFACES the on-VM lane files a receipt, so the verdict has both halves" {
	# The seam. Without this the tailnet half could be perfect and
	# test-surfaces would report MISSING on-vm forever — a verdict that can
	# never pass is as useless as one that always does.
	run bash -c "sed -n '/^run_lane()/,/^}/p' '${DRIVER_SRC}' | grep -c 'write_surface_receipt on-vm'"
	[ "$status" -eq 0 ]
	[ "$output" = "1" ]
}

# ─── Mutations: every guard above is proven able to go red ──────────────────

@test "REMOTE MUTATION zero-check guard: removing it lets an empty run pass" {
	# Delete every recorded check and the run has measured nothing. Without the
	# TS_TEST_TOTAL guard that is a clean exit 0 and a receipt saying PASS,
	# which is the precise shape that has twice reported green in this repo
	# while measuring nothing.
	mutate 's/^  if \[ "\$TS_TEST_TOTAL" -eq 0 \]; then/  if false; then/'
	mutate 's/^ts_check() {/ts_check() { return 0;/'
	run "${driver}" ts-test
	[ "$status" -eq 0 ]
	run jq -r '.checks_total' "${surfaces}/${ENV_KEY}.tailnet.json"
	[ "$output" = "0" ]
	# ... and that is exactly what the real guard refuses. Same mutation, guard
	# restored: the run must now fail.
	setup
	mutate 's/^ts_check() {/ts_check() { return 0;/'
	run "${driver}" ts-test
	[ "$status" -ne 0 ]
	[[ "$output" == *"ZERO checks"* ]]
}

@test "REMOTE MUTATION serve-gate: accepting any status hides a non-serving lane" {
	mutate 's/elif \[ "\$code" = "200" \]; then/elif true; then/'
	export STUB_CURL_READYZ_CODE=502
	run "${driver}" ts-test
	[ "$status" -eq 0 ]
}

@test "REMOTE MUTATION issuer-check: removing it lets a bouncing login through" {
	mutate 's/if \[ "\$got_issuer" = "\$want_issuer" \]; then/if true; then/'
	export STUB_CURL_OIDC_ISSUER="http://localhost:8080/dex"
	run "${driver}" ts-test
	[ "$status" -eq 0 ]
}

@test "REMOTE MUTATION anon-check: removing it certifies an OPEN api as healthy" {
	mutate 's/elif \[ "\$anon" = "401" \] || \[ "\$anon" = "403" \]; then/elif true; then/'
	export STUB_CURL_API_ANON_CODE=200
	run "${driver}" ts-test
	[ "$status" -eq 0 ]
}

@test "SURFACES MUTATION missing-receipt: not counting it makes one surface enough" {
	write_receipt tailnet PASS
	mutate 's/^      missing=\$((missing + 1))/      :/'
	run "${driver}" test-surfaces
	[ "$status" -eq 0 ]
	[[ "$output" == *"BOTH SURFACES PASSED"* ]]
}
