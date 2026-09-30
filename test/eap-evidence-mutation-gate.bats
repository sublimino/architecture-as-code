#!/usr/bin/env bats
#
# scripts/verify-mutation-gate.sh proves the evidence defences are not vacuous:
# a control must pass, and each mutation must fail for its own reason. A gate
# that only greps fixtures, or that counts any non-zero exit as proof, is what
# this suite exists to catch.
#
# @target scripts/verify-mutation-gate.sh

setup() {
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	gate="$root/scripts/verify-mutation-gate.sh"
	stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$BATS_TEST_TMPDIR/$1"; chmod +x "$BATS_TEST_TMPDIR/$1"; }
}

@test "against the real packager and verifier: control passes and 4/4 mutations are proven" {
	run bash "$gate" --check-all
	[ "$status" -eq 0 ]
	[[ "$output" == *"CONTROL: untampered evidence packages and verifies"* ]]
	[[ "$output" == *"MUTATION GATE: 4/4 mutations proven"* ]]
}

@test "a verifier that rejects everything fails the control, so nothing is proven" {
	stub verify 'echo "VERDICT: FAIL"; exit 1'
	MUTATION_GATE_VERIFY="$BATS_TEST_TMPDIR/verify" run bash "$gate" --check-all
	[ "$status" -eq 1 ]
	[[ "$output" == *"CONTROL FAILED"* ]]
	[[ "$output" != *"MUTATION PROVEN"* ]]
}

@test "a verifier that accepts everything leaves the tamper mutation void" {
	stub verify 'echo "VERDICT: PASS"; exit 0'
	MUTATION_GATE_VERIFY="$BATS_TEST_TMPDIR/verify" run bash "$gate" --check-all
	[ "$status" -eq 1 ]
	[[ "$output" == *"MUTATION VOID [Tampered artifact]"* ]]
}

@test "a refusal for the wrong reason does not count as proof" {
	# Signs pristine evidence, refuses everything else with an unrelated message.
	stub pack 'for a; do d="$a"; done
cmp -s "$d/step3-provocation-act.log" "'"$root"'/test/fixtures/eap-evidence/step3-provocation-act.log" &&
cmp -s "$d/step5-cgroup-freeze.txt" "'"$root"'/test/fixtures/eap-evidence/step5-cgroup-freeze.txt" &&
exec "'"$root"'/scripts/package-eap-evidence.sh" "$@"
echo "disk full" >&2; exit 1'
	MUTATION_GATE_PACKAGE="$BATS_TEST_TMPDIR/pack" run bash "$gate" --check-all
	[ "$status" -eq 1 ]
	[[ "$output" == *"MUTATION VOID [Legacy tenant vector]"* ]]
	[[ "$output" == *"MUTATION VOID [Thawed pod]"* ]]
}

@test "the gate never writes into the repository" {
	before="$(git -C "$root" status --porcelain)"
	run bash "$gate" --check-all
	[ "$(git -C "$root" status --porcelain)" = "$before" ]
}
