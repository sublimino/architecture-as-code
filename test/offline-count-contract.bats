#!/usr/bin/env bats
#
# SLSI-OSD-5. Proves the offline leg's comparison contract against P0's record.
#
# The contract exists because P1-GOV cannot otherwise tell its own regression
# apart from the environment fault it inherited: the baseline for this leg is
# not zero failures, it is 1417 passes and 1 failure. A contract that merely
# ASSERTS those numbers is worthless the first time somebody retypes one, so
# every count below is cross-read from docs/slsi-p0-baseline/baseline.json by
# this file independently of scripts/offline-baseline-compare.sh. Two readers,
# one source of truth. If they ever disagree, one of them is wrong and the test
# says which.
#
# Owned by `make offline-count-contract`, which the offline leg's static
# section runs.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	CONTRACT="${REPO_ROOT}/test/offline-baseline-contract.json"
	BASELINE="${REPO_ROOT}/docs/slsi-p0-baseline/baseline.json"
	COMPARE="${REPO_ROOT}/scripts/offline-baseline-compare.sh"
}

@test "both inputs exist and parse as JSON" {
	# Anti-vacuity floor for every assertion below: a missing or unparseable
	# baseline would make several jq reads return empty and compare equal.
	[ -f "${CONTRACT}" ]
	[ -f "${BASELINE}" ]
	run jq -e . "${CONTRACT}"
	[ "$status" -eq 0 ]
	run jq -e . "${BASELINE}"
	[ "$status" -eq 0 ]
	[ "$(jq '.suites | length' "${BASELINE}")" -gt 5 ]
	[ "$(jq '.coveredSuites | length' "${CONTRACT}")" -gt 0 ]
}

@test "offline-baseline-compare.sh with NO arguments verifies the contract" {
	# The production invocation. `make offline-count-contract` passes no flags.
	run bash "${COMPARE}"
	[ "$status" -eq 0 ]
	echo "$output" | grep -qF 'offline count contract verified against P0 baseline'
	echo "$output" | grep -qF 'ok test-all-offline'
	echo "$output" | grep -qF 'ok docs-lint'
}

@test "the contract's test-all-offline counts equal P0's recorded counts exactly" {
	local c b
	for f in pass fail skip; do
		c="$(jq -r --arg f "baseline${f^}" '.coveredSuites[]|select(.id=="test-all-offline")|.[$f]' "${CONTRACT}")"
		b="$(jq -r --arg f "$f" '.suites[]|select(.id=="test-all-offline")|.[$f]' "${BASELINE}")"
		[ -n "$b" ]
		[ "$c" = "$b" ]
	done
	[ "$(jq -r '.suites[]|select(.id=="test-all-offline")|.pass' "${BASELINE}")" = "1417" ]
	[ "$(jq -r '.suites[]|select(.id=="test-all-offline")|.fail' "${BASELINE}")" = "1" ]
	[ "$(jq -r '.coveredSuites[]|select(.id=="test-all-offline")|.baselineState' "${CONTRACT}")" = "RED_NEW" ]
}

@test "the comparison is against P0's counts and never against zero" {
	# The defect this pins: a leg compared against zero reports any run with no
	# failures as a pass, including a run that executed nothing.
	local n
	n="$(jq '[.coveredSuites[] | select(.baselinePass == 0 and .baselineFail == 0)] | length' "${CONTRACT}")"
	[ "$n" -eq 0 ]
	[ "$(jq -r '.coveredSuites[]|select(.id=="test-all-offline")|.baselinePass' "${CONTRACT}")" -gt 0 ]
	jq -e '.rules.neverCompareAgainstZero' "${CONTRACT}" >/dev/null
	jq -e '.rules.passIsAFloor' "${CONTRACT}" >/dev/null
}

