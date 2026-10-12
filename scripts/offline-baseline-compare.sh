#!/usr/bin/env bash
#
# SLSI-OSD-5. The executable half of test/offline-baseline-contract.json.
#
# WHY A COMPARATOR AND NOT AN EXIT CODE
# -------------------------------------
# P1-GOV's problem is that it cannot tell its own regression apart from the
# environment fault it inherited. `make test-all-offline` answers one question:
# did everything pass right now. It cannot answer the question that actually
# matters at adjudication -- is this run better, the same, or worse than what P0
# recorded -- because the baseline for this leg is NOT zero failures. P0
# recorded 1417 passes and 1 failure. Comparing against zero conflates a
# genuine regression, a pre-existing inherited red, and a cold-worktree
# environment fault into one undifferentiated red bar.
#
# The pass count is a FLOOR, not decoration. A suite that silently stops
# executing assertions exits 0, and against a zero-based comparison that reads
# as a pass. Only a recorded floor catches it.
#
# bare invocation (no arguments) == --verify-contract. That is the production
# invocation: it is what `make offline-count-contract` runs.

set -eo pipefail

SCRIPT_NAME="$(basename "$0")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT="${REPO_ROOT}/test/offline-baseline-contract.json"
BASELINE="${REPO_ROOT}/docs/slsi-p0-baseline/baseline.json"

usage() {
	cat <<EOF
usage: ${SCRIPT_NAME} [--verify-contract]
       ${SCRIPT_NAME} --suite <id> --pass <n> --fail <n>
       ${SCRIPT_NAME} --show <id>

  (no arguments)        Same as --verify-contract. The production invocation.
  --verify-contract     Prove every covered suite's recorded counts in
                        test/offline-baseline-contract.json match
                        docs/slsi-p0-baseline/baseline.json exactly, and that no
                        covered suite has a zero pass floor paired with a zero
                        fail ceiling (which would be unfalsifiable).
  --suite ID --pass N --fail M
                        Compare an observed run against P0's recorded counts for
                        ID. Prints REGRESSION, PARITY or IMPROVEMENT. Exit 0 on
                        PARITY or IMPROVEMENT, 1 on REGRESSION, 2 on a usage or
                        contract error.
  --show ID             Print the contract's recorded baseline for ID.
EOF
}

die() {
	echo "${SCRIPT_NAME}: $*" >&2
	exit 2
}

require_inputs() {
	command -v jq >/dev/null 2>&1 || die "jq is not on PATH"
	[ -f "${CONTRACT}" ] || die "missing contract: ${CONTRACT}"
	[ -f "${BASELINE}" ] || die "missing P0 baseline: ${BASELINE}"
}

contract_field() {
	jq -r --arg id "$1" --arg f "$2" \
		'(.coveredSuites[] | select(.id==$id) | .[$f]) // empty' "${CONTRACT}"
}

baseline_field() {
	jq -r --arg id "$1" --arg f "$2" \
		'(.suites[] | select(.id==$id) | .[$f]) // empty' "${BASELINE}"
}

cmd_verify_contract() {
	require_inputs

	local ids id status=0
	ids="$(jq -r '.coveredSuites[].id' "${CONTRACT}")"
	[ -n "${ids}" ] || die "contract covers no suites; a vacuous contract verifies nothing"

	while read -r id; do
		[ -n "${id}" ] || continue
		local f cv bv
		for f in pass fail skip; do
			cv="$(contract_field "${id}" "baseline${f^}")"
			bv="$(baseline_field "${id}" "${f}")"
			[ -n "${bv}" ] || { echo "DRIFT ${id}: not present in P0 baseline" >&2; status=1; continue; }
			if [ "${cv}" != "${bv}" ]; then
				echo "DRIFT ${id}.${f}: contract says ${cv}, P0 baseline says ${bv}" >&2
				status=1
			fi
		done
		cv="$(contract_field "${id}" "baselineState")"
		bv="$(baseline_field "${id}" "state")"
		if [ "${cv}" != "${bv}" ]; then
			echo "DRIFT ${id}.state: contract says ${cv}, P0 baseline says ${bv}" >&2
			status=1
		fi
		cv="$(contract_field "${id}" "baselineExitCode")"
		bv="$(baseline_field "${id}" "exitCode")"
		if [ "${cv}" != "${bv}" ]; then
			echo "DRIFT ${id}.exitCode: contract says ${cv}, P0 baseline says ${bv}" >&2
			status=1
		fi

		# A floor of zero paired with a ceiling of zero is satisfied by a run that
		# executed nothing at all. docs-lint legitimately records 0 passes, so the
		# rejection is of the PAIR, not of a zero pass count on its own.
		if [ "$(contract_field "${id}" "baselinePass")" = "0" ] &&
			[ "$(contract_field "${id}" "baselineFail")" = "0" ]; then
			echo "CONTRACT DEFECT ${id}: pass floor 0 and fail ceiling 0 is unfalsifiable" >&2
			status=1
		fi
		echo "ok ${id}: pass>=$(contract_field "${id}" "baselinePass") fail<=$(contract_field "${id}" "baselineFail") (state $(contract_field "${id}" "baselineState"))"
	done <<< "${ids}"

	if [ "${status}" -ne 0 ]; then
		echo "" >&2
		echo "The comparison contract has drifted from P0's recorded counts." >&2
		echo "Fix the contract to match docs/slsi-p0-baseline/baseline.json;" >&2
		echo "never edit the baseline to match the contract." >&2
		return 1
	fi
	echo "=== offline count contract verified against P0 baseline $(jq -r '.baseline.capturedTipSha' "${CONTRACT}") ==="
}

