#!/usr/bin/env bats
#
# scripts/verify-final-eap-attestation.sh aggregates the Phase 6 gates. Here
# every gate is a stub in a synthetic REPO_ROOT, so what is tested is the
# aggregation: a PASS verdict only when every gate ran and passed.
#
# @target scripts/verify-final-eap-attestation.sh

bats_require_minimum_version 1.5.0

setup() {
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	att="$root/scripts/verify-final-eap-attestation.sh"
	export REPO_ROOT="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$REPO_ROOT/scripts" "$REPO_ROOT/test"
	for s in verify-teardown-prereqs super-test-adversarial verify-mutation-gate; do
		printf '#!/usr/bin/env bash\nexit "${FAIL_%s:-0}"\n' "${s//-/_}" >"$REPO_ROOT/scripts/$s.sh"
	done
	for b in e2e-scratch-coldstart-replay evidence-bundle-integrity final-mission-governor; do
		printf '@test "stub" { true; }\n' >"$REPO_ROOT/test/$b.bats"
	done
	export KEYS_DIR="$BATS_TEST_TMPDIR/keys"
	mkdir -p "$KEYS_DIR" && touch "$KEYS_DIR/cosign.key" "$KEYS_DIR/cosign.pub" "$KEYS_DIR/witness.pem"
}

@test "every gate passes: exit 0 and PASS 7/7" {
	run bash "$att"
	[ "$status" -eq 0 ]
	[[ "$output" == *"FINAL ATTESTATION VERDICT: PASS (7/7 steps verified)"* ]]
}

@test "a failing gate stops the attestation with exit 1 and no PASS verdict" {
	FAIL_super_test_adversarial=1 run --separate-stderr bash "$att"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"[Step 2] FAIL"* ]]
	[[ "$output" != *"VERDICT: PASS"* ]]
}

@test "a missing governor suite fails the attestation instead of being skipped" {
	rm "$REPO_ROOT/test/final-mission-governor.bats"
	run bash "$att"
	[ "$status" -eq 1 ]
	[[ "$output" != *"VERDICT: PASS"* ]]
}

@test "signing keys are found through KEYS_DIR, as every other script finds them" {
	[ ! -e "$REPO_ROOT/.keys" ]
	run bash "$att"
	[ "$status" -eq 0 ]
	rm "$KEYS_DIR/witness.pem"
	run bash "$att"
	[ "$status" -eq 1 ]
}
