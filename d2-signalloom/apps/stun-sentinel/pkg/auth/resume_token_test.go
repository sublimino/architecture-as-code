// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package auth

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func testKeys(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

func validToken(pub ed25519.PublicKey, priv ed25519.PrivateKey, operatorID, agentID, namespace string) (ResumeToken, error) {
	now := time.Now().UTC()
	token := ResumeToken{
		SchemaVersion:         FrozenSchemaVersion,
		TokenID:               "tok-test-12345",
		Algorithm:             ResumeTokenAlgEd25519,
		AgentID:               agentID,
		Namespace:             namespace,
		Audience:              "osramp-fleet",
		OperatorID:            operatorID,
		GovernanceApprovalRef: "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		IssuedAt:              now.Add(-1 * time.Minute).Format(time.RFC3339),
		ExpiresAt:             now.Add(10 * time.Minute).Format(time.RFC3339),
		Nonce:                 base64.StdEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef")),
		TrustRootID:           "sler-root-2026",
		RequiredSignatures:    1,
	}
	return SignResumeToken(token, operatorID, priv, now)
}

func TestVerifyValidResumeToken(t *testing.T) {
	pub, priv := testKeys(t)
	opID := "spiffe://signalloom.demo/operator/alice"
	agentID := "agent-payment-audit"
	ns := "fe-signalloom-agents"

	token, err := validToken(pub, priv, opID, agentID, ns)
	if err != nil {
		t.Fatalf("SignResumeToken: %v", err)
	}

	reg := NewStaticOperatorKeyRegistry(OperatorKeyEntry{
		OperatorID: opID,
		KeyID:      ComputeKeyID(pub),
		PublicKey:  pub,
	})

	policy := DefaultResumeTokenPolicy("osramp-fleet", "sler-root-2026")
	target := TargetRef{AgentID: agentID, Namespace: ns}

	res, err := VerifyResumeToken(token, target, reg, policy, time.Now().UTC())
	if err != nil {
		t.Fatalf("VerifyResumeToken failed unexpectedly: %v", err)
	}
	if len(res.OperatorIDs) != 1 || res.OperatorIDs[0] != opID {
		t.Errorf("expected operator %s, got %v", opID, res.OperatorIDs)
	}
}

func TestVerifyRejectsInvalidSignature(t *testing.T) {
	pub, _ := testKeys(t)
	_, otherPriv := testKeys(t)
	opID := "spiffe://signalloom.demo/operator/alice"
	agentID := "agent-payment-audit"
	ns := "fe-signalloom-agents"

	// Sign with otherPriv but register pub
	now := time.Now().UTC()
	token := ResumeToken{
		SchemaVersion:         FrozenSchemaVersion,
		TokenID:               "tok-test-12345",
		Algorithm:             ResumeTokenAlgEd25519,
		AgentID:               agentID,
		Namespace:             ns,
		Audience:              "osramp-fleet",
		OperatorID:            opID,
		GovernanceApprovalRef: "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		IssuedAt:              now.Add(-1 * time.Minute).Format(time.RFC3339),
		ExpiresAt:             now.Add(10 * time.Minute).Format(time.RFC3339),
		Nonce:                 base64.StdEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef")),
		TrustRootID:           "sler-root-2026",
		RequiredSignatures:    1,
	}
	signed, _ := SignResumeToken(token, opID, otherPriv, now)

	reg := NewStaticOperatorKeyRegistry(OperatorKeyEntry{
		OperatorID: opID,
		KeyID:      ComputeKeyID(pub),
		PublicKey:  pub,
	})
	policy := DefaultResumeTokenPolicy("osramp-fleet", "sler-root-2026")
	target := TargetRef{AgentID: agentID, Namespace: ns}

	_, err := VerifyResumeToken(signed, target, reg, policy, now)
	if err == nil {
		t.Fatal("expected signature verification failure, got nil")
	}
}

func TestVerifyRejectsRevokedKey(t *testing.T) {
	pub, priv := testKeys(t)
	opID := "spiffe://signalloom.demo/operator/alice"
	agentID := "agent-payment-audit"
	ns := "fe-signalloom-agents"

	token, err := validToken(pub, priv, opID, agentID, ns)
	if err != nil {
		t.Fatal(err)
	}

	reg := NewStaticOperatorKeyRegistry(OperatorKeyEntry{
		OperatorID: opID,
		KeyID:      ComputeKeyID(pub),
		PublicKey:  pub,
		Revoked:    true,
	})
	policy := DefaultResumeTokenPolicy("osramp-fleet", "sler-root-2026")
	target := TargetRef{AgentID: agentID, Namespace: ns}

	_, err = VerifyResumeToken(token, target, reg, policy, time.Now().UTC())
	if !errors.Is(err, ErrResumeTokenRevokedKey) {
		t.Fatalf("expected ErrResumeTokenRevokedKey, got: %v", err)
	}
}

func TestVerifyRejectsTargetMismatch(t *testing.T) {
	pub, priv := testKeys(t)
	opID := "spiffe://signalloom.demo/operator/alice"
	agentID := "agent-payment-audit"
	ns := "fe-signalloom-agents"

	token, err := validToken(pub, priv, opID, agentID, ns)
	if err != nil {
		t.Fatal(err)
	}

	reg := NewStaticOperatorKeyRegistry(OperatorKeyEntry{
		OperatorID: opID,
		KeyID:      ComputeKeyID(pub),
		PublicKey:  pub,
	})
	policy := DefaultResumeTokenPolicy("osramp-fleet", "sler-root-2026")
	target := TargetRef{AgentID: "agent-other", Namespace: ns}

	_, err = VerifyResumeToken(token, target, reg, policy, time.Now().UTC())
	if !errors.Is(err, ErrResumeTokenTargetMismatch) {
		t.Fatalf("expected ErrResumeTokenTargetMismatch, got: %v", err)
	}
}

func TestVerifyDualOperatorQuorum(t *testing.T) {
	pub1, priv1 := testKeys(t)
	pub2, priv2 := testKeys(t)
	op1 := "spiffe://signalloom.demo/operator/alice"
	op2 := "spiffe://signalloom.demo/operator/bob"
	agentID := "agent-payment-audit"
	ns := "fe-signalloom-agents"

	now := time.Now().UTC()
	token := ResumeToken{
		SchemaVersion:         FrozenSchemaVersion,
		TokenID:               "tok-test-dual",
		Algorithm:             ResumeTokenAlgEd25519,
		AgentID:               agentID,
		Namespace:             ns,
		Audience:              "osramp-fleet",
		OperatorID:            op1,
		GovernanceApprovalRef: "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		IssuedAt:              now.Add(-1 * time.Minute).Format(time.RFC3339),
		ExpiresAt:             now.Add(10 * time.Minute).Format(time.RFC3339),
		Nonce:                 base64.StdEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef")),
		TrustRootID:           "sler-root-2026",
		RequiredSignatures:    2,
	}

	token, err := SignResumeToken(token, op1, priv1, now)
	if err != nil {
		t.Fatal(err)
	}
	token, err = SignResumeToken(token, op2, priv2, now.Add(5*time.Second))
	if err != nil {
		t.Fatal(err)
	}

	reg := NewStaticOperatorKeyRegistry(
		OperatorKeyEntry{OperatorID: op1, KeyID: ComputeKeyID(pub1), PublicKey: pub1},
		OperatorKeyEntry{OperatorID: op2, KeyID: ComputeKeyID(pub2), PublicKey: pub2},
	)

	policy := DefaultResumeTokenPolicy("osramp-fleet", "sler-root-2026")
	policy.RequiredSignatures = 2
	target := TargetRef{AgentID: agentID, Namespace: ns}

	res, err := VerifyResumeToken(token, target, reg, policy, now)
	if err != nil {
		t.Fatalf("dual-operator verify failed: %v", err)
	}
	if len(res.OperatorIDs) != 2 {
		t.Errorf("expected 2 operators, got %v", res.OperatorIDs)
	}
}

func TestReplayLedgerIdempotencyAndReplay(t *testing.T) {
	ledger := NewReplayLedger()
	tokenID := "tok-replay-test-01"
	idempotencyKey := "idem-req-111"
	operators := []string{"spiffe://signalloom.demo/operator/alice"}
	now := time.Now().UTC()

	// First use
	isRetry, ops, err := ledger.CheckAndRecord(tokenID, idempotencyKey, operators, now)
	if err != nil {
		t.Fatalf("first check failed: %v", err)
	}
	if isRetry {
		t.Errorf("expected isRetry=false on first use")
	}
	if len(ops) != 1 || ops[0] != operators[0] {
		t.Errorf("unexpected operators: %v", ops)
	}

	// Idempotent retry with SAME idempotencyKey
	isRetry, ops, err = ledger.CheckAndRecord(tokenID, idempotencyKey, operators, now.Add(1*time.Second))
	if err != nil {
		t.Fatalf("idempotent retry failed: %v", err)
	}
	if !isRetry {
		t.Errorf("expected isRetry=true on repeat presentation with same idempotency key")
	}

	// Replay attempt with DIFFERENT idempotencyKey
	_, _, err = ledger.CheckAndRecord(tokenID, "different-key", operators, now.Add(2*time.Second))
	if !errors.Is(err, ErrResumeTokenReplayed) {
		t.Fatalf("expected ErrResumeTokenReplayed, got: %v", err)
	}
}

func TestLoadOperatorKeyRegistryFromJSONFileAndDir(t *testing.T) {
	pub1, _ := testKeys(t)
	pub2, _ := testKeys(t)
	op1 := "spiffe://signalloom.demo/operator/alice"
	op2 := "spiffe://signalloom.demo/operator/bob"

	tmpDir := t.TempDir()
	key1JSON := OperatorKeyJSON{
		OperatorID: op1,
		PublicKey:  base64.StdEncoding.EncodeToString(pub1),
	}
	key2JSON := OperatorKeyJSON{
		OperatorID: op2,
		PublicKey:  hex.EncodeToString(pub2),
	}

	data1, _ := json.Marshal([]OperatorKeyJSON{key1JSON})
	data2, _ := json.Marshal(key2JSON)

	file1 := filepath.Join(tmpDir, "keys1.json")
	file2 := filepath.Join(tmpDir, "keys2.json")
	if err := os.WriteFile(file1, data1, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file2, data2, 0o644); err != nil {
		t.Fatal(err)
	}

	// Load from directory
	reg, err := LoadOperatorKeyRegistry(tmpDir)
	if err != nil {
		t.Fatalf("LoadOperatorKeyRegistry(dir): %v", err)
	}
	if len(reg.AllKeys()) != 2 {
		t.Fatalf("expected 2 keys, got %d", len(reg.AllKeys()))
	}

	e1, err := reg.LookupOperatorKey(ComputeKeyID(pub1))
	if err != nil || e1.OperatorID != op1 {
		t.Errorf("lookup key1 failed: %v, entry: %+v", err, e1)
	}
	e2, err := reg.LookupOperatorKey(ComputeKeyID(pub2))
	if err != nil || e2.OperatorID != op2 {
		t.Errorf("lookup key2 failed: %v, entry: %+v", err, e2)
	}

	// Load single file
	regSingle, err := LoadOperatorKeyRegistry(file1)
	if err != nil {
		t.Fatalf("LoadOperatorKeyRegistry(file): %v", err)
	}
	if len(regSingle.AllKeys()) != 1 {
		t.Fatalf("expected 1 key, got %d", len(regSingle.AllKeys()))
	}
}

func TestParseResumeTokenJSONAndBase64(t *testing.T) {
	pub, priv := testKeys(t)
	token, _ := validToken(pub, priv, "spiffe://signalloom.demo/operator/alice", "agent-x", "ns")

	tokenBytes, _ := json.Marshal(token)
	b64 := base64.StdEncoding.EncodeToString(tokenBytes)

	// Test parsing raw JSON
	p1, err := ParseResumeToken(string(tokenBytes))
	if err != nil || p1.TokenID != token.TokenID {
		t.Errorf("parse raw JSON failed: %v", err)
	}

	// Test parsing base64
	p2, err := ParseResumeToken(b64)
	if err != nil || p2.TokenID != token.TokenID {
		t.Errorf("parse base64 failed: %v", err)
	}
}
