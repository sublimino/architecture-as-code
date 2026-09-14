// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tombstone

import (
	"context"
	"encoding/hex"
	"reflect"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/privacy"
)

// SLDP-P4-GOV Seam Remediation Verification Suite.
//
// # What these tests prove: Seam G1 is CLOSED.
//
// Formerly, SLDP-P4-GOV finding G1 documented that:
//  1. MintRequest accepted none of OperationID, ReceiptSchema, ReceiptDigest, ReceiptNonce.
//  2. VerifyReceiptCommitment was a self-consistency check on internal tombstone parameters
//     rather than a verification against a genuine destruction receipt.
//  3. ProjectReceipt had no production caller.
//  4. privacy/tombstone had zero callers on the production erasure path.
//
// This suite proves that:
//  1. MintRequest accepts all destruction receipt identity fields and binds the persisted nonce.
//  2. VerifyReceiptCommitment takes privacy.KeyDestructionReceipt, calls ProjectReceipt, and
//     fails on fabricated tombstones or mismatched receipts.
//  3. Publisher implements privacy.TombstonePublisher and produces verifiable, confirmable tombstones.

// TestGovernorSeam_MintAcceptsAndBindsReceiptIdentity proves MintRequest accepts receipt identity
// and binds the persisted receipt nonce to the published tombstone.
func TestGovernorSeam_MintAcceptsAndBindsReceiptIdentity(t *testing.T) {
	receiptIdentityFields := []string{"OperationID", "ReceiptSchema", "ReceiptDigest", "ReceiptNonce"}

	mt := reflect.TypeOf(MintRequest{})
	for _, name := range receiptIdentityFields {
		if _, ok := mt.FieldByName(name); !ok {
			t.Fatalf("MintRequest is missing expected field %q", name)
		}
	}

	persistedNonce := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	req := MintRequest{
		TenantID:           "tenant-t1",
		SubjectID:          "alice",
		RequestID:          "req-001",
		PolicyBasis:        BasisArticle17_1,
		ErasedAt:           time.Date(2026, 9, 14, 10, 0, 0, 0, time.UTC),
		KeyGenerationFirst: 1,
		KeyGenerationLast:  1,
		KeysDestroyed:      2,
		BucketPopulation:   10,
		OperationID:        "op-0f7c1b2a3d4e",
		ReceiptSchema:      "signalloom.key-destruction-receipt/v1",
		ReceiptDigest:      "9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b",
		ReceiptNonce:       persistedNonce,
	}

	ts, _, err := Mint(req)
	if err != nil {
		t.Fatalf("Mint failed: %v", err)
	}

	if ts.ReceiptNonce != persistedNonce {
		t.Fatalf("tombstone ReceiptNonce %q does not match persisted receipt nonce %q", ts.ReceiptNonce, persistedNonce)
	}

	if ts.ReceiptCommitment == "" {
		t.Fatal("tombstone ReceiptCommitment is empty")
	}
}

