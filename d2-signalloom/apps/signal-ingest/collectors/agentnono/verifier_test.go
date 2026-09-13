// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package agentnono

import (
	"crypto/x509"
	"encoding/pem"
	"testing"
	"time"
)

func TestAuditVerifier_SignatureRoundtrip(t *testing.T) {
	spiffeID := "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
	kp, err := GenerateTestKeypair(spiffeID)
	if err != nil {
		t.Fatalf("failed to generate test keypair: %v", err)
	}

	verifier := NewAuditVerifier(VerifierConfig{
		TrustDomain:    DefaultTrustDomain,
		TrustBundlePEM: []byte(kp.CACertPEM),
	})

	sessionID := "audit-sess-roundtrip-001"
	events, err := GenerateSignedSession(kp, sessionID, 3, time.Now().UTC())
	if err != nil {
		t.Fatalf("failed to generate signed session: %v", err)
	}

	for i, ev := range events {
		res := verifier.VerifyEvent(ev)
		if res.Status != StatusVerified {
			t.Fatalf("event %d: expected status %s, got %s (err: %v)", i+1, StatusVerified, res.Status, res.Error)
		}
		if res.SPIFFEID != spiffeID {
			t.Errorf("event %d: expected SPIFFE ID %s, got %s", i+1, spiffeID, res.SPIFFEID)
		}
		if res.SignatureGitOID == "" {
			t.Errorf("event %d: expected non-empty SignatureGitOID", i+1)
		}
	}
}

func TestAuditVerifier_TamperedPayloadRejected(t *testing.T) {
	spiffeID := "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
	kp, err := GenerateTestKeypair(spiffeID)
	if err != nil {
		t.Fatalf("failed to generate test keypair: %v", err)
	}

	verifier := NewAuditVerifier(VerifierConfig{
		TrustDomain:    DefaultTrustDomain,
		TrustBundlePEM: []byte(kp.CACertPEM),
	})

	sessionID := "audit-sess-tamper-001"
	events, err := GenerateSignedSession(kp, sessionID, 2, time.Now().UTC())
	if err != nil {
		t.Fatalf("failed to generate signed session: %v", err)
	}

	// Verify first event is valid
	res1 := verifier.VerifyEvent(events[0])
	if res1.Status != StatusVerified {
		t.Fatalf("expected event 1 verified, got %s (%v)", res1.Status, res1.Error)
	}

	// Tamper event 2 payload bytes (alter Syscall) without resigning
	events[1].Syscall = "pwrite64"
	res2 := verifier.VerifyEvent(events[1])
	if res2.Status != StatusTampered {
		t.Fatalf("expected tampered event status %s, got %s", StatusTampered, res2.Status)
	}
}

func TestAuditVerifier_HashChainBreakRejected(t *testing.T) {
	spiffeID := "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
	kp, err := GenerateTestKeypair(spiffeID)
	if err != nil {
		t.Fatalf("failed to generate test keypair: %v", err)
	}

	verifier := NewAuditVerifier(VerifierConfig{
		TrustDomain:    DefaultTrustDomain,
		TrustBundlePEM: []byte(kp.CACertPEM),
	})

	sessionID := "audit-sess-break-001"
	events, err := GenerateSignedSession(kp, sessionID, 3, time.Now().UTC())
	if err != nil {
		t.Fatalf("failed to generate signed session: %v", err)
	}

	// Verify event 1
	_ = verifier.VerifyEvent(events[0])

	// Corrupt prev_digest of event 2 to simulate skipped/dropped event in chain
	events[1].PrevDigest = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
	res2 := verifier.VerifyEvent(events[1])
	if res2.Status != StatusTampered {
		t.Fatalf("expected break to trigger %s, got %s", StatusTampered, res2.Status)
	}
}

func TestAuditVerifier_UnsignedAdmittedAsUnverified(t *testing.T) {
	verifier := NewAuditVerifier(VerifierConfig{
		TrustDomain:      DefaultTrustDomain,
		RequireSignature: false,
	})

	event := &NonoAuditEvent{
		Timestamp:               time.Now().UTC(),
		AgentID:                 "agent-standard-baseline",
		SPIFFEID:                "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-standard-baseline",
		AuditSessionID:          "audit-sess-unsigned-001",
		Seq:                     1,
		EventType:               "heartbeat",
		NonoCapabilityAvailable: false,
	}

	res := verifier.VerifyEvent(event)
	if res.Status != StatusUnverified {
		t.Fatalf("expected unsigned event to have status %s, got %s", StatusUnverified, res.Status)
	}
}

