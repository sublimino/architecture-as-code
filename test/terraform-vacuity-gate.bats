#!/usr/bin/env bats
#
# The vacuity scanner, run by the OFFLINE gate.
#
# ─── Why this file exists, and why the name starts with terraform- ──────────
#
# scripts/check-vacuous-assertions.sh is the one thing in this repository that
# can detect a test incapable of failing. Before this suite landed it was
# invoked in exactly two places, both of which need a VM:
#
#   scripts/ci/vm-pipeline.sh:759      cd ${WORK_DIR} && ./scripts/check-vacuous-assertions.sh
#   scripts/gcp-tf/demo-pipeline.sh:682  the same call
#
# `make gcp-tf-validate` did not run it, and neither did anything else a
# developer runs before merging. test/vacuous-assertions.bats — which drives the
# scanner against fixtures and proves each rule can go red — is not matched by
# the gate's `$(wildcard test/terraform-*.bats)` either, so it was equally
# absent from the gate.
#
# The consequence was measured, not theorised. Five vacuous assertions were
# merged on 2026-08-20 through suites that were green, and commit cad3f774
# recorded it: "A gate that counts passing tests cannot detect a test that is
# incapable of failing." The mechanism behind that sentence is simply that the
# gate never ran the detector. Re-introducing the same defect on 2026-08-20 --
# stripping five status assertions back out of
# test/terraform-tailscale-access.bats -- left every test/terraform-*.bats suite
# green in 238s while the scanner reported four findings by name.
#
# The `terraform-` prefix IS the registration. `make gcp-tf-validate` runs
# `$(wildcard test/terraform-*.bats)`, so a file named this way is in the
# offline gate the moment it lands and cannot be dropped from a hand-written
# list. The prefix in this repo already means "in the offline gate" rather than
# "about Terraform" — test/terraform-toolchain-pins.bats covers
# scripts/ci/install-ci-tools.sh, test/terraform-demo-driver.bats covers a shell
# driver. This is that same convention, not a new one.
#
# What this file deliberately does NOT do is re-test the scanner's rules. That
# is test/vacuous-assertions.bats's job and it does it against fixtures. This
# suite asks one question the gate could not previously ask: does the REAL tree
# pass the REAL scanner?

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export REPO_ROOT
	export SCANNER="${REPO_ROOT}/scripts/check-vacuous-assertions.sh"
}

@test "VACGATE the scanner is present and executable" {
	# Presence before behaviour. A missing scanner makes every assertion below
	# fail for a reason that has nothing to do with the tree's assertions, and
	# this repo has shipped a suite that drove a script nobody had written.
	[ -f "${SCANNER}" ] || {
		echo "scripts/check-vacuous-assertions.sh is gone; the offline gate has lost"
		echo "its only detector for tests that cannot fail."
		return 1
	}
	[ -x "${SCANNER}" ]
}

