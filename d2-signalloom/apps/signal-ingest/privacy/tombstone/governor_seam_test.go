// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tombstone

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/privacy"
)

// SLDP-P4-GOV seam characterisation.
//
// # What these tests are, and why they PASS while recording a FAILED certification
//
// SLDP-P4-1 and SLDP-P4-2 are each internally sound and each independently green. The property
// neither card owns is the SEAM between them: whether a published tombstone refers to a
// destruction that actually happened. The Phase 4 governor deliverable states it directly —
// "Evidence that tombstones reference real destruction receipts" — and that evidence does not
// exist, because the mechanism does not exist.
//
// These tests therefore CHARACTERISE the seam as it currently stands rather than asserting the
// property the deliverable wanted. They are written to pass against today's code and to FAIL the
// moment someone wires the seam, which is the point: whoever closes this defect is forced to come
// back and delete these tests, and the act of deleting them sends them to
// docs/signalloom/sldp-p4-governor-proof.md §3 where the finding is recorded in full.
//
// A test that silently tolerated the gap would let Phase 5 inherit it by omission. A test that
// simply failed would break the phase's loop-until-green contract and be muted within a day.
// A characterisation test does neither.
//
// See docs/signalloom/sldp-p4-governor-proof.md §3 (Property C, status FAIL).

// TestGovernorSeam_MintCannotAcceptReceiptIdentity is the root of the finding.
//
// privacy.KeyDestructionReceipt carries exactly three fields that identify a specific destruction:
// OperationID (the deterministic keyed saga id), ReceiptSchema and ReceiptDigest — the last
// documented in its own source as "the hex SHA-256 a tombstone references". MintRequest accepts
// none of them. The binding the comment describes has no parameter to travel through.
func TestGovernorSeam_MintCannotAcceptReceiptIdentity(t *testing.T) {
	receiptIdentityFields := []string{"OperationID", "ReceiptSchema", "ReceiptDigest"}

	rt := reflect.TypeOf(privacy.KeyDestructionReceipt{})
	for _, name := range receiptIdentityFields {
		if _, ok := rt.FieldByName(name); !ok {
			t.Fatalf("precondition failed: privacy.KeyDestructionReceipt has no field %q. "+
				"If the receipt no longer carries destruction identity, this whole finding needs re-deriving", name)
		}
	}

	mt := reflect.TypeOf(MintRequest{})
	var carried []string
	for _, name := range receiptIdentityFields {
		if _, ok := mt.FieldByName(name); ok {
			carried = append(carried, name)
		}
	}
	if len(carried) > 0 {
		t.Fatalf("SEAM CLOSED: MintRequest now accepts receipt identity %v. "+
			"This characterisation test has served its purpose — delete it and update "+
			"docs/signalloom/sldp-p4-governor-proof.md §3 to status PASS", carried)
	}

	t.Log("CONFIRMED (SLDP-P4-GOV finding G1): MintRequest accepts no receipt identity; " +
		"a tombstone cannot be bound to the destruction it claims to record")
}

// TestGovernorSeam_TombstoneCarriesNoJoinToAReceipt shows the same gap from the published side.
//
// Non-joinability against RETAINED EVIDENCE is a property SLDP-P4-2 built deliberately and proved
// well (see TestTombstoneNonJoinability and its six positive controls). Non-joinability against
// the DESTRUCTION RECEIPT is a different thing, and is an accident rather than a design: there is
// no keyed, subject-free binding published either. The tombstone is unlinkable to the subject AND
// unlinkable to the destruction, and only the first of those was intended.
func TestGovernorSeam_TombstoneCarriesNoJoinToAReceipt(t *testing.T) {
	receipt := privacy.KeyDestructionReceipt{
		SubjectID:     "alice",
		TenantID:      "t1",
		KeysRemoved:   2,
		DestroyedAt:   time.Date(2026, 9, 14, 11, 0, 0, 0, time.UTC),
		OperationID:   "0f7c1b2a3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8",
		ReceiptSchema: "signalloom.key-destruction-receipt/v1",
		ReceiptDigest: "9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b",
	}

	ts, _, err := Mint(MintRequest{
		TenantID: receipt.TenantID, SubjectID: receipt.SubjectID, RequestID: "req-1",
		PolicyBasis: BasisArticle17_1, ErasedAt: receipt.DestroyedAt,
		KeyGenerationFirst: 41, KeyGenerationLast: 43,
		KeysDestroyed: receipt.KeysRemoved, BucketPopulation: 32,
	})
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}

	raw, err := json.Marshal(ts)
	if err != nil {
		t.Fatalf("marshal tombstone: %v", err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("unmarshal tombstone: %v", err)
	}
	if len(doc) == 0 {
		t.Fatal("degenerate: the tombstone marshalled to an empty document, so the scan below proves nothing")
	}
	for field, value := range doc {
		s, ok := value.(string)
		if !ok {
			continue
		}
		for label, secret := range map[string]string{
			"OperationID":   receipt.OperationID,
			"ReceiptDigest": receipt.ReceiptDigest,
			"ReceiptSchema": receipt.ReceiptSchema,
		} {
			if secret != "" && strings.Contains(s, secret) {
				t.Fatalf("SEAM CLOSED: tombstone field %q now carries receipt %s. "+
					"Delete this characterisation test and update the governor proof §3", field, label)
			}
		}
	}

	t.Log("CONFIRMED (SLDP-P4-GOV finding G1): no published tombstone field joins to any receipt")
}

// TestGovernorSeam_VerificationPassesOnAFabricatedTombstone is the consequence, stated as an attack.
//
// VerifyReceiptCommitment recomputes the commitment from the tombstone's OWN published fields and
// its OWN published nonce. That makes it a self-consistency check, not a proof of anything
// external: it returns true for any well-formed document, including one minted for a subject who
// was never erased, by an operator who ran no saga, against a key that was never destroyed.
//
// This is the "acceptance criterion that would pass whether or not the control works" the phase
// constitution names as a hard blocker. It is recorded here rather than satisfied.
func TestGovernorSeam_VerificationPassesOnAFabricatedTombstone(t *testing.T) {
	// No saga. No key. No receipt. No destruction. Arbitrary attacker-chosen inputs.
	fabricated, _, err := Mint(MintRequest{
		TenantID: "t1", SubjectID: "a-subject-who-was-never-erased", RequestID: "fabricated",
		PolicyBasis: BasisArticle17_1, ErasedAt: time.Date(2026, 9, 14, 9, 0, 0, 0, time.UTC),
		KeyGenerationFirst: 1, KeyGenerationLast: 1,
		KeysDestroyed: 7, BucketPopulation: 64,
	})
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}

	if !VerifyReceiptCommitment(fabricated) {
		t.Fatal("SEAM CLOSED: a fabricated tombstone no longer verifies. " +
			"Delete this characterisation test and update the governor proof §3 to status PASS")
	}

	rawFabricated, err := json.Marshal(fabricated)
	if err != nil {
		t.Fatalf("marshal fabricated tombstone: %v", err)
	}
	if err := ValidateDocument(rawFabricated); err != nil {
		t.Fatalf("the fabricated tombstone is not merely verifiable but fully valid; "+
			"ValidateDocument unexpectedly rejected it: %v", err)
	}

	t.Log("CONFIRMED (SLDP-P4-GOV finding G1, severity HIGH): VerifyReceiptCommitment returns true " +
		"for a tombstone recording a destruction that never occurred. The control cannot fail, " +
		"therefore it certifies nothing. See docs/signalloom/sldp-p4-governor-proof.md §3")
}