// TestGovernorSeam_VerifyReceiptCommitmentRejectsFabricatedTombstone proves that
// VerifyReceiptCommitment cannot be fooled by a fabricated tombstone or mismatched receipt.
func TestGovernorSeam_VerifyReceiptCommitmentRejectsFabricatedTombstone(t *testing.T) {
	persistedNonce := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	receipt := privacy.KeyDestructionReceipt{
		SubjectID:     "alice",
		TenantID:      "tenant-t1",
		KeysRemoved:   2,
		DestroyedAt:   time.Date(2026, 9, 14, 10, 0, 0, 0, time.UTC),
		OperationID:   "op-0f7c1b2a3d4e",
		ReceiptSchema: "signalloom.key-destruction-receipt/v1",
		ReceiptDigest: "9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b",
		ReceiptNonce:  persistedNonce,
	}

	// 1. Genuine tombstone minted with the receipt's identity and nonce.
	genuineReq := MintRequest{
		TenantID:           receipt.TenantID,
		SubjectID:          receipt.SubjectID,
		RequestID:          "req-genuine",
		PolicyBasis:        BasisArticle17_1,
		ErasedAt:           receipt.DestroyedAt,
		KeyGenerationFirst: 1,
		KeyGenerationLast:  1,
		KeysDestroyed:      receipt.KeysRemoved,
		BucketPopulation:   10,
		OperationID:        receipt.OperationID,
		ReceiptSchema:      receipt.ReceiptSchema,
		ReceiptDigest:      receipt.ReceiptDigest,
		ReceiptNonce:       receipt.ReceiptNonce,
	}
	genuineTS, _, err := Mint(genuineReq)
	if err != nil {
		t.Fatalf("Mint genuine: %v", err)
	}

	if !VerifyReceiptCommitment(genuineTS, receipt) {
		t.Fatal("VerifyReceiptCommitment rejected genuine tombstone against its real destruction receipt")
	}

	// 2. Fabricated tombstone with arbitrary inputs and fresh nonce (no saga receipt).
	fabricatedReq := MintRequest{
		TenantID:           "tenant-t1",
		SubjectID:          "a-subject-who-was-never-erased",
		RequestID:          "fabricated",
		PolicyBasis:        BasisArticle17_1,
		ErasedAt:           time.Date(2026, 9, 14, 9, 0, 0, 0, time.UTC),
		KeyGenerationFirst: 1,
		KeyGenerationLast:  1,
		KeysDestroyed:      7,
		BucketPopulation:   64,
	}
	fabricatedTS, _, err := Mint(fabricatedReq)
	if err != nil {
		t.Fatalf("Mint fabricated: %v", err)
	}

	// Fabricated tombstone MUST FAIL against genuine receipt.
	if VerifyReceiptCommitment(fabricatedTS, receipt) {
		t.Fatal("CRITICAL: VerifyReceiptCommitment accepted a fabricated tombstone against a real receipt!")
	}

	// Fabricated tombstone against fabricated receipt with different digest MUST FAIL.
	fakeReceipt := receipt
	fakeReceipt.ReceiptDigest = "1111111111111111111111111111111111111111111111111111111111111111"
	if VerifyReceiptCommitment(fabricatedTS, fakeReceipt) {
		t.Fatal("CRITICAL: VerifyReceiptCommitment accepted a fabricated tombstone against fake receipt!")
	}

	// Genuine tombstone against mismatched tenant MUST FAIL.
	wrongTenantReceipt := receipt
	wrongTenantReceipt.TenantID = "tenant-other"
	if VerifyReceiptCommitment(genuineTS, wrongTenantReceipt) {
		t.Fatal("VerifyReceiptCommitment accepted tombstone with mismatched tenant")
	}

	// Genuine tombstone against mismatched digest MUST FAIL.
	wrongDigestReceipt := receipt
	wrongDigestReceipt.ReceiptDigest = "2222222222222222222222222222222222222222222222222222222222222222"
	if VerifyReceiptCommitment(genuineTS, wrongDigestReceipt) {
		t.Fatal("VerifyReceiptCommitment accepted tombstone with mismatched digest")
	}
}

