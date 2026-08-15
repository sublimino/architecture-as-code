#!/usr/bin/env bats
#
# Assert that each test suite executed a MINIMUM number of tests.
#
# The defect this pins: a runner that completes "successfully" with zero tests
# executed. In this repo's history that has happened three distinct ways:
#
#   1. pytest's `-n auto` added via pytest.ini was an unrecognised argument when
#      PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 was active — pytest exited on a usage
#      error before collecting anything. The downstream harness ran 12 cases of
#      "mutations" against an unchanged file and reported every audit guard was
#      decoration.
#
#   2. A Playwright spec matching no project's testMatch was silently skipped —
#      exit 0, no warning. Four specs hid that way.
#
#   3. A bats suite executed by no runner at all: 33 of 68 suites, ~640
#      assertions, committed and never run. Among them the suite four docs call
#      "the enforcement mechanism for nginx route collisions".
#
# The guard against case 2 exists (acceptance-spec-coverage.bats). The guard
# against case 3 exists (bats-registry-coverage.bats). This file guards case 1
# in its general form: a runner that started, appeared to succeed, and measured
# nothing. It also detects a catastrophic regression that drops the count below
# the floor — a removed test file, a skipped import, a collection error that
# hides half the suite.
#
# Floor values are deliberately set ~15% below the current count so normal
# development does not trip them, but a broken collection or a runner that
# silently stops does.
#
# These floors are NOT aspirational targets. They are circuit-breakers. A value
# at or near the floor means something is wrong with the runner, not with the
# code under test.

setup() {
    repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
    fe_src="$repo_root/d2-signalloom/apps/fe-signalloom/src"
    dashboard="$repo_root/d2-signalloom/apps/dashboard-signalloom"
    riskctl="$repo_root/tools/riskctl"
}

# ---------------------------------------------------------------------------
# pytest (fe-signalloom)
# ---------------------------------------------------------------------------
# Current: 594 passed, 83 skipped, 677 collected.
# Floor: 500. A drop below 500 means collection broke or a large test file was
# silently excluded.

@test "pytest collected at least 500 tests" {
    cd "$fe_src"
    local out
    out="$(uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist \
             --with-requirements requirements.txt \
             python -m pytest tests --collect-only -q 2>&1 | tail -3)"

    local collected
    collected="$(echo "$out" | grep -oP '(\d+) tests? collected' | grep -oP '^\d+' || echo 0)"

    if [ "$collected" -lt 500 ]; then
        echo "FLOOR BREACH: pytest collected only $collected tests (floor: 500)"
        echo "Current baseline: 677 collected. A count this low means collection"
        echo "broke — a missing import, an unrecognised argument, or a file that"
        echo "was silently excluded."
        echo "Raw output: $out"
        false
    fi
}

@test "pytest passed at least 500 tests" {
    cd "$fe_src"
    local out
    out="$(uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist \
             --with-requirements requirements.txt \
             python -m pytest tests -q 2>&1 | tail -3)"

    local passed
    passed="$(echo "$out" | grep -oP '(\d+) passed' | grep -oP '^\d+' || echo 0)"

    if [ "$passed" -lt 500 ]; then
        echo "FLOOR BREACH: pytest passed only $passed tests (floor: 500)"
        echo "Current baseline: 594 passed. This is either a mass failure or a"
        echo "runner that did not actually run."
        echo "Raw output: $out"
        false
    fi
}

@test "pytest reported zero failures" {
    cd "$fe_src"
    local out
    out="$(uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist \
             --with-requirements requirements.txt \
             python -m pytest tests -q 2>&1 | tail -3)"

    local failed
    failed="$(echo "$out" | grep -oP '(\d+) failed' | grep -oP '^\d+' || echo 0)"

    if [ "$failed" -gt 0 ]; then
        echo "pytest reported $failed failure(s)"
        echo "Raw output: $out"
        false
    fi
}

# ---------------------------------------------------------------------------
# vitest (dashboard-signalloom)
# ---------------------------------------------------------------------------
# Current: 2099 passed, 1 skipped, 106 test files.
# Floor: 1800 tests, 90 files.

