#!/usr/bin/env bats
#
# scripts/verify-cel.sh aggregates five tiers of CEL-policy verification into one
# pass/fail. This file is the verification of that verification.
#
# A runner that cannot go red is worse than no runner: it converts "nobody
# checked" into "everything is fine" and does it on every commit. So every gate
# in the aggregator has a test here that injects the condition the gate exists
# for and requires a non-zero exit — a failing tier, a tier that collected no
# tests at all, a tier that collected only skips, a conformance tier that
# scanned no fixtures, and a missing or broken Docker.
#
# Nothing here reads the script to decide whether a gate exists. Each test plants
# a real defect and runs the real runner against it, and each negative is paired
# with a positive on the same tier so that a red result cannot come from the
# injection being malformed. The injection seams are the VERIFY_CEL_* env vars
# the script documents; planted files live in $BATS_TEST_TMPDIR, never in a
# scanned tree.
#
# Runtime ~90s, almost all of it the two positives (uv, go, and a Postgres
# container). No cluster.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
	runner="$repo_root/scripts/verify-cel.sh"
	export VERIFY_CEL_LOG_DIR="$BATS_TEST_TMPDIR/logs"
	mkdir -p "$VERIFY_CEL_LOG_DIR"
}

# plant NAME BODY — a pytest file outside the scanned tree. Echoes its path.
plant() {
	local path="$BATS_TEST_TMPDIR/$1"
	printf '%s\n' "$2" >"$path"
	printf '%s\n' "$path"
}

# tier_row TIER — the aggregate table's row for one tier.
tier_row() {
	printf '%s\n' "$output" | grep -E "^$1 " | head -1
}

# --- the aggregator says PASS when the tiers really pass ----------------------

@test "a real tier passes, and reports the fixture count it scanned" {
	run "$runner" conformance
	echo "$output"
	[ "$status" -eq 0 ]
	[[ "$(tier_row t2)" == *PASS* ]]
	[[ "$output" == *"verify-cel: PASS"* ]]
	# >0 fixtures, printed, so an empty policy/frameworks tree is visible.
	count="$(printf '%s\n' "$output" | grep -oE '[0-9]+ fixtures' | grep -oE '^[0-9]+')"
	[ "$count" -gt 0 ]
}

@test "the db tier passes against a real throwaway Postgres" {
	run "$runner" db
	echo "$output"
	[ "$status" -eq 0 ]
	[[ "$(tier_row t5)" == *PASS* ]]
	# Zero skips: without DATABASE_URL these same tests skip, and the point of
	# the tier is that it ran for real.
	[[ "$(tier_row t5)" =~ ^t5[[:space:]]+db[[:space:]]+PASS[[:space:]]+[0-9]+[[:space:]]+0[[:space:]] ]]
}

@test "no container is left behind by the db tier" {
	run "$runner" db
	[ "$status" -eq 0 ]
	run bash -c "DOCKER_CONFIG=$BATS_TEST_TMPDIR/dockercfg docker ps --format '{{.Names}}' | grep -c '^verify-cel-pg-' || true"
	echo "$output"
	[ "${output//[^0-9]/}" = "0" ]
}

# --- a failing tier must fail the run ----------------------------------------

@test "a tier whose tests fail fails the run" {
	file="$(plant test_planted_failure.py 'def test_planted():
    assert False, "planted"')"
	VERIFY_CEL_T3_FILES="$file" run "$runner" fe-fast
	echo "$output"
	[ "$status" -ne 0 ]
	[[ "$(tier_row t3)" == *FAIL* ]]
	[[ "$output" == *"verify-cel: FAIL"* ]]
}

@test "one failing tier reddens the whole run while the others stay green" {
	file="$(plant test_planted_failure.py 'def test_planted():
    assert False, "planted"')"
	VERIFY_CEL_T3_FILES="$file" run "$runner" conformance fe-fast
	echo "$output"
	[ "$status" -ne 0 ]
	[[ "$(tier_row t2)" == *PASS* ]]
	[[ "$(tier_row t3)" == *FAIL* ]]
}

# --- a tier that checked nothing must fail the run ---------------------------

@test "a tier that collects zero tests fails the run" {
	# pytest exits 5 here, not 1: "no tests ran" is a success-shaped exit in many
	# wrappers, which is exactly how an empty tier reads as green.
	file="$(plant test_planted_empty.py '# no test functions at all
def helper():
    return 1')"
	VERIFY_CEL_T3_FILES="$file" run "$runner" fe-fast
	echo "$output"
	[ "$status" -ne 0 ]
	[[ "$(tier_row t3)" == *FAIL* ]]
	[[ "$output" == *"no tests ran"* || "$(tier_row t3)" == *"zero passing tests"* ]]
}