@test "the 21 docs-lint findings are PROVEN inherited from cb0a6d0e, not asserted" {
	# Count them out of the baseline's own evidence rather than trusting the
	# number in either file.
	[ "$(jq '[.foreignFailures[]|select(.suite=="docs-lint")]|length' "${BASELINE}")" -eq 21 ]
	[ "$(jq -r '[.foreignFailures[]|select(.suite=="docs-lint")|.originCommit]|unique|length' "${BASELINE}")" -eq 1 ]
	[ "$(jq -r '[.foreignFailures[]|select(.suite=="docs-lint")|.originCommit]|unique|.[0]' "${BASELINE}")" = "cb0a6d0e" ]
	[ "$(jq -r '[.foreignFailures[]|select(.suite=="docs-lint")|.ownedBySLSI]|unique|.[0]' "${BASELINE}")" = "false" ]
	# The P0 suite record and the handoff both have to agree with that count.
	[ "$(jq -r '.suites[]|select(.id=="docs-lint")|.fail' "${BASELINE}")" = "21" ]
	[ "$(jq -r '.handoff.allowedDeviations.docsLintFindings' "${BASELINE}")" = "21" ]
	# And the contract must carry them as RED_INHERITED, not as an environment red.
	[ "$(jq -r '.coveredSuites[]|select(.id=="docs-lint")|.baselineState' "${CONTRACT}")" = "RED_INHERITED" ]
	[ "$(jq -r '.coveredSuites[]|select(.id=="docs-lint")|.baselineFail' "${CONTRACT}")" = "21" ]
	[ "$(jq -r '.coveredSuites[]|select(.id=="docs-lint")|.countsAsEnvironmentRed' "${CONTRACT}")" = "false" ]
	[ "$(jq -r '.coveredSuites[]|select(.id=="docs-lint")|.originCommit' "${CONTRACT}")" = "cb0a6d0e" ]
}

@test "RED_INHERITED and RED_NEW are kept distinct in the contract" {
	jq -e '.rules.inheritedIsNotEnvironment' "${CONTRACT}" >/dev/null
	# Exactly one covered suite is inherited and exactly one is new; a contract
	# that labelled both the same way would pass every other test here.
	[ "$(jq '[.coveredSuites[]|select(.baselineState=="RED_INHERITED")]|length' "${CONTRACT}")" -eq 1 ]
	[ "$(jq '[.coveredSuites[]|select(.baselineState=="RED_NEW")]|length' "${CONTRACT}")" -eq 1 ]
}

@test "every suite in P0's baseline is either covered or explicitly excluded" {
	# Silent omission is the failure mode: a suite that appears in neither list
	# is a suite nobody decided about.
	local unaccounted=""
	while read -r id; do
		[ -n "$id" ] || continue
		jq -e --arg id "$id" \
			'[(.coveredSuites[].id),(.excludedSuites[].id)] | index($id)' \
			"${CONTRACT}" >/dev/null || unaccounted="${unaccounted}${id} "
	done < <(jq -r '.suites[].id' "${BASELINE}")
	if [ -n "${unaccounted}" ]; then
		echo "P0 baseline suite(s) the contract neither covers nor excludes:" >&2
		echo "  ${unaccounted}" >&2
		false
	fi
}

@test "the P1-4 air-gap suite is accounted for as having no P0 baseline" {
	# It was added to the Makefile by the merge that produced this base, AFTER P0
	# capture. Comparing it against zero would be as wrong as comparing the
	# offline leg against zero.
	[ -z "$(jq -r '.suites[]|select(.id=="test-slsi-airgap")|.id' "${BASELINE}")" ]
	[ "$(jq -r '.excludedSuites[]|select(.id=="test-slsi-airgap")|.baselineState' "${CONTRACT}")" = "NOT_IN_BASELINE" ]
	[ -n "$(jq -r '.excludedSuites[]|select(.id=="test-slsi-airgap")|.reason' "${CONTRACT}")" ]
	grep -q 'test-slsi-airgap' "${REPO_ROOT}/Makefile"
}