@test "vitest passed at least 1800 tests" {
    cd "$dashboard"
    [ -d node_modules ] || bun install --frozen-lockfile >/dev/null 2>&1

    local out
    out="$(bunx vitest run 2>&1 | tail -5)"

    local passed
    passed="$(echo "$out" | grep -oP '(\d+) passed' | grep -oP '^\d+' || echo 0)"

    if [ "$passed" -lt 1800 ]; then
        echo "FLOOR BREACH: vitest passed only $passed tests (floor: 1800)"
        echo "Current baseline: 2099 passed."
        echo "Raw output: $out"
        false
    fi
}

@test "vitest ran at least 90 test files" {
    cd "$dashboard"
    [ -d node_modules ] || bun install --frozen-lockfile >/dev/null 2>&1

    local out
    out="$(bunx vitest run 2>&1 | tail -5)"

    local files
    files="$(echo "$out" | grep -oP '(\d+) passed' | head -1 | grep -oP '^\d+' || echo 0)"
    # The "Test Files" line says "N passed" too — take the first occurrence
    # from the full output which is the file count.
    files="$(bunx vitest run 2>&1 | grep 'Test Files' | grep -oP '(\d+) passed' | grep -oP '^\d+' || echo 0)"

    if [ "$files" -lt 90 ]; then
        echo "FLOOR BREACH: vitest ran only $files test files (floor: 90)"
        echo "Current baseline: 106 files."
        false
    fi
}

# ---------------------------------------------------------------------------
# Go (riskctl)
# ---------------------------------------------------------------------------
# Current: 45 tests across 3 packages.
# Floor: 30.

@test "Go riskctl passed at least 30 tests" {
    cd "$riskctl"
    local out
    out="$(go test ./... -count=1 -buildvcs=false -v 2>&1)"

    local passed
    passed="$(echo "$out" | grep -c '^\-\-\- PASS' || echo 0)"

    if [ "$passed" -lt 30 ]; then
        echo "FLOOR BREACH: Go passed only $passed tests (floor: 30)"
        echo "Current baseline: 45 tests."
        false
    fi
}

@test "Go riskctl reported zero failures" {
    cd "$riskctl"
    local out
    out="$(go test ./... -count=1 -buildvcs=false 2>&1)"
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        echo "Go tests failed (exit $rc)"
        echo "$out" | tail -10
        false
    fi
}

# ---------------------------------------------------------------------------
# bats (d2-signalloom)
# ---------------------------------------------------------------------------
# Current: 234 via make test, 249 standalone.
# Floor: 200.

@test "d2-signalloom bats executed at least 200 tests" {
    local out
    out="$(make -C "$repo_root/d2-signalloom" test 2>&1 | tail -3)"
    local rc=${PIPESTATUS[0]}

    if [ "$rc" -ne 0 ]; then
        echo "make -C d2-signalloom test failed (exit $rc)"
        echo "$out"
        false
    fi

    # Count "ok N" lines in the TAP output from the make run.
    local total
    total="$(make -C "$repo_root/d2-signalloom" test 2>&1 | grep -cE '^ok ')"

    if [ "$total" -lt 200 ]; then
        echo "FLOOR BREACH: bats ran only $total tests (floor: 200)"
        echo "Current baseline: ~234."
        false
    fi
}

# ---------------------------------------------------------------------------
# audit proof
# ---------------------------------------------------------------------------
# Current: 12/12 in 7s.
# Floor: 12 exactly — every case must fire.

@test "audit reintroduction proof fires all 12 cases" {
    local out
    out="$(bash "$repo_root/d2-signalloom/test/audit-guard-reintroduction-proof.sh" 2>&1)"
    local rc=$?

    local red
    red="$(echo "$out" | grep -c 'RED as required')"

    if [ "$rc" -ne 0 ]; then
        echo "proof exited $rc"
        echo "$out" | tail -8
        false
    fi

    if [ "$red" -ne 12 ]; then
        echo "FLOOR BREACH: only $red of 12 proof cases fired"
        echo "$out" | grep -E 'DID NOT FIRE|PATCH FAILED'
        false
    fi
}
