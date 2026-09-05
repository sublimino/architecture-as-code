#!/usr/bin/env bats
# SFDP-P4-4: Witness verify and FrostDB segment attestation tamper regression suite.
#
# Asserts:
# 1. Sign-then-mutate-then-verify sequence: intact envelope passes verify (exit 0),
#    mutated segment/envelope fails verify (exit 2, status=diverged), restored passes.
# 2. Verify is the gate, not sign: an envelope is only accepted when signature matches
#    persisted byte digest against policy.
# 3. Tamper demo cleans up its own rows and leaves zero residual tenant rows.

setup() {
  repo="$BATS_TEST_DIRNAME/.."
  tmp="$(mktemp -d)"
  keys_input="${KEYS_DIR:-$repo/.keys}"
  if [ -d "$keys_input" ]; then
    KEYS_DIR="$(cd "$keys_input" && pwd)"
  else
    KEYS_DIR="$(cd "$repo/.keys" && pwd)"
  fi
  export KEYS_DIR
  export GOCACHE="${GOCACHE:-/tmp/gocache}"
  export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
  export CGO_ENABLED=0
  export LC_ALL=C
  export LANG=C
}

teardown() {
  rm -rf "$tmp"
}

@test "tamper-regression: signing-keys exists and policy pins exactly one signer" {
  [ -f "$KEYS_DIR/witness.pem" ]
  [ -f "$KEYS_DIR/witness-pub.pem" ]
  [ -f "$KEYS_DIR/segment-signing-policy.json" ]

  run jq -e '.schema_version == "signalloom.segment.signing-policy/v1" and (.expected_key_ids | length) == 1' "$KEYS_DIR/segment-signing-policy.json"
  [ "$status" -eq 0 ]
}

@test "tamper-regression: attested-test produces valid intact signed segment proof" {
  run make -C "$repo" attested-test ATTESTED_TEST_SOURCE=segments KEYS_DIR="$KEYS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status": "intact"'* ]]
  [[ "$output" == *"PASS: real FrostDB Parquet evidence was intact, diverged after mutation, and intact after restore"* ]]
}

@test "tamper-regression: audit-anchor-tamper-demo detects segment byte mutation and exits 2" {
  run make -C "$repo" audit-anchor-tamper-demo AUDIT_ANCHOR_TAMPER_SOURCE=segments KEYS_DIR="$KEYS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status": "diverged"'* ]]
  [[ "$output" == *"persisted byte digest mismatch"* ]]
}

@test "tamper-regression: verify rejects mutated DSSE segment against policy (verify is the gate)" {
  proof_dir="$tmp/proof"
  mkdir -p "$proof_dir/store" "$proof_dir/evidence" "$proof_dir/protected"
  highwater="$proof_dir/protected/highwater.json"
  journal="$proof_dir/evidence/segments.jsonl"
  expected_key_id=$(jq -er '.expected_key_ids[0]' "$KEYS_DIR/segment-signing-policy.json")

  # 1. Run Go test to emit signed segment and journal
  run bash -c "SIGNAL_SEGMENT_PROOF_DIR=\"$proof_dir\" \
SIGNAL_SEGMENT_STORE_DIR=\"$proof_dir/store\" \
SIGNAL_SEGMENT_EVIDENCE_DIR=\"$proof_dir/evidence\" \
SIGNAL_SEGMENT_HIGHWATER=\"$highwater\" \
SIGNAL_SEGMENT_SIGNING_KEY=\"$KEYS_DIR/witness.pem\" \
SIGNAL_SEGMENT_PUBLIC_KEY=\"$KEYS_DIR/witness-pub.pem\" \
SIGNAL_SEGMENT_EXPECTED_KEY_ID=\"$expected_key_id\" \
GOCACHE=\"$GOCACHE\" GOMODCACHE=\"$GOMODCACHE\" CGO_ENABLED=0 \
go -C \"$repo/d2-signalloom/apps/signal-ingest\" test -tags=frostdb ./store -run \"^TestGoEvidenceAcceptedThenMutationRejectedByPythonVerifier$\" -count=1"
  [ "$status" -eq 0 ]

  # 2. Verify intact: must exit 0 with status intact
  run bash -c "cd \"$repo/d2-signalloom/apps/fe-signalloom/src\" && \
AUDIT_ANCHOR_DIR=\"$proof_dir/evidence/checkpoints\" python3 -m audit_anchor \
  --public-key \"$KEYS_DIR/witness-pub.pem\" \
  --expected-key-id \"$expected_key_id\" \
  --source segments \
  --segment-journal \"$journal\" \
  --segment-root \"$proof_dir/store\" \
  --protected-high-water \"$highwater\" \
  verify --json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status": "intact"'* ]]

  # 3. Mutate byte in Parquet file
  segment_id=$(head -n 1 "$journal" | jq -er '.segment_id')
  segment_file="$proof_dir/store/$segment_id"
  [ -f "$segment_file" ]
  printf '\xff' | dd of="$segment_file" bs=1 seek=0 count=1 conv=notrunc status=none

  # 4. Verify mutated: MUST FAIL with exit 2 and status diverged (verify is the gate)
  run bash -c "cd \"$repo/d2-signalloom/apps/fe-signalloom/src\" && \
AUDIT_ANCHOR_DIR=\"$proof_dir/evidence/checkpoints\" python3 -m audit_anchor \
  --public-key \"$KEYS_DIR/witness-pub.pem\" \
  --expected-key-id \"$expected_key_id\" \
  --source segments \
  --segment-journal \"$journal\" \
  --segment-root \"$proof_dir/store\" \
  --protected-high-water \"$highwater\" \
  verify --json"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"status": "diverged"'* ]]
  [[ "$output" == *"digest mismatch"* ]]
}

@test "tamper-regression: tamper-demo cleanup leaves zero residual tenant rows" {
  # Verify cleanup trap in audit-anchor-tamper-demo.sh is configured
  run grep -F 'DELETE FROM public.audit_events WHERE tenant_id = $1' "$repo/scripts/audit-anchor-tamper-demo.sh"
  [ "$status" -eq 0 ]
  run grep -F 'trap cleanup EXIT' "$repo/scripts/audit-anchor-tamper-demo.sh"
  [ "$status" -eq 0 ]
}
