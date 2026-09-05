#!/usr/bin/env bats

setup() {
	repo="$BATS_TEST_DIRNAME/.."
	tmp="$(mktemp -d)"
}

teardown() {
	rm -rf "$tmp"
}

@test "attested-test depends on signing-keys rather than workload-key" {
	run make -C "$repo" -n attested-test ATTESTED_TEST_SOURCE=segments
	[ "$status" -eq 0 ]
	[[ "$output" == *"ATTESTED_TEST_SOURCE=segments ./scripts/attested-test.sh"* ]]
	[[ "$output" != *"workload-key"* ]]
	run grep -F 'exec ./scripts/segment-attestation-proof.sh' "$repo/scripts/attested-test.sh"
	[ "$status" -eq 0 ]
}

@test "attested-test preserves its explicitly selected audit mode" {
	run make -C "$repo" -n attested-test ATTESTED_TEST_SOURCE=audit
	[ "$status" -eq 0 ]
	[[ "$output" == *"ATTESTED_TEST_SOURCE=audit ./scripts/attested-test.sh"* ]]
	run grep -F 'SOURCE="${ATTESTED_TEST_SOURCE:-audit}"' "$repo/scripts/attested-test.sh"
	[ "$status" -eq 0 ]
}

@test "audit anchor commands forward root ARGS to the Python CLI" {
	for target in audit-anchor-checkpoint audit-anchor-verify audit-anchor-show; do
		run make -C "$repo" -n "$target" ARGS="--source segments"
		[ "$status" -eq 0 ]
		[[ "$output" == *"--source segments"* ]]
	done
}

@test "segment proof gate requires retained Go integration evidence" {
	run grep -F 'SIGNAL_SEGMENT_PROOF_DIR' "$repo/scripts/segment-attestation-proof.sh"
	[ "$status" -eq 0 ]
	run grep -F 'TestGoEvidenceAcceptedThenMutationRejectedByPythonVerifier' "$repo/scripts/segment-attestation-proof.sh"
	[ "$status" -eq 0 ]
	run grep -F 'segments.jsonl' "$repo/scripts/segment-attestation-proof.sh"
	[ "$status" -eq 0 ]
}

@test "segment proof validates intact diverged and restored machine JSON" {
	proof="$repo/scripts/segment-attestation-proof.sh"
	for expression in \
		'.status == "intact"' \
		'.status == "diverged"' \
		'unanchored_row_count == 0'; do
		run grep -F "$expression" "$proof"
		[ "$status" -eq 0 ]
	done
	run grep -F 'verify_status' "$proof"
	[ "$status" -eq 0 ]
	run grep -F ' -eq 2 ' "$proof"
	[ "$status" -eq 0 ]
}

@test "configured Archivista is strict and never silently becomes file evidence" {
	run grep -F 'AUDIT_ANCHOR_REQUIRE_LOG=1' "$repo/scripts/segment-attestation-proof.sh"
	[ "$status" -eq 0 ]
	run grep -F -- '--require-archivista' "$repo/scripts/segment-attestation-proof.sh"
	[ "$status" -eq 0 ]
}

@test "signing-keys creates a protected segment signer policy without cluster keys" {
	run make -C "$repo" signing-keys KEYS_DIR="$tmp/keys"
	[ "$status" -eq 0 ]
	[ -s "$tmp/keys/segment-signing-policy.json" ]
	run jq -e '.schema_version == "signalloom.segment.signing-policy/v1" and (.expected_key_ids | length) == 1' "$tmp/keys/segment-signing-policy.json"
	[ "$status" -eq 0 ]
	[[ "$output" != *"workload-key"* ]]
}

@test "segment proof pins verifier identity from protected signing policy" {
	run grep -F 'segment-signing-policy.json' "$repo/scripts/segment-attestation-proof.sh"
	[ "$status" -eq 0 ]
	run grep -F -- '--expected-key-id "${EXPECTED_KEY_ID}"' "$repo/scripts/segment-attestation-proof.sh"
	[ "$status" -eq 0 ]
}

@test "root segment verify forwards the protected expected key identity" {
	run make -C "$repo" -n audit-anchor-verify ARGS="--source segments"
	[ "$status" -eq 0 ]
	[[ "$output" == *"segment-signing-policy.json"* ]]
	[[ "$output" == *"--expected-key-id"* ]]
}

@test "signing-keys refuses a public key rejected by protected policy" {
	run make -C "$repo" signing-keys KEYS_DIR="$tmp/keys"
	[ "$status" -eq 0 ]
	jq '.expected_key_ids = ["0000000000000000000000000000000000000000000000000000000000000000"]' \
		"$tmp/keys/segment-signing-policy.json" >"$tmp/policy" \
		&& mv "$tmp/policy" "$tmp/keys/segment-signing-policy.json"
	run make -C "$repo" signing-keys KEYS_DIR="$tmp/keys"
	[ "$status" -ne 0 ]
	[[ "$output" == *"protected segment signing policy rejects"* ]]
}

@test "combined audit segment verification pins protected signer identity" {
	run grep -F 'segment-signing-policy.json' "$repo/scripts/audit-anchor-tamper-demo.sh"
	[ "$status" -eq 0 ]
	run grep -F -- '--expected-key-id "${EXPECTED_KEY_ID}"' "$repo/scripts/audit-anchor-tamper-demo.sh"
	[ "$status" -eq 0 ]
	run grep -F -- '--source both' "$repo/scripts/audit-anchor-tamper-demo.sh"
	[ "$status" -eq 0 ]
}

@test "audit tamper anchor pins protected signer identity" {
	run grep -A 10 '^anchor()' "$repo/scripts/audit-anchor-tamper-demo.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *'--expected-key-id "${EXPECTED_KEY_ID}"'* ]]
}

@test "strict unreachable Archivista checkpoint exits nonzero" {
	run make -C "$repo" signing-keys KEYS_DIR="$tmp/keys"
	[ "$status" -eq 0 ]
	run env \
		ARCHIVISTA_URL=http://127.0.0.1:1 \
		DATABASE_URL=postgresql://unused:unused@127.0.0.1:1/unused \
		make -C "$repo" audit-anchor-checkpoint \
		KEYS_DIR="$tmp/keys"
	[ "$status" -ne 0 ]
	[[ "$output" == *"strict Archivista mode configured"* ]]
}

@test "owned shell scripts parse as bash" {
	run bash -n "$repo/scripts/attested-test.sh" "$repo/scripts/audit-anchor-tamper-demo.sh" "$repo/scripts/segment-attestation-proof.sh"
	[ "$status" -eq 0 ]
}