func TestAuditVerifier_CosignManifestVerification(t *testing.T) {
	spiffeID := "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
	kp, err := GenerateTestKeypair(spiffeID)
	if err != nil {
		t.Fatalf("generate keypair: %v", err)
	}

	manifestData := []byte("apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: agent-nono-evidenced")
	sig, err := kp.SignPayload(manifestData)
	if err != nil {
		t.Fatalf("sign manifest: %v", err)
	}

	pubDER, err := x509.MarshalPKIXPublicKey(&kp.WorkloadKey.PublicKey)
	if err != nil {
		t.Fatalf("marshal pubkey: %v", err)
	}
	pubPEM := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER})

	valid, err := VerifyCosignManifest(manifestData, sig, pubPEM)
	if err != nil || !valid {
		t.Fatalf("expected cosign manifest valid, got %v (err: %v)", valid, err)
	}

	// Corrupt manifest and assert failure
	corrupted := []byte("apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: malicious-agent")
	validBad, errBad := VerifyCosignManifest(corrupted, sig, pubPEM)
	if validBad || errBad == nil {
		t.Fatalf("expected corrupted manifest to fail verification")
	}
}

func TestVerifyFinalizedSession_ValidChain(t *testing.T) {
	spiffeID := "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
	kp, err := GenerateTestKeypair(spiffeID)
	if err != nil {
		t.Fatalf("failed to generate test keypair: %v", err)
	}

	verifier := NewAuditVerifier(VerifierConfig{
		TrustDomain:      DefaultTrustDomain,
		TrustBundlePEM:   []byte(kp.CACertPEM),
		RequireSignature: true,
	})

	sessionID := "audit-sess-finalized-valid-001"
	events, err := GenerateFinalizedSignedSession(kp, sessionID, 4, time.Now().UTC())
	if err != nil {
		t.Fatalf("failed to generate finalized session: %v", err)
	}

	res := verifier.VerifyFinalizedSession(events)
	if res.Status != StatusVerified {
		t.Fatalf("expected StatusVerified, got %s (err: %v)", res.Status, res.Error)
	}
	if !res.IsFinalized {
		t.Errorf("expected IsFinalized to be true")
	}
	if res.EventCount != 4 {
		t.Errorf("expected EventCount 4, got %d", res.EventCount)
	}
	if res.SessionID != sessionID {
		t.Errorf("expected sessionID %q, got %q", sessionID, res.SessionID)
	}
	if len(res.GitOIDs) != 4 {
		t.Errorf("expected 4 GitOIDs, got %d", len(res.GitOIDs))
	}
	if res.LandlockABI < 1 {
		t.Errorf("expected LandlockABI >= 1, got %d", res.LandlockABI)
	}
}

func TestVerifyFinalizedSession_UnfinalizedRejected(t *testing.T) {
	spiffeID := "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
	kp, err := GenerateTestKeypair(spiffeID)
	if err != nil {
		t.Fatalf("failed to generate test keypair: %v", err)
	}

	verifier := NewAuditVerifier(VerifierConfig{
		TrustDomain:      DefaultTrustDomain,
		TrustBundlePEM:   []byte(kp.CACertPEM),
		RequireSignature: true,
	})

	sessionID := "audit-sess-unfinalized-001"
	// Generate regular unfinalized session
	events, err := GenerateSignedSession(kp, sessionID, 3, time.Now().UTC())
	if err != nil {
		t.Fatalf("failed to generate signed session: %v", err)
	}

	res := verifier.VerifyFinalizedSession(events)
	if res.Status != StatusUnverified {
		t.Fatalf("expected StatusUnverified for unfinalized session, got %s", res.Status)
	}
	if res.IsFinalized {
		t.Errorf("expected IsFinalized to be false")
	}
	if res.Error == nil {
		t.Errorf("expected error for unfinalized session")
	}
}

func TestVerifyFinalizedSession_EmptySessionRejected(t *testing.T) {
	verifier := NewAuditVerifier(VerifierConfig{
		TrustDomain: DefaultTrustDomain,
	})

	res := verifier.VerifyFinalizedSession([]*NonoAuditEvent{})
	if res.Status != StatusTampered {
		t.Fatalf("expected StatusTampered for empty session, got %s", res.Status)
	}
	if res.Error == nil {
		t.Errorf("expected error for empty session")
	}
}

