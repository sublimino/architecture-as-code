#!/usr/bin/env bash
#
# SLSI-OSD-5. Proves that every assertion in test/offline-install-boundary.bats
# and test/offline-count-contract.bats can FAIL, and fails for the reason it
# claims to catch.
#
# A green suite proves nothing on its own. The only question that matters about
# a guard is whether it goes red when the thing it guards is broken, and the
# only way to answer it is to break that thing and watch. For each mutation
# below the script states which named test must go red; a mutation that leaves
# every test green is reported as an UNPROVEN assertion, which is a defect in
# the suite, not in the mutation.
#
# RUN IT ALONE. It mutates the real Makefile, the real scripts and the real
# contract in place. A concurrent edit in this checkout lands inside a mutation
# window and reads exactly like a real finding.
#
# Restoration is from an explicit byte-for-byte backup taken before the first
# mutation and verified by sha256 afterwards -- never `git checkout -- .`, which
# does nothing for untracked files and silently discards unstaged fixes in
# tracked ones. Both of those have already cost this project real work.
#
# Registered by `make test-offline-mutation-proof`.

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/offline-mutation-proof.XXXXXX")"
MUTATED_FILES=(
	"Makefile"
	"scripts/offline-deps.sh"
	"scripts/offline-baseline-compare.sh"
	"test/offline-baseline-contract.json"
	"test/offline-install-boundary.bats"
)

PROVEN=0
UNPROVEN=()

backup_all() {
	local f
	for f in "${MUTATED_FILES[@]}"; do
		mkdir -p "${BACKUP_DIR}/$(dirname "${f}")"
		cp -p "${f}" "${BACKUP_DIR}/${f}"
	done
	( cd "${BACKUP_DIR}" && find . -type f -exec sha256sum {} + ) | sort > "${BACKUP_DIR}/.sums"
}

restore_all() {
	local f
	for f in "${MUTATED_FILES[@]}"; do
		cp -p "${BACKUP_DIR}/${f}" "${f}"
	done
}

verify_restored() {
	local f ok=0
	for f in "${MUTATED_FILES[@]}"; do
		if ! cmp -s "${BACKUP_DIR}/${f}" "${f}"; then
			echo "RESTORE FAILED: ${f} does not match its backup at ${BACKUP_DIR}/${f}" >&2
			ok=1
		fi
		# Modes as well as bytes. cmp is blind to permissions, and the first run
		# of this proof stripped the executable bit off two scripts while every
		# content comparison passed -- an invisible mutation residue. Compared via
		# a test -x round trip rather than stat, which takes different flags on
		# BSD and GNU.
		if [ -x "${BACKUP_DIR}/${f}" ] && [ ! -x "${f}" ]; then
			echo "RESTORE FAILED: ${f} lost its executable bit" >&2
			ok=1
		fi
		if [ ! -x "${BACKUP_DIR}/${f}" ] && [ -x "${f}" ]; then
			echo "RESTORE FAILED: ${f} gained an executable bit" >&2
			ok=1
		fi
	done
	return "${ok}"
}

cleanup() {
	local rc=$?
	restore_all || true
	if verify_restored; then
		rm -rf "${BACKUP_DIR}"
	else
		echo "Backups retained at ${BACKUP_DIR}" >&2
		rc=1
	fi
	exit "${rc}"
}
trap cleanup EXIT INT TERM

# Literal first-occurrence replacement. Writes to a temp file and moves it into
# place: never `sed -i`, which needs an argument on BSD and does not on GNU.
subst() {
	local f="$1" old="$2" new="$3" tmp
	tmp="$(mktemp "${TMPDIR:-/tmp}/offline-mut.XXXXXX")"
	awk -v old="${old}" -v new="${new}" '
		BEGIN { done = 0 }
		{
			if (!done) {
				i = index($0, old)
				if (i > 0) {
					$0 = substr($0, 1, i - 1) new substr($0, i + length(old))
					done = 1
				}
			}
			print
		}
		END { if (!done) exit 3 }
	' "${f}" > "${tmp}" || { rm -f "${tmp}"; echo "MUTATION TARGET NOT FOUND in ${f}: ${old}" >&2; return 3; }
	# Write THROUGH the original file rather than `mv`-ing over it. mv replaces
	# the file and its permissions with mktemp's 0600, which silently stripped the
	# executable bit off both scripts on this proof's first run -- a mutation side
	# effect that outlived the mutation, because the restore below compares with
	# cmp and cmp does not look at modes. Redirecting into the existing path keeps
	# the inode and therefore the mode, with no GNU-only stat or chmod flags.
	cat "${tmp}" > "${f}"
	rm -f "${tmp}"
}

