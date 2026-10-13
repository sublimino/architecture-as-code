#!/usr/bin/env bash
# verify-cel-mutation-proof.sh — prove test/verify-cel.bats can fail.
#
# scripts/verify-cel.sh exists to turn five test tiers into one honest pass/fail,
# and test/verify-cel.bats exists to prove that pass/fail can go red. Neither is
# worth anything until the second has been shown to notice when a gate in the
# first is removed: a green self-test over a runner with no gates left reads
# exactly like a green self-test over a correct one.
#
# So: delete one gate from the real script, confirm the ONE test that pins it
# goes red, restore, move on. Each mutation is an exact-string replacement
# applied in Python, not a sed expression — the patterns here contain `${...}`,
# `[`, and `/`, and a sed expression that silently matches nothing produces a
# surviving mutant that reads as a test-coverage finding.
#
# Restore is from a byte-for-byte backup taken here, NOT `git checkout --`:
# `git checkout` in a proof harness discards unstaged work elsewhere in the tree.
#
# Run: test/verify-cel-mutation-proof.sh      (~90s, needs docker, go, uv, bats)

set -o pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

TARGET="scripts/verify-cel.sh"

# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"

ms_guard_init verify-cel "${TARGET}"
trap ms_guard_on_exit EXIT INT TERM

restore() { ms_guard_restore; }

failures=0
mutants=0

# mutate OLD NEW — exact-string replacement, first occurrence, must match.
mutate() {
	ms_guard_arm "$1"
	OLD="$1" NEW="$2" TARGET="${TARGET}" python3 -c '
import os, sys
p = os.environ["TARGET"]
s = open(p).read()
old = os.environ["OLD"]
if old not in s:
    sys.exit("mutation pattern not found — the script moved; fix this harness")
open(p, "w").write(s.replace(old, os.environ["NEW"], 1))
'
}

# prove DESCRIPTION FILTER OLD NEW
prove() {
	local desc="$1" filter="$2" old="$3" new="$4" rc
	mutants=$((mutants + 1))
	printf '\n=== %s\n' "${desc}"
	if ! mutate "${old}" "${new}"; then
		failures=$((failures + 1))
		restore
		return
	fi
	bats test/verify-cel.bats --filter "${filter}" >/dev/null 2>&1
	rc=$?
	restore
	if [ "${rc}" -ne 0 ]; then
		echo "    KILLED — '${filter}' went red, as it must"
	else
		echo "    SURVIVED — '${filter}' stayed green with the gate removed"
		failures=$((failures + 1))
	fi
}

prove "the zero-passing-tests gate" 'collects only skips' \
	'	if [ "${passed}" -eq 0 ]; then
		status=FAIL
		note="zero passing tests${note:+; }${note}"
	fi
	if [ -n "${max_skipped}" ]' \
	'	if [ -n "${max_skipped}" ]'

prove "the conformance fixture-count gate" 'zero fixtures' \
	'	if [ "${fixtures}" -eq 0 ]; then' \
	'	if [ "${fixtures}" -lt 0 ]; then'

prove "docker-missing is fatal, not a skip" 'docker is not installed' \
	'			echo "The db tier needs a real Postgres. It does not skip."
			return 1' \
	'			record t5 PASS 1 0 0 0 "docker not found, skipped"
			return 0'

prove "the db tier allows no skips" 'skip inside the db tier' \
	'	if [ -n "${max_skipped}" ] && [ "${skipped}" -gt "${max_skipped}" ]; then' \
	'	if [ -n "${max_skipped}" ] && [ "${skipped}" -gt 9999 ]; then'

prove "the Postgres readiness gate" 'never becomes ready' \
	'		if [ "${ready}" -ne 1 ]; then' \
	'		if [ "${ready}" -ne 1 ] && false; then'

prove "a failing tier reddens the aggregate" 'reddens the whole run' \
	'	[ "${status}" = PASS ] || exit_code=1' \
	'	[ "${status}" = PASS ] || exit_code=0'

# Known redundancy, stated rather than hidden: the pytest exit-5 branch is NOT
# individually killable. Zero collection also means zero passing tests, so the
# gate above catches it first and a mutant that removes only the exit-5 branch
# survives. The behaviour is pinned twice; the branch is not pinned alone.

printf '\n=== restoring and re-running the whole self-test\n'
if bats test/verify-cel.bats; then
	echo "    the restored script is green"
else
	echo "    RESTORED SCRIPT IS RED — restore is broken"
	failures=$((failures + 1))
fi

printf '\n%s mutant(s), %s unaccounted for\n' "${mutants}" "${failures}"
[ "${failures}" -eq 0 ]
