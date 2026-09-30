#!/usr/bin/env bats
#
# scripts/super-test-adversarial.sh may only report a probe PASS when that
# probe ran and the defence it names held. Offline probes drive the real
# packager and verifier; live probes are injected commands and are NOT_RUN
# (verdict FAIL) when absent, never assumed.
#
# @target scripts/super-test-adversarial.sh

bats_require_minimum_version 1.5.0

setup() {
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	st="$root/scripts/super-test-adversarial.sh"
	res="$BATS_TEST_TMPDIR/results.json"
	unset SUPERTEST_ADV1_CMD SUPERTEST_ADV4_CMD SUPERTEST_VERIFY SUPERTEST_PACKAGE
}

probe() { jq -r --arg id "$1" '.probes[] | select(.id == $id) | .status' "$res"; }

@test "offline: evidence-contract probes pass, live probes are NOT_RUN and the verdict is FAIL" {
	run bash "$st" --run-all --out "$res"
	[ "$status" -eq 1 ]
	[ "$(probe ADV-2)" = PASS ]
	[ "$(probe ADV-3)" = PASS ]
	[ "$(probe ADV-5)" = PASS ]
	[ "$(probe ADV-1)" = NOT_RUN ]
	[ "$(probe ADV-4)" = NOT_RUN ]
	[ "$(jq -r '"\(.verdict) \(.total_probes) \(.failed_probes)"' "$res")" = "FAIL 5 2" ]
}

@test "every probe run and holding gives PASS, exit 0" {
	SUPERTEST_ADV1_CMD=true SUPERTEST_ADV4_CMD=true run bash "$st" --out "$res"
	[ "$status" -eq 0 ]
	[ "$(jq -r .verdict "$res")" = PASS ]
	[[ "$output" == *"VERDICT: PASS (5/5 probes passed)"* ]]
}

@test "a live probe command that fails is recorded FAIL with its output" {
	SUPERTEST_ADV1_CMD='echo "HTTP 200 for forged token"; exit 1' SUPERTEST_ADV4_CMD=true \
		run --separate-stderr bash "$st" --out "$res"
	[ "$status" -eq 1 ]
	[ "$(probe ADV-1)" = FAIL ]
	[ "$(jq -r '.probes[] | select(.id == "ADV-1") | .actual' "$res")" = "HTTP 200 for forged token" ]
	[[ "$stderr" == *"FAIL [ADV-1]"* ]]
}

@test "a verifier that accepts everything fails the tamper probe" {
	printf '#!/usr/bin/env bash\necho "VERDICT: PASS"\n' >"$BATS_TEST_TMPDIR/verify"
	chmod +x "$BATS_TEST_TMPDIR/verify"
	SUPERTEST_VERIFY="$BATS_TEST_TMPDIR/verify" run bash "$st" --out "$res"
	[ "$(probe ADV-5)" = FAIL ]
}

@test "a verifier that rejects everything fails the tamper probe (its control must pass)" {
	printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/verify"
	chmod +x "$BATS_TEST_TMPDIR/verify"
	SUPERTEST_VERIFY="$BATS_TEST_TMPDIR/verify" run bash "$st" --out "$res"
	[ "$(probe ADV-5)" = FAIL ]
}

@test "a packager that signs anything fails the legacy-tenant and flatline probes" {
	printf '#!/usr/bin/env bash\nexit 0\n' >"$BATS_TEST_TMPDIR/pack"
	chmod +x "$BATS_TEST_TMPDIR/pack"
	SUPERTEST_PACKAGE="$BATS_TEST_TMPDIR/pack" run bash "$st" --out "$res"
	[ "$(probe ADV-2)" = FAIL ]
	[ "$(probe ADV-3)" = FAIL ]
}

@test "the results file is only written where --out says, never into the repo" {
	before="$(git -C "$root" status --porcelain)"
	run bash "$st" --out "$res"
	[ -s "$res" ]
	[ "$(git -C "$root" status --porcelain)" = "$before" ]
}

@test "unknown argument is a usage error (exit 2)" {
	run bash "$st" --bogus
	[ "$status" -eq 2 ]
}
