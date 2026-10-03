#!/usr/bin/env bats
#
# Guard against legacy probe name occurrences in tracked files.
#
# @target scripts/check-old-probe-name.sh

bats_require_minimum_version 1.5.0

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	GUARD="${TEST_GUARD_SCRIPT:-$REPO_ROOT/scripts/check-old-probe-name.sh}"

	# Build isolated fixture repository in $BATS_TEST_TMPDIR
	FX="$BATS_TEST_TMPDIR/fixture-repo"
	mkdir -p "$FX/scripts" "$FX/test/fixtures" "$FX/docs"

	# Initialize git repository with committer identity
	git -C "$FX" init -q
	git -C "$FX" config user.name "BATS Test"
	git -C "$FX" config user.email "bats@example.com"
	git -C "$FX" config commit.gpgsign false

	# Copy docs-lint.sh to provide RECORDS regex definition
	cp "$REPO_ROOT/scripts/docs-lint.sh" "$FX/scripts/docs-lint.sh"

	# Create a clean allowlist with an entry that will match
	cat <<'AL' > "$FX/test/fixtures/old-probe-name-allowlist.txt"
# Fixture allowlist
scripts/check-old-probe-name.sh # scanner self-reference
docs/allowed-legacy.md # pre-approved legacy reference
AL

	# Create baseline tracked files
	cat <<'F1' > "$FX/README.md"
# Clean Project
This is a clean project description for testing.
F1

	cat <<'F2' > "$FX/docs/allowed-legacy.md"
# Allowed Doc
This mentions stun-sentinel under explicit allowlist reason.
F2

	cp "$GUARD" "$FX/scripts/check-old-probe-name.sh"
	chmod +x "$FX/scripts/check-old-probe-name.sh"

	git -C "$FX" add .
	git -C "$FX" commit -q -m "chore: baseline fixture"
}

@test "clean fixture repository scans clean (exit 0)" {
	run --separate-stderr "$GUARD" --root "$FX" --allowlist "$FX/test/fixtures/old-probe-name-allowlist.txt"
	[ "$status" -eq 0 ]
	[[ "$output" == "check-old-probe-name: SCANNED CLEAN: "* ]]
}

@test "planted stun-sentinel in a living file exits 1 and names path:line" {
	printf 'legacy probe reference stun-sentinel here\n' >> "$FX/README.md"
	git -C "$FX" add "$FX/README.md"
	git -C "$FX" commit -q -m "test: planted occurrence"

	run --separate-stderr "$GUARD" --root "$FX" --allowlist "$FX/test/fixtures/old-probe-name-allowlist.txt"
	[ "$status" -eq 1 ]
	[[ "$output" == *"README.md:3:"*"stun-sentinel"* ]]
}

@test "planted StunSentinel variant exits 1 and names path:line" {
	printf 'legacy probe reference StunSentinel here\n' >> "$FX/README.md"
	git -C "$FX" add "$FX/README.md"
	git -C "$FX" commit -q -m "test: planted StunSentinel"

	run --separate-stderr "$GUARD" --root "$FX" --allowlist "$FX/test/fixtures/old-probe-name-allowlist.txt"
	[ "$status" -eq 1 ]
	[[ "$output" == *"README.md:3:"*"StunSentinel"* ]]
}

@test "planted STUN_SENTINEL variant exits 1 and names path:line" {
	printf 'legacy probe reference STUN_SENTINEL here\n' >> "$FX/README.md"
	git -C "$FX" add "$FX/README.md"
	git -C "$FX" commit -q -m "test: planted STUN_SENTINEL"

	run --separate-stderr "$GUARD" --root "$FX" --allowlist "$FX/test/fixtures/old-probe-name-allowlist.txt"
	[ "$status" -eq 1 ]
	[[ "$output" == *"README.md:3:"*"STUN_SENTINEL"* ]]
}

@test "planted stun_sentinel variant exits 1 and names path:line" {
	printf 'legacy probe reference stun_sentinel here\n' >> "$FX/README.md"
	git -C "$FX" add "$FX/README.md"
	git -C "$FX" commit -q -m "test: planted stun_sentinel"

	run --separate-stderr "$GUARD" --root "$FX" --allowlist "$FX/test/fixtures/old-probe-name-allowlist.txt"
	[ "$status" -eq 1 ]
	[[ "$output" == *"README.md:3:"*"stun_sentinel"* ]]
}

@test "planted stun sentinel space variant exits 1 and names path:line" {
	printf 'legacy probe reference stun sentinel here\n' >> "$FX/README.md"
	git -C "$FX" add "$FX/README.md"
	git -C "$FX" commit -q -m "test: planted stun sentinel"

	run --separate-stderr "$GUARD" --root "$FX" --allowlist "$FX/test/fixtures/old-probe-name-allowlist.txt"
	[ "$status" -eq 1 ]
	[[ "$output" == *"README.md:3:"*"stun sentinel"* ]]
}