func TestVerifyFinalizedSession_MismatchedSessionIDRejected(t *testing.T) {
	spiffeID := "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
	kp, err := GenerateTestKeypair(spiffeID)
	if err != nil {
		t.Fatalf("failed to generate test keypair: %v", err)
	}

	verifier := NewAuditVerifier(VerifierConfig{
		TrustDomain:    DefaultTrustDomain,
		TrustBundlePEM: []byte(kp.CACertPEM),
	})

	events, err := GenerateFinalizedSignedSession(kp, "audit-sess-primary", 3, time.Now().UTC())
	if err != nil {
		t.Fatalf("generate session: %v", err)
	}

	// Inject different session ID into event 2
	events[1].AuditSessionID = "audit-sess-foreign"
	events[1].SessionID = "audit-sess-foreign"

	res := verifier.VerifyFinalizedSession(events)
	if res.Status != StatusTampered {
		t.Fatalf("expected StatusTampered for mismatched session ID, got %s", res.Status)
	}
}

func TestVerifyFinalizedSession_SequenceGapRejected(t *testing.T) {
	spiffeID := "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
	kp, err := GenerateTestKeypair(spiffeID)
	if err != nil {
		t.Fatalf("failed to generate test keypair: %v", err)
	}

	verifier := NewAuditVerifier(VerifierConfig{
		TrustDomain:    DefaultTrustDomain,
		TrustBundlePEM: []byte(kp.CACertPEM),
	})

	events, err := GenerateFinalizedSignedSession(kp, "audit-sess-gap", 4, time.Now().UTC())
	if err != nil {
		t.Fatalf("generate session: %v", err)
	}

	// Create sequence gap: 1, 2, 4
	events[2].Seq = 4

	res := verifier.VerifyFinalizedSession(events)
	if res.Status != StatusTampered {
		t.Fatalf("expected StatusTampered for sequence gap, got %s", res.Status)
	}
}

func TestVerifyFinalizedSession_OutOfOrderSequenceRejected(t *testing.T) {
	spiffeID := "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
	kp, err := GenerateTestKeypair(spiffeID)
	if err != nil {
		t.Fatalf("failed to generate test keypair: %v", err)
	}

	verifier := NewAuditVerifier(VerifierConfig{
		TrustDomain:    DefaultTrustDomain,
		TrustBundlePEM: []byte(kp.CACertPEM),
	})

	events, err := GenerateFinalizedSignedSession(kp, "audit-sess-order", 3, time.Now().UTC())
	if err != nil {
		t.Fatalf("generate session: %v", err)
	}

	// Invert sequence order: 1, 3, 2
	events[1].Seq = 3
	events[2].Seq = 2

	res := verifier.VerifyFinalizedSession(events)
	if res.Status != StatusTampered {
		t.Fatalf("expected StatusTampered for out-of-order sequence, got %s", res.Status)
	}
}

func TestVerifyFinalizedSession_HashChainBreakRejected(t *testing.T) {
	spiffeID := "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
	kp, err := GenerateTestKeypair(spiffeID)
	if err != nil {
		t.Fatalf("failed to generate test keypair: %v", err)
	}

	verifier := NewAuditVerifier(VerifierConfig{
		TrustDomain:    DefaultTrustDomain,
		TrustBundlePEM: []byte(kp.CACertPEM),
	})

	events, err := GenerateFinalizedSignedSession(kp, "audit-sess-break", 3, time.Now().UTC())
	if err != nil {
		t.Fatalf("generate session: %v", err)
	}

	// Corrupt prev_digest of event 2
	events[1].PrevDigest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

	res := verifier.VerifyFinalizedSession(events)
	if res.Status != StatusTampered {
		t.Fatalf("expected StatusTampered for hash chain break, got %s", res.Status)
	}
}

func TestVerifyFinalizedSession_ForgedSignatureRejected(t *testing.T) {
	spiffeID := "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
	kp, err := GenerateTestKeypair(spiffeID)
	if err != nil {
		t.Fatalf("failed to generate test keypair: %v", err)
	}

	verifier := NewAuditVerifier(VerifierConfig{
		TrustDomain:      DefaultTrustDomain,
		TrustBundlePEM:   []byte(kp.CACertPEM),
		RequireSignature: true,
	})

	events, err := GenerateFinalizedSignedSession(kp, "audit-sess-forged", 3, time.Now().UTC())
	if err != nil {
		t.Fatalf("generate session: %v", err)
	}

	// Generate different attacker keypair and sign event 2 with attacker key
	attackerKP, err := GenerateTestKeypair("spiffe://signalloom.demo/ns/attacker/sa/evil")
	if err != nil {
		t.Fatalf("generate attacker keypair: %v", err)
	}
	forgedSig, err := attackerKP.SignPayload(events[1].CanonicalPayload())
	if err != nil {
		t.Fatalf("sign forged: %v", err)
	}
	events[1].Signature = forgedSig

	res := verifier.VerifyFinalizedSession(events)
	if res.Status != StatusTampered {
		t.Fatalf("expected StatusTampered for forged signature, got %s", res.Status)
	}
}