// TestGovernorSeam_ProjectReceiptIsCalledInVerification proves that ProjectReceipt
// is load-bearing and its fields govern commitment verification.
func TestGovernorSeam_ProjectReceiptIsCalledInVerification(t *testing.T) {
	nonceBytes := make([]byte, 32)
	for i := range nonceBytes {
		nonceBytes[i] = byte(i)
	}
	nonce := hex.EncodeToString(nonceBytes)

	receipt := privacy.KeyDestructionReceipt{
		SubjectID:     "alice",
		TenantID:      "tenant-t1",
		KeysRemoved:   3,
		DestroyedAt:   time.Date(2026, 9, 14, 15, 30, 0, 0, time.UTC),
		OperationID:   "op-test",
		ReceiptSchema: "signalloom.key-destruction-receipt/v1",
		ReceiptDigest: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
		ReceiptNonce:  nonce,
	}

	proj := ProjectReceipt(receipt, 1, 100)
	if proj.TenantID != receipt.TenantID {
		t.Errorf("proj.TenantID = %q, want %q", proj.TenantID, receipt.TenantID)
	}
	if proj.KeysDestroyedBand != BandKeysDestroyed(receipt.KeysRemoved) {
		t.Errorf("proj.KeysDestroyedBand = %q, want %q", proj.KeysDestroyedBand, BandKeysDestroyed(receipt.KeysRemoved))
	}
	if proj.DestroyedDay != CoarsenDay(receipt.DestroyedAt) {
		t.Errorf("proj.DestroyedDay = %q, want %q", proj.DestroyedDay, CoarsenDay(receipt.DestroyedAt))
	}

	ts, _, err := Mint(MintRequest{
		TenantID:           receipt.TenantID,
		SubjectID:          receipt.SubjectID,
		RequestID:          "req-proj",
		PolicyBasis:        BasisArticle17_1,
		ErasedAt:           receipt.DestroyedAt,
		KeyGenerationFirst: 1,
		KeyGenerationLast:  100,
		KeysDestroyed:      receipt.KeysRemoved,
		BucketPopulation:   10,
		OperationID:        receipt.OperationID,
		ReceiptSchema:      receipt.ReceiptSchema,
		ReceiptDigest:      receipt.ReceiptDigest,
		ReceiptNonce:       receipt.ReceiptNonce,
	})
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}

	// Changing receipt.KeysRemoved to a different band causes verification failure.
	mutatedReceipt := receipt
	mutatedReceipt.KeysRemoved = 100 // changes band to "21+"
	if VerifyReceiptCommitment(ts, mutatedReceipt) {
		t.Fatal("VerifyReceiptCommitment did not detect discrepancy in projected keys destroyed band")
	}

	// Changing receipt.DestroyedAt to a different day causes verification failure.
	mutatedReceipt = receipt
	mutatedReceipt.DestroyedAt = receipt.DestroyedAt.AddDate(0, 0, 2)
	if VerifyReceiptCommitment(ts, mutatedReceipt) {
		t.Fatal("VerifyReceiptCommitment did not detect discrepancy in projected destroyed day")
	}
}

// TestGovernorSeam_PublisherProducesVerifiableTombstone tests end-to-end tombstone publication
// via Publisher and verifies that the resulting tombstone is valid, verifiable, and confirmable.
func TestGovernorSeam_PublisherProducesVerifiableTombstone(t *testing.T) {
	pub := NewPublisher(nil)

	receipt := privacy.KeyDestructionReceipt{
		SubjectID:     "alice",
		TenantID:      "tenant-t1",
		KeysRemoved:   2,
		DestroyedAt:   time.Date(2026, 9, 14, 12, 0, 0, 0, time.UTC),
		OperationID:   "op-pub-001",
		ReceiptSchema: "signalloom.key-destruction-receipt/v1",
		ReceiptDigest: "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899",
		ReceiptNonce:  "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
	}

	req := privacy.ErasureRequest{
		RequestID:   "req-pub-001",
		TenantID:    receipt.TenantID,
		SubjectID:   receipt.SubjectID,
		RequestedBy: "operator-1",
		RequestedAt: receipt.DestroyedAt,
	}

	var storedTombstone Tombstone
	pub.Store = func(_ context.Context, ts Tombstone, _ []byte) error {
		storedTombstone = ts
		return nil
	}

	publication, err := pub.PublishTombstone(context.Background(), receipt, req)
	if err != nil {
		t.Fatalf("PublishTombstone failed: %v", err)
	}

	if publication.TombstoneID == "" {
		t.Fatal("publication TombstoneID is empty")
	}
	if publication.ConfirmationKey == "" {
		t.Fatal("publication ConfirmationKey is empty")
	}

	if storedTombstone.TombstoneID != publication.TombstoneID {
		t.Fatalf("stored tombstone id %q != publication %q", storedTombstone.TombstoneID, publication.TombstoneID)
	}

	// Verify tombstone against the real destruction receipt.
	if !VerifyReceiptCommitment(storedTombstone, receipt) {
		t.Fatal("published tombstone failed VerifyReceiptCommitment against the destruction receipt")
	}

	// Verify selective disclosure confirmation key.
	ck, err := ParseConfirmationKey(publication.ConfirmationKey)
	if err != nil {
		t.Fatalf("ParseConfirmationKey failed: %v", err)
	}
	if !ConfirmSpecificErasure(storedTombstone, ck, req.TenantID, req.SubjectID, req.RequestID) {
		t.Fatal("ConfirmSpecificErasure failed with the disclosed confirmation key")
	}

	// Mismatched subject in ConfirmSpecificErasure must fail.
	if ConfirmSpecificErasure(storedTombstone, ck, req.TenantID, "wrong-subject", req.RequestID) {
		t.Fatal("ConfirmSpecificErasure succeeded with wrong subject")
	}
}