@test "VACGATE the scanner still distinguishes a violation from a clean tree" {
	# Run the REAL scanner over a throwaway tree holding one deliberate VAC006,
	# then over a clean one. Without this pair, the repository-wide assertion
	# below is satisfied just as well by a scanner that has stopped detecting
	# anything — which is the exact failure mode it exists to catch, turned on
	# itself.
	#
	# The fixture is written OUTSIDE the repository. A violation planted inside
	# test/ would be found by the repository-wide run in the next test and by
	# every future run of the scanner in CI.
	local dirty="${BATS_TEST_TMPDIR}/dirty/test"
	local clean="${BATS_TEST_TMPDIR}/clean/test"
	mkdir -p "${dirty}" "${clean}"
	: >"${BATS_TEST_TMPDIR}/empty.allow"

	# The `@test` token is assembled with printf rather than written literally,
	# and that is not style. bats preprocesses THIS file before executing it and
	# rewrites every line that looks like `@test "..." {` into its internal
	# `bats_test_function … ; test_x() {` form — including inside a quoted
	# heredoc. Writing the fixture the obvious way lands bats internals on disk,
	# the scanner finds no @test in them at all, and the positive control below
	# reports a clean scan over a file that is nothing but a violation.
	#
	# Rediscovered here on 2026-08-20 by insisting the control actually fire; it
	# is the same trap recorded at the top of test/vacuous-assertions.bats, where
	# it had silently turned four RED tests green. Two suites have now hit it, so
	# treat a literal @test inside a heredoc as unusable rather than unlucky.
	{
		printf '#!/usr/bin/env bats\n'
		printf '@%s "%s" {\n' test "a run whose status nothing examines"
		printf '\trun true\n'
		printf '\t[ -f /dev/null ]\n'
		printf '}\n'
	} >"${dirty}/probe.bats"
	{
		printf '#!/usr/bin/env bats\n'
		printf '@%s "%s" {\n' test "a run whose status is examined"
		printf '\trun true\n'
		printf '\t[ "$%s" -eq 0 ]\n' status
		printf '}\n'
	} >"${clean}/probe.bats"

	# The fixture must contain the token the scanner keys on. If bats ever starts
	# rewriting the printf form too, this says so instead of reporting a clean
	# scan over a mangled file.
	grep -q '^@test ' "${dirty}/probe.bats" || {
		echo "the fixture on disk has no @test line — bats rewrote it, and the"
		echo "control below would pass over a file the scanner cannot parse:"
		cat "${dirty}/probe.bats"
		return 1
	}

	run env VACUOUS_REPO_ROOT="${BATS_TEST_TMPDIR}/dirty" \
		VACUOUS_ALLOWLIST="${BATS_TEST_TMPDIR}/empty.allow" \
		"${SCANNER}" "${dirty}"
	[ "$status" -eq 1 ] || {
		echo "the scanner did not report a planted VAC006 (exit ${status})."
		echo "Everything this suite asserts about the real tree would be vacuous."
		echo "${output}"
		return 1
	}
	[[ "${output}" == *"VAC006"* ]] || {
		echo "the scanner failed, but not with VAC006 — it may be failing for an"
		echo "unrelated reason, which would make the exit code above meaningless:"
		echo "${output}"
		return 1
	}

	run env VACUOUS_REPO_ROOT="${BATS_TEST_TMPDIR}/clean" \
		VACUOUS_ALLOWLIST="${BATS_TEST_TMPDIR}/empty.allow" \
		"${SCANNER}" "${clean}"
	[ "$status" -eq 0 ] || {
		echo "the scanner reported a finding on a clean fixture (exit ${status});"
		echo "it is crying wolf and the real-tree assertion below cannot be trusted:"
		echo "${output}"
		return 1
	}
}

@test "VACGATE no assertion in this repository is incapable of failing" {
	# THE assertion, and the reason this file is in the gate glob.
	#
	# Exit 2 is CANNOT SCAN and is not a pass — the scanner says so itself. It is
	# separated from exit 1 here because the two mean opposite things and a
	# combined `[ "$status" -eq 0 ]` would report a scanner that could not run as
	# a tree full of vacuous tests, sending the reader to the wrong file.
	run "${SCANNER}"
	if [ "$status" -eq 2 ]; then
		echo "the scanner could not run. This is NOT a pass and NOT a finding about"
		echo "the tree — read its message and fix the scan, do not silence this test:"
		echo "${output}"
		return 1
	fi
	[ "$status" -eq 0 ] || {
		echo "${output}"
		echo ""
		echo "One or more checks in this tree cannot fail. Each reads as coverage and"
		echo "is not. Repair the assertion, or add a line to"
		echo "scripts/vacuous-assertions.allow with a stated reason — the allowlist is"
		echo "for genuine exceptions, and routing a real finding through it is a"
		echo "mitigation that hides its own alarm."
		return 1
	}
}