@test "planted file name containing old probe name exits 1" {
	touch "$FX/stun-sentinel-daemon.yaml"
	git -C "$FX" add "$FX/stun-sentinel-daemon.yaml"
	git -C "$FX" commit -q -m "test: planted file name"

	run --separate-stderr "$GUARD" --root "$FX" --allowlist "$FX/test/fixtures/old-probe-name-allowlist.txt"
	[ "$status" -eq 1 ]
	[[ "$output" == *"stun-sentinel-daemon.yaml:1:"* ]]
}

@test "planted occurrence in a decision record path (RECORDS) exits 0" {
	mkdir -p "$FX/ci-evidence"
	printf 'audit record mentions stun-sentinel from past run\n' > "$FX/ci-evidence/audit.json"
	git -C "$FX" add "$FX/ci-evidence/audit.json"
	git -C "$FX" commit -q -m "test: planted in decision record"

	run --separate-stderr "$GUARD" --root "$FX" --allowlist "$FX/test/fixtures/old-probe-name-allowlist.txt"
	[ "$status" -eq 0 ]
	[[ "$output" == "check-old-probe-name: SCANNED CLEAN: "* ]]
}

@test "planted occurrence in an allow-listed path exits 0" {
	printf 'another line with stun-sentinel\n' >> "$FX/docs/allowed-legacy.md"
	git -C "$FX" add "$FX/docs/allowed-legacy.md"
	git -C "$FX" commit -q -m "test: planted in allowlisted path"

	run --separate-stderr "$GUARD" --root "$FX" --allowlist "$FX/test/fixtures/old-probe-name-allowlist.txt"
	[ "$status" -eq 0 ]
	[[ "$output" == "check-old-probe-name: SCANNED CLEAN: "* ]]
}

@test "planted occurrence in an untracked file exits 0" {
	printf 'untracked scratch note with stun-sentinel\n' > "$FX/scratch-note.txt"

	run --separate-stderr "$GUARD" --root "$FX" --allowlist "$FX/test/fixtures/old-probe-name-allowlist.txt"
	[ "$status" -eq 0 ]
	[[ "$output" == "check-old-probe-name: SCANNED CLEAN: "* ]]
}

@test "allowlist entry that suppresses nothing exits 1 (stale pre-approval)" {
	cat <<'AL' > "$FX/test/fixtures/old-probe-name-allowlist.txt"
# Fixture allowlist with a stale unused entry
scripts/check-old-probe-name.sh # scanner self-reference
docs/allowed-legacy.md # pre-approved legacy reference
docs/nonexistent-feature.md # stale entry suppressing nothing
AL
	git -C "$FX" add "$FX/test/fixtures/old-probe-name-allowlist.txt"
	git -C "$FX" commit -q -m "test: added stale allowlist entry"

	run --separate-stderr "$GUARD" --root "$FX" --allowlist "$FX/test/fixtures/old-probe-name-allowlist.txt"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"entry suppresses nothing (docs/nonexistent-feature.md)"* ]]
}

@test "empty git repository exits 2" {
	EMPTY_REPO="$BATS_TEST_TMPDIR/empty-repo"
	mkdir -p "$EMPTY_REPO"
	git -C "$EMPTY_REPO" init -q

	run --separate-stderr "$GUARD" --root "$EMPTY_REPO" --allowlist "$FX/test/fixtures/old-probe-name-allowlist.txt"
	[ "$status" -eq 2 ]
	[[ "$stderr" == "CANNOT SCAN: zero tracked files in "* ]]
}

@test "non-git directory exits 2" {
	NON_GIT="$BATS_TEST_TMPDIR/non-git-dir"
	mkdir -p "$NON_GIT"
	touch "$NON_GIT/file.txt"

	run --separate-stderr "$GUARD" --root "$NON_GIT" --allowlist "$FX/test/fixtures/old-probe-name-allowlist.txt"
	[ "$status" -eq 2 ]
	[[ "$stderr" == "CANNOT SCAN: "* ]]
}

@test "missing allowlist file exits 2" {
	run --separate-stderr "$GUARD" --root "$FX" --allowlist "$FX/nonexistent-allowlist.txt"
	[ "$status" -eq 2 ]
	[[ "$stderr" == "CANNOT SCAN: allowlist file "* ]]
}

@test "real repository is scanned clean (exit 0)" {
	run --separate-stderr "$GUARD" --root "$REPO_ROOT"
	[ "$status" -eq 0 ]
	[[ "$output" == "check-old-probe-name: SCANNED CLEAN: "* ]]
}