jq_edit() {
	local f="$1" filter="$2" tmp
	tmp="$(mktemp "${TMPDIR:-/tmp}/offline-mut.XXXXXX")"
	jq "${filter}" "${f}" > "${tmp}"
	cat "${tmp}" > "${f}"
	rm -f "${tmp}"
}

# Run one bats suite and report whether the NAMED test went red. The named test
# is checked specifically: a mutation that reddens some other test has not
# proven the assertion it was aimed at.
#
# bats output is captured to a file and the exit code read from the direct call,
# never through a pipe -- `cmd | tail; echo $?` is tail's status, which has
# bitten this repo three times.
expect_red() {
	local label="$1" suite="$2" test_name="$3" log
	log="$(mktemp "${TMPDIR:-/tmp}/offline-mut-log.XXXXXX")"
	set +e
	bats "${suite}" > "${log}" 2>&1
	local rc=$?
	set -e
	if [ "${rc}" -eq 0 ]; then
		echo "UNPROVEN  ${label}"
		echo "          suite ${suite} stayed GREEN under the mutation"
		UNPROVEN+=("${label}")
		rm -f "${log}"
		return 0
	fi
	# `--` before the pattern: several expected test names begin with `--check`
	# or `--pass`, which grep otherwise parses as its own options and dies with
	# "unrecognized option", reporting a genuinely-proven mutation as UNPROVEN.
	if grep -qF -- "not ok" "${log}" && grep -F -- "not ok" "${log}" | grep -qF -- "${test_name}"; then
		echo "PROVEN    ${label}"
		echo "          red at: ${test_name}"
		PROVEN=$((PROVEN + 1))
	else
		echo "UNPROVEN  ${label}"
		echo "          suite went red but NOT at the expected test: ${test_name}"
		echo "          actual failures:"
		grep -F "not ok" "${log}" | sed 's/^/            /' || true
		UNPROVEN+=("${label}")
	fi
	rm -f "${log}"
}

BOUNDARY=test/offline-install-boundary.bats
COUNTS=test/offline-count-contract.bats

echo "=== offline mutation proof: backing up ${#MUTATED_FILES[@]} files to ${BACKUP_DIR} ==="
backup_all

echo ""
echo "--- baseline: both suites must be GREEN before any mutation"
bats "${BOUNDARY}" > /dev/null
bats "${COUNTS}" > /dev/null
echo "ok both suites green at baseline"

echo ""
echo "=== boundary suite ==="

subst Makefile '@echo "=== [Offline 5/5] Static Config, Manifests, Registries & Guards ==="' '@echo "=== static gates ==="'
expect_red "M1  offline leg loses a stage marker (extractor anti-vacuity)" "${BOUNDARY}" "the recipe extractor is not vacuous"
restore_all

subst Makefile 'test-all-offline: offline-deps ##' 'test-all-offline: ##'
expect_red "M2  offline-deps dropped as a prerequisite of the offline leg" "${BOUNDARY}" "offline-deps is a declared prerequisite of test-all-offline"
restore_all

subst Makefile 'test-dashboard-weave: offline-deps ##' 'test-dashboard-weave: ##'
expect_red "M3  offline-deps dropped as a prerequisite of test-dashboard-weave" "${BOUNDARY}" "offline-deps is a declared prerequisite of test-dashboard-weave"
restore_all

# THE mutation this whole card exists to prevent: the install moved back inside
# the offline assertion, where it makes the leg green and the word meaningless.
subst Makefile '	bats test/test-count-floor.bats' '	cd d2-signalloom/apps/dashboard-signalloom && bun install --frozen-lockfile\n	bats test/test-count-floor.bats'
expect_red "M4  a network install moved INSIDE the offline leg's recipe" "${BOUNDARY}" "the test-all-offline recipe contains no dependency install"
restore_all