@test "a tier that collects only skips fails the run" {
	file="$(plant test_planted_skips.py 'import pytest


@pytest.mark.skip(reason="planted")
def test_planted():
    assert True')"
	VERIFY_CEL_T3_FILES="$file" run "$runner" fe-fast
	echo "$output"
	[ "$status" -ne 0 ]
	[[ "$(tier_row t3)" == *"zero passing tests"* ]]
}

@test "a skip inside the db tier fails the run" {
	# The db tier is the one tier held to zero skips. Without DATABASE_URL its
	# real tests skip, so "0 passed, N skipped, exit 0" is the shape a broken
	# environment produces, and it must not be green.
	file="$(plant test_planted_db_skip.py 'import pytest


def test_planted_ok():
    assert True


@pytest.mark.skip(reason="planted")
def test_planted_skipped():
    assert True')"
	VERIFY_CEL_T5_FILES="$file" run "$runner" db
	echo "$output"
	[ "$status" -ne 0 ]
	[[ "$(tier_row t5)" == *"1 skipped, max 0"* ]]
}

@test "a conformance tier that scans zero fixtures fails the run" {
	# A real, passing go run — TestConformance_ChecksCompile is green — that
	# replays no fixture through the engine. Green tests plus an empty fixture
	# tree is the silent failure the fixture count exists to catch.
	VERIFY_CEL_T2_RUN=TestConformance_ChecksCompile run "$runner" conformance
	echo "$output"
	[ "$status" -ne 0 ]
	[[ "$(tier_row t2)" == *"zero conformance fixtures"* ]]
}

@test "an engine tier pointed at a package with no tests fails the run" {
	mkdir -p "$BATS_TEST_TMPDIR/mod"
	printf 'module planted\n\ngo 1.24\n' >"$BATS_TEST_TMPDIR/mod/go.mod"
	printf 'package planted\n\nfunc Unused() int { return 1 }\n' \
		>"$BATS_TEST_TMPDIR/mod/planted.go"
	VERIFY_CEL_ENGINE_DIR="$BATS_TEST_TMPDIR/mod" run "$runner" engine
	echo "$output"
	[ "$status" -ne 0 ]
	[[ "$(tier_row t1)" == *FAIL* ]]
}

# --- Docker unavailable must fail loudly, never skip -------------------------

@test "the db tier fails loudly when docker is not installed" {
	VERIFY_CEL_DOCKER="$BATS_TEST_TMPDIR/no-such-docker" run "$runner" db
	echo "$output"
	[ "$status" -ne 0 ]
	[[ "$(tier_row t5)" == *FAIL* ]]
	[[ "$output" != *"verify-cel: PASS"* ]]
	grep -q 'docker not found' "$VERIFY_CEL_LOG_DIR/t5.setup.log"
	# And it must not have called it a skip.
	[[ "$(tier_row t5)" != *SKIP* ]]
}

@test "the db tier fails loudly when the docker daemon is unusable" {
	fake="$BATS_TEST_TMPDIR/docker"
	printf '%s\n' '#!/usr/bin/env bash' 'echo "Cannot connect to the Docker daemon" >&2' 'exit 1' >"$fake"
	chmod +x "$fake"
	VERIFY_CEL_DOCKER="$fake" run "$runner" db
	echo "$output"
	[ "$status" -ne 0 ]
	[[ "$(tier_row t5)" == *FAIL* ]]
	grep -q 'no usable Docker daemon' "$VERIFY_CEL_LOG_DIR/t5.setup.log"
}

@test "the db tier fails when Postgres never becomes ready" {
	# The container starts but never answers pg_isready. A readiness loop that
	# falls through silently is a known shape of bug in this repo's scripts.
	fake="$BATS_TEST_TMPDIR/docker"
	cat >"$fake" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
info) exit 0 ;;
run) echo fakecontainer; exit 0 ;;
port) echo "127.0.0.1:65432"; exit 0 ;;
exec) exit 1 ;;
stop | rm) exit 0 ;;
*) exit 0 ;;
esac
FAKE
	chmod +x "$fake"
	VERIFY_CEL_DOCKER="$fake" VERIFY_CEL_PG_TIMEOUT=2 run "$runner" db
	echo "$output"
	[ "$status" -ne 0 ]
	[[ "$(tier_row t5)" == *FAIL* ]]
	grep -q 'not ready after 2s' "$VERIFY_CEL_LOG_DIR/t5.setup.log"
}

# --- the runner itself ------------------------------------------------------

@test "an unknown tier name is an error, not a silent no-op" {
	run "$runner" no-such-tier
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown tier"* ]]
}