@test "residual reds are carried with a count and an attribution" {
	[ "$(jq '.residualReds|length' "${CONTRACT}")" -gt 0 ]
	local n
	n="$(jq '[.residualReds[]|select((.failingTests|type)=="number" and (.attribution|length)>0 and (.detail|length)>0)]|length' "${CONTRACT}")"
	[ "$n" -eq "$(jq '.residualReds|length' "${CONTRACT}")" ]
	# The two we measured on this base, by running the leg's 56 recipe lines
	# individually -- `make -k` cannot enumerate them, because the whole leg is a
	# single recipe and make aborts a recipe at its first failing line regardless
	# of -k.
	[ "$(jq -r '.residualReds[]|select(.suite|test("bats-registry-coverage"))|.failingTests' "${CONTRACT}")" = "1" ]
	[ "$(jq -r '.residualReds[]|select(.suite|test("bootstrap drift"))|.failingTests' "${CONTRACT}")" = "2" ]
	# Every residual must name the leg line it reddens, so the next person can
	# reproduce it without re-deriving the enumeration.
	[ "$(jq '[.residualReds[]|select((.legLine|type)=="number")]|length' "${CONTRACT}")" -eq "$(jq '.residualReds|length' "${CONTRACT}")" ]
}

@test "the coverage caveat states that no pipeline runs the offline leg" {
	# Measured, not assumed: the claim in the contract has to still be true.
	local hits=0 p
	for p in scripts/ci/vm-pipeline.sh scripts/gcp-tf/demo-pipeline.sh .github/workflows/signalloom-eap-pr.yaml; do
		[ -f "${REPO_ROOT}/${p}" ] || continue
		if grep -qF 'test-all-offline' "${REPO_ROOT}/${p}"; then
			hits=$((hits + 1))
		fi
	done
	[ "$hits" -eq 0 ]
	jq -e '.coverageCaveat' "${CONTRACT}" >/dev/null
	jq -r '.coverageCaveat' "${CONTRACT}" | grep -qF 'proves NOTHING about CI'
}

@test "comparator verdict: observed equal to P0 is PARITY and exits 0" {
	run bash "${COMPARE}" --suite test-all-offline --pass 1417 --fail 1
	[ "$status" -eq 0 ]
	echo "$output" | grep -qF 'PARITY'
}

@test "comparator verdict: one fewer pass than P0 is a REGRESSION and exits 1" {
	run bash "${COMPARE}" --suite test-all-offline --pass 1416 --fail 1
	[ "$status" -eq 1 ]
	echo "$output" | grep -qF 'REGRESSION'
}

@test "comparator verdict: one more failure than P0 is a REGRESSION and exits 1" {
	run bash "${COMPARE}" --suite test-all-offline --pass 1417 --fail 2
	[ "$status" -eq 1 ]
	echo "$output" | grep -qF 'REGRESSION'
}

@test "comparator verdict: clearing P0's failure is an IMPROVEMENT and exits 0" {
	run bash "${COMPARE}" --suite test-all-offline --pass 1417 --fail 0
	[ "$status" -eq 0 ]
	echo "$output" | grep -qF 'IMPROVEMENT'
}

@test "comparator refuses a suite the contract does not cover" {
	run bash "${COMPARE}" --suite test-all-cluster --pass 1 --fail 0
	[ "$status" -eq 2 ]
	echo "$output" | grep -qF 'not covered by the contract'
}

@test "comparator refuses non-numeric counts rather than comparing them as strings" {
	run bash "${COMPARE}" --suite test-all-offline --pass many --fail 1
	[ "$status" -eq 2 ]
	echo "$output" | grep -qF 'non-negative integers'
}

@test "comparator rejects an unknown option with a usage message" {
	run bash "${COMPARE}" --compare-against-zero
	[ "$status" -eq 2 ]
	echo "$output" | grep -qF 'unknown option'
	echo "$output" | grep -qF 'usage:'
}