subst Makefile '	node d2-signalloom/apps/dashboard-signalloom/node_modules/vitest/vitest.mjs run \' '	cd d2-signalloom/apps/dashboard-signalloom && bun install --frozen-lockfile\n	node d2-signalloom/apps/dashboard-signalloom/node_modules/vitest/vitest.mjs run \'
expect_red "M5  a network install moved INSIDE test-dashboard-weave's recipe" "${BOUNDARY}" "the test-dashboard-weave recipe contains no dependency install"
restore_all

subst scripts/offline-deps.sh '	"d2-signalloom/design-system-demo"' '	"d2-signalloom/apps/docs-signalloom"'
expect_red "M6  a workspace the offline leg enters is no longer declared" "${BOUNDARY}" "every bun workspace the offline leg enters is declared"
restore_all

# A recursive-make line that is otherwise harmless, so that ONLY the
# no-recursion assertion can go red. The first attempt replaced the script
# invocation with a sub-make of a non-existent target, which also emptied the
# dry-run output and reddened test 8 instead -- a mutation that proves the wrong
# assertion is not a proof of the one it was aimed at.
subst Makefile '	./scripts/offline-deps.sh' '	$(MAKE) --no-print-directory --version >/dev/null\n	./scripts/offline-deps.sh'
expect_red "M7  recursive make introduced into the install target" "${BOUNDARY}" "uses no recursive make"
restore_all

# A line containing $(MAKE) is executed even under `make -n`, so putting a real
# install on such a line makes a dry run build for real -- the defect this repo
# has already been bitten by.
subst Makefile '	./scripts/offline-deps.sh' '	$(MAKE) --version >/dev/null; ./scripts/offline-deps.sh'
expect_red "M8  make -n made to perform the install for real" "${BOUNDARY}" "make -n offline-deps prints the install without performing it"
restore_all

# The no-argument production path, broken directly at the arm that serves it.
#
# Worth recording why this is not the `main "${@:-}"` mutation: it was, and the
# suite stayed GREEN, because this script's parser reads "${1-}" and matches the
# empty string in its "" arm, so it survives the extra empty argument that
# defect normally produces. The comparator script's parser branches on $# and
# does NOT survive it (see C2). Same idiom, different blast radius -- which is
# exactly why the mutation has to be run rather than reasoned about.
subst scripts/offline-deps.sh '	"") cmd_install ;;' '	"") die "refusing to run with no arguments" ;;'
expect_red "M9  no-argument production invocation broken by \${@:-}" "${BOUNDARY}" "with NO arguments installs and reports every workspace satisfied"
restore_all

subst scripts/offline-deps.sh '	[ -d "${REPO_ROOT}/${dir}/node_modules" ] &&' '	[ -d "${REPO_ROOT}/${dir}/node_modules_absent" ] &&'
expect_red "M10 --check reports a satisfied workspace as unsatisfied" "${BOUNDARY}" "--check reports satisfied for every declared workspace"
restore_all

subst scripts/offline-deps.sh '		die "unknown option: $1"' '		cmd_install'
expect_red "M11 unknown option silently falls through to an install" "${BOUNDARY}" "rejects an unknown option with a usage message"
restore_all

subst scripts/offline-deps.sh '		( cd "${REPO_ROOT}/${dir}" && bun install --frozen-lockfile )' '		( cd "${REPO_ROOT}/${dir}" && npm install --no-audit )'
expect_red "M12 install switched from bun to npm" "${BOUNDARY}" "installs with bun only and never reaches for npm"
restore_all

echo ""
echo "=== count contract suite ==="

mv test/offline-baseline-contract.json "${BACKUP_DIR}/contract-moved-aside.json"
expect_red "C1  the contract file is missing" "${COUNTS}" "both inputs exist and parse as JSON"
mv "${BACKUP_DIR}/contract-moved-aside.json" test/offline-baseline-contract.json

subst scripts/offline-baseline-compare.sh 'main "$@"' 'main "${@:-}"'
expect_red "C2  comparator's no-argument production invocation broken" "${COUNTS}" "with NO arguments verifies the contract"
restore_all

jq_edit test/offline-baseline-contract.json '(.coveredSuites[]|select(.id=="test-all-offline")|.baselinePass) = 1418'
expect_red "C3  contract drifts one pass away from P0's recorded count" "${COUNTS}" "counts equal P0's recorded counts exactly"
restore_all

