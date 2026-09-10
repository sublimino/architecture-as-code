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
