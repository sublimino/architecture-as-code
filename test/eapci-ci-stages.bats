#!/usr/bin/env bats
# test/eapci-ci-stages.bats
#
# Verification tests for EAPCI-P1-3:
#   - DEMO_ENV validation against ^(demo|ci)-[1-9][0-9]*$ (exit 2 on failure)
#   - DEMO_LIST_STAGES=1 listing mode (ci lists 6 stages in order, demo lists none)
#   - CI execution of 6 EAP stages in exact sequence after deployed-staleness
#   - Demo lane isolation (none of the 6 EAP stages execute)
#   - Named stage failure recording in stages.json and summary.json
#   - Stage 4 Kusari live TAP skip guard (fails on # skip)
#   - Removal of test/tetragon-telemetry-stream.bats from both pipelines

setup() {
	repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	script="$repo/scripts/gcp-tf/demo-pipeline.sh"
	vm_pipeline="$repo/scripts/ci/vm-pipeline.sh"
	makefile="$repo/Makefile"
	fixtures="$repo/test/fixtures/gcp-demo-pipeline"

	[ -f "$script" ]
	[ -f "$vm_pipeline" ]
	[ -f "$makefile" ]
	[ -d "$fixtures" ]

	export HOME="$BATS_TEST_TMPDIR/home"
	stubdir="$HOME/.local/bin"
	mkdir -p "$stubdir"

	local n
	for n in make kubectl bats bun bunx uv go node npx sudo curl nc sleep git; do
		[ "$n" = git ] && continue
		cp "$fixtures/stub-cmd" "$stubdir/$n"
	done
	cp "$fixtures/stub-supervise-port-forward" "$stubdir/supervise-port-forward"
	chmod +x "$stubdir"/*

	PATH="$stubdir:$PATH"
	export PATH

	LOG="$BATS_TEST_TMPDIR/calls.log"
	: >"$LOG"
	export STUB_CALL_LOG="$LOG"

	work="$BATS_TEST_TMPDIR/work"
	reports="$BATS_TEST_TMPDIR/reports"
	mkdir -p "$reports"
	make_fake_repo "$work"

	# Clear inherited environment variables
	local _inherited
	for _inherited in $(compgen -v | grep -E '^(DEMO_|GCP_TF_)' || true); do
		unset "$_inherited"
	done

	export DEMO_WORK_DIR="$work"
	export DEMO_REPORT_DIR="$reports"
	export DEMO_PIPELINE_LOG="$BATS_TEST_TMPDIR/pipeline.log"
	export DEMO_STAGE_TIMEOUT_SECONDS=30
	export DEMO_CHROME_BIN=/bin/true
	export DEMO_SUPERVISE_BIN="$stubdir/supervise-port-forward"
	export DEMO_PF_STATE_DIR="$BATS_TEST_TMPDIR/pf-state"
	export DEMO_CONVERT_BIN="$BATS_TEST_TMPDIR/no-such-converter"
}

make_fake_repo() {
	local root="$1"
	mkdir -p "$root/scripts/ci" \
		"$root/test/acceptance/node_modules/@playwright" \
		"$root/d2-signalloom/test" \
		"$root/d2-signalloom/apps/dashboard-signalloom" \
		"$root/d2-signalloom/apps/fe-signalloom/src" \
		"$root/tools/demo-console"

	local f
	for f in scripts/ci/install-ci-tools.sh \
		scripts/setup.sh \
		scripts/acceptance-test.sh \
		scripts/check-flux-substitution.sh \
		scripts/check-vacuous-assertions.sh \
		scripts/dual-cluster-up.sh \
		scripts/remote-tenant-lab.sh \
		scripts/slaws-acceptance.sh \
		scripts/ci/resolve-tailnet-origin.sh \
		scripts/ci/user-surface-gate.sh \
		test/guard-falsification-proof.sh \
		d2-signalloom/test/audit-guard-reintroduction-proof.sh \
		d2-signalloom/test/seam-guard-mutation-proof.sh; do
		cat >"$root/$f" <<-STUB
			#!/usr/bin/env bash
			printf '%s %s\n' "$f" "\$*" >>"\${STUB_CALL_LOG:-/dev/null}"
			exit 0
		STUB
		chmod +x "$root/$f"
	done
}

first_line() {
	local n
	n="$(grep -nE -m1 -- "$1" "$LOG" | cut -d: -f1)"
	if [ -z "$n" ]; then
		echo "pattern never appeared in the call log: $1" >&2
		echo "--- call log ---" >&2
		cat "$LOG" >&2
		return 1
	fi
	printf '%s' "$n"
}

assert_before() {
	local a b first second
	first="$(first_line "$1")" || return 1
	second="$(first_line "$2")" || return 1
	a="$first"; b="$second"
	if [ "$a" -ge "$b" ]; then
		echo "expected [$1] (line $a) to come BEFORE [$2] (line $b)" >&2
		cat "$LOG" >&2
		return 1
	fi
}

assert_absent() {
	[ -f "$LOG" ]
	run grep -nE -- "$1" "$LOG"
	if [ "$status" -ne 1 ]; then
		echo "expected [$1] to be ABSENT from the call log; grep status=$status" >&2
		echo "$output" >&2
		return 1
	fi
}

# ═══ DEMO_ENV Validation Tests ═══════════════════════════════════════════════

@test "EAPCI DEMO_ENV empty or unset exits with code 2" {
	unset DEMO_ENV
	run bash "$script"
	[ "$status" -eq 2 ]
	[[ "$output" == *"ERROR: DEMO_ENV is unset or empty"* ]]

	export DEMO_ENV=""
	run bash "$script"
	[ "$status" -eq 2 ]
	[[ "$output" == *"ERROR: DEMO_ENV is unset or empty"* ]]
}

@test "EAPCI DEMO_ENV malformed values exit with code 2" {
	local bad_env
	for bad_env in staging-1 dev-1 ci-0 demo-0 ci- demo- prod-1 demo_1 CI-1; do
		export DEMO_ENV="$bad_env"
		run bash "$script"
		[ "$status" -eq 2 ]
		[[ "$output" == *"ERROR: DEMO_ENV='${bad_env}' is malformed"* ]]
	done
}

@test "EAPCI DEMO_ENV valid values are accepted" {
	local good_env
	for good_env in demo-1 demo-2 ci-1 ci-2 demo-10 ci-99; do
		export DEMO_ENV="$good_env"
		export DEMO_LIST_STAGES=1
		run bash "$script"
		[ "$status" -eq 0 ]
	done
}

# ═══ DEMO_LIST_STAGES=1 Listing Mode ═════════════════════════════════════════

@test "EAPCI DEMO_LIST_STAGES=1 lists the six EAP stages in order on CI lanes" {
	export DEMO_ENV="ci-1"
	export DEMO_LIST_STAGES=1
	run bash "$script"
	[ "$status" -eq 0 ]

	# Assert all 6 stages appear in the listed output in exact order
	local line1 line2 line3 line4 line5 line6
	line1="$(grep -n 'dual-cluster-up\.sh' <<< "$output" | cut -d: -f1)"
	line2="$(grep -n 'remote-tenant-lab\.sh' <<< "$output" | cut -d: -f1)"
	line3="$(grep -n 'test-kusari-e2e' <<< "$output" | cut -d: -f1)"
	line4="$(grep -n 'kusari-e2e-live\.bats' <<< "$output" | cut -d: -f1)"
	line5="$(grep -n 'slaws-acceptance\.sh' <<< "$output" | cut -d: -f1)"
	line6="$(grep -n 'test-eap-offline' <<< "$output" | cut -d: -f1)"

	[ -n "$line1" ]
	[ -n "$line2" ]
	[ -n "$line3" ]
	[ -n "$line4" ]
	[ -n "$line5" ]
	[ -n "$line6" ]

	[ "$line1" -lt "$line2" ]
	[ "$line2" -lt "$line3" ]
	[ "$line3" -lt "$line4" ]
	[ "$line4" -lt "$line5" ]
	[ "$line5" -lt "$line6" ]
}

@test "EAPCI DEMO_LIST_STAGES=1 lists no EAP stages on demo lanes" {
	local demo_env
	for demo_env in demo-1 demo-2; do
		export DEMO_ENV="$demo_env"
		export DEMO_LIST_STAGES=1
		run bash "$script"
		[ "$status" -eq 0 ]
		[[ "$output" != *"dual-cluster-up"* ]]
		[[ "$output" != *"remote-tenant-lab"* ]]
		[[ "$output" != *"test-kusari-e2e"* ]]
		[[ "$output" != *"kusari-e2e-live"* ]]
		[[ "$output" != *"slaws-acceptance"* ]]
		[[ "$output" != *"test-eap-offline"* ]]
	done
}

# ═══ Stage Sequencing & Lane Execution ═══════════════════════════════════════

@test "EAPCI CI lane executes all 6 EAP stages in order after deployed-staleness" {
	export DEMO_ENV="ci-1"
	run bash "$script"
	[ "$status" -eq 0 ]

	# 1. deployed-staleness comes before dual-cluster-up
	assert_before '^make check-deployed-staleness$' 'scripts/dual-cluster-up\.sh'

	# 2. dual-cluster-up -> remote-tenant-lab -> make test-kusari-e2e -> kusari live -> slaws -> eap offline
	assert_before 'scripts/dual-cluster-up\.sh' 'scripts/remote-tenant-lab\.sh'
	assert_before 'scripts/remote-tenant-lab\.sh' '^make test-kusari-e2e$'
	assert_before '^make test-kusari-e2e$' 'bats --tap test/kusari-e2e-live\.bats'
	assert_before 'bats --tap test/kusari-e2e-live\.bats' 'scripts/slaws-acceptance\.sh'
	assert_before 'scripts/slaws-acceptance\.sh' '^make test-eap-offline$'

	# 3. EAP offline comes before flux substitution check
	assert_before '^make test-eap-offline$' 'check-flux-substitution\.sh'
}

@test "EAPCI Demo lanes execute NONE of the 6 EAP stages" {
	local demo_env
	for demo_env in demo-1 demo-2; do
		: >"$LOG"
		export DEMO_ENV="$demo_env"
		run bash "$script"
		[ "$status" -eq 0 ]

		assert_absent 'dual-cluster-up\.sh'
		assert_absent 'remote-tenant-lab\.sh'
		assert_absent 'test-kusari-e2e'
		assert_absent 'kusari-e2e-live\.bats'
		assert_absent 'slaws-acceptance\.sh'
		assert_absent 'test-eap-offline'
	done
}

# ═══ Named Failure and Skip Handling ══════════════════════════════════════════

@test "EAPCI failing stage N leaves non-zero exit and stages.json naming N" {
	export DEMO_ENV="ci-1"
	# Stub remote-tenant-lab.sh to exit 3
	cat >"$work/scripts/remote-tenant-lab.sh" <<-STUB
		#!/usr/bin/env bash
		printf '%s %s\n' "scripts/remote-tenant-lab.sh" "\$*" >>"\${STUB_CALL_LOG:-/dev/null}"
		exit 3
	STUB
	chmod +x "$work/scripts/remote-tenant-lab.sh"

	run bash "$script"
	[ "$status" -ne 0 ]

	# stages.json must record the named failure and exit code 3
	[ -f "$reports/stages.json" ]
	run grep -F '"name":"EAP remote-tenant lab"' "$reports/stages.json"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"status":"fail"'* ]]
	[[ "$output" == *'"exit_code":3'* ]]

	# The other 5 EAP stages still ran
	assert_before 'scripts/dual-cluster-up\.sh' 'scripts/remote-tenant-lab\.sh'
	assert_before 'scripts/remote-tenant-lab\.sh' '^make test-kusari-e2e$'
	assert_before '^make test-kusari-e2e$' 'bats --tap test/kusari-e2e-live\.bats'
	assert_before 'bats --tap test/kusari-e2e-live\.bats' 'scripts/slaws-acceptance\.sh'
	assert_before 'scripts/slaws-acceptance\.sh' '^make test-eap-offline$'
}

@test "EAPCI stage 4 Kusari live TAP skip guard fails on skipped test in TAP" {
	export DEMO_ENV="ci-1"
	# Override bats stub to output a TAP skip when kusari-e2e-live.bats is run
	cat >"$stubdir/bats" <<-'STUB'
		#!/usr/bin/env bash
		printf 'bats %s\n' "$*" >>"${STUB_CALL_LOG:-/dev/null}"
		if [[ "$*" == *"test/kusari-e2e-live.bats"* ]]; then
			echo "1..1"
			echo "ok 1 - kusari live test # skip KUSARI_LIVE not set"
			exit 0
		fi
		echo "1..1"
		echo "ok 1 - test passed"
		exit 0
	STUB
	chmod +x "$stubdir/bats"

	run bash "$script"
	[ "$status" -ne 0 ]

	[ -f "$reports/stages.json" ]
	run grep -F '"name":"Kusari live tier (KUSARI_LIVE=1)"' "$reports/stages.json"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"status":"fail"'* ]]

	[ -f "$reports/stage6eap4-kusari-live.tap" ]
	run grep -F "skipping is not permitted in CI" "$reports/stage6eap4-kusari-live.tap"
	[ "$status" -eq 0 ]
}

# ═══ Tetragon Reference Removal ═══════════════════════════════════════════════

@test "EAPCI neither pipeline file references tetragon suites" {
	run grep -i "tetragon" "$script"
	[ "$status" -eq 1 ]

	run grep -i "tetragon" "$vm_pipeline"
	[ "$status" -eq 1 ]
}

@test "EAPCI test/tetragon-telemetry-stream.bats file still exists on disk" {
	[ -f "$repo/test/tetragon-telemetry-stream.bats" ]
}