jq_edit test/offline-baseline-contract.json '(.coveredSuites[]|select(.id=="test-obscel")|.baselinePass) = 0 | (.coveredSuites[]|select(.id=="test-obscel")|.baselineFail) = 0'
expect_red "C4  a covered suite given an unfalsifiable zero/zero baseline" "${COUNTS}" "never against zero"
restore_all

jq_edit test/offline-baseline-contract.json '(.coveredSuites[]|select(.id=="docs-lint")|.baselineFail) = 20'
expect_red "C5  the 21 inherited docs-lint findings miscounted as 20" "${COUNTS}" "PROVEN inherited from cb0a6d0e"
restore_all

jq_edit test/offline-baseline-contract.json '(.coveredSuites[]|select(.id=="docs-lint")|.baselineState) = "RED_NEW"'
expect_red "C6  inherited red relabelled as a new red" "${COUNTS}" "kept distinct in the contract"
restore_all

jq_edit test/offline-baseline-contract.json '.excludedSuites |= map(select(.id != "test-all-cluster"))'
expect_red "C7  a P0 baseline suite silently omitted from the contract" "${COUNTS}" "either covered or explicitly excluded"
restore_all

jq_edit test/offline-baseline-contract.json '.excludedSuites |= map(select(.id != "test-slsi-airgap"))'
expect_red "C8  the P1-4 air-gap suite left unaccounted for" "${COUNTS}" "air-gap suite is accounted for"
restore_all

jq_edit test/offline-baseline-contract.json '(.residualReds[0].failingTests) = "two"'
expect_red "C9  a residual red carried without a numeric count" "${COUNTS}" "carried with a count and an attribution"
restore_all

jq_edit test/offline-baseline-contract.json '(.residualReds[]|select(.suite|test("bootstrap drift"))|.failingTests) = 1'
expect_red "C15 a residual red's measured count altered" "${COUNTS}" "carried with a count and an attribution"
restore_all

jq_edit test/offline-baseline-contract.json '.residualReds[0] |= del(.legLine)'
expect_red "C16 a residual red stops naming the leg line it reddens" "${COUNTS}" "carried with a count and an attribution"
restore_all

jq_edit test/offline-baseline-contract.json '.coverageCaveat = "The offline leg is comprehensively covered by CI."'
expect_red "C10 the CI coverage caveat removed" "${COUNTS}" "coverage caveat states that no pipeline runs the offline leg"
restore_all

subst scripts/offline-baseline-compare.sh '	if [ "${obs_pass}" -lt "${base_pass}" ] || [ "${obs_fail}" -gt "${base_fail}" ]; then' '	if false; then'
expect_red "C11 regression detection disabled in the comparator" "${COUNTS}" "one fewer pass than P0 is a REGRESSION"
restore_all

subst scripts/offline-baseline-compare.sh '	[ -n "${base_pass}" ] || die "suite not covered by the contract: ${id}"' '	[ -n "${base_pass}" ] || base_pass=0'
expect_red "C12 comparator accepts a suite the contract does not cover" "${COUNTS}" "refuses a suite the contract does not cover"
restore_all

subst scripts/offline-baseline-compare.sh '	*[!0-9]*) die "--pass and --fail must be non-negative integers" ;;' '	*[!0-9]*) : ;;'
expect_red "C13 comparator accepts non-numeric counts" "${COUNTS}" "refuses non-numeric counts"
restore_all

subst scripts/offline-baseline-compare.sh '			die "unknown option: $1"' '			: ;;'
expect_red "C14 comparator's unknown-option arm removed" "${COUNTS}" "rejects an unknown option with a usage message"
restore_all

echo ""
echo "--- restoring and re-proving both suites are GREEN"
restore_all
verify_restored
bats "${BOUNDARY}" > /dev/null
bats "${COUNTS}" > /dev/null
echo "ok both suites green after restoration, all files byte-identical to backup"

echo ""
echo "=== offline mutation proof: ${PROVEN} mutations PROVEN ==="
if [ "${#UNPROVEN[@]}" -gt 0 ]; then
	echo "UNPROVEN assertions (${#UNPROVEN[@]}):" >&2
	printf '  %s\n' "${UNPROVEN[@]}" >&2
	echo "" >&2
	echo "An assertion that cannot be made to fail is not an assertion." >&2
	exit 1
fi