cmd_show() {
	require_inputs
	local id="$1"
	[ -n "$(contract_field "${id}" "baselineState")" ] ||
		die "suite not covered by the contract: ${id}"
	jq -r --arg id "${id}" '.coveredSuites[] | select(.id==$id)' "${CONTRACT}"
}

cmd_compare() {
	require_inputs
	local id="$1" obs_pass="$2" obs_fail="$3"

	local base_pass base_fail
	base_pass="$(contract_field "${id}" "baselinePass")"
	base_fail="$(contract_field "${id}" "baselineFail")"
	[ -n "${base_pass}" ] || die "suite not covered by the contract: ${id}"

	case "${obs_pass}${obs_fail}" in
	*[!0-9]*) die "--pass and --fail must be non-negative integers" ;;
	esac

	# Reject a zero baseline pass floor paired with a zero fail ceiling: it would
	# make every observation an IMPROVEMENT and the comparison meaningless.
	if [ "${base_pass}" -eq 0 ] && [ "${base_fail}" -eq 0 ]; then
		die "contract defect: ${id} has a zero pass floor and a zero fail ceiling"
	fi

	local verdict="PARITY"
	if [ "${obs_pass}" -lt "${base_pass}" ] || [ "${obs_fail}" -gt "${base_fail}" ]; then
		verdict="REGRESSION"
	elif [ "${obs_pass}" -gt "${base_pass}" ] || [ "${obs_fail}" -lt "${base_fail}" ]; then
		verdict="IMPROVEMENT"
	fi

	echo "${verdict} ${id}: observed pass=${obs_pass} fail=${obs_fail} vs P0 pass=${base_pass} fail=${base_fail}"
	[ "${verdict}" = "REGRESSION" ] && return 1
	return 0
}

main() {
	# NOT "${@:-}": with zero arguments that expands to one empty-string argument
	# and the parser below would reject the bare call, which is the production
	# invocation.
	local suite="" pass="" fail="" mode=""
	if [ "$#" -eq 0 ]; then
		cmd_verify_contract
		return
	fi
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--verify-contract) mode="verify" ;;
		--suite)
			suite="${2-}"
			[ -n "${suite}" ] || die "--suite needs a value"
			shift
			;;
		--pass)
			pass="${2-}"
			[ -n "${pass}" ] || die "--pass needs a value"
			shift
			;;
		--fail)
			fail="${2-}"
			[ -n "${fail}" ] || die "--fail needs a value"
			shift
			;;
		--show)
			mode="show"
			suite="${2-}"
			[ -n "${suite}" ] || die "--show needs a suite id"
			shift
			;;
		--help | -h)
			usage
			return 0
			;;
		*)
			usage >&2
			die "unknown option: $1"
			;;
		esac
		shift
	done

	case "${mode}" in
	verify) cmd_verify_contract ;;
	show) cmd_show "${suite}" ;;
	*)
		[ -n "${suite}" ] || die "give --suite with --pass and --fail, or no arguments to verify the contract"
		[ -n "${pass}" ] || die "--pass is required with --suite"
		[ -n "${fail}" ] || die "--fail is required with --suite"
		cmd_compare "${suite}" "${pass}" "${fail}"
		;;
	esac
}

main "$@"
