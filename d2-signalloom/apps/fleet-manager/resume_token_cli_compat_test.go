package main

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/auth"
)

// cmd/resume-token signs through the sentinel's auth package, which is the
// deployed verifier's implementation of the same frozen byte layout. This
// pins that a token signed there verifies here, so the CLI cannot drift from
// the hub's verifier without this test saying so.
func TestResumeTokenCLI_SentinelSignedTokenVerifiesAtTheHub(t *testing.T) {
	now := time.Now().UTC()
	alicePub, alicePriv := keyFromSeed(t, seedOperatorAlice)
	bobPub, bobPriv := keyFromSeed(t, seedOperatorBob)

	minted := auth.ResumeToken{
		SchemaVersion:         auth.FrozenSchemaVersion,
		TokenID:               "rt-compat",
		Algorithm:             auth.ResumeTokenAlgEd25519,
		AgentID:               "remote-api-0",
		Namespace:             "tenant-a",
		Audience:              "signalloom-fleet/local",
		GovernanceApprovalRef: "CHG-2026-10-04-0007",
		IssuedAt:              now.Add(-30 * time.Second).Format(time.RFC3339),
		ExpiresAt:             now.Add(9 * time.Minute).Format(time.RFC3339),
		Nonce:                 "cmVzdW1lLXRva2VuLWNsaS1jb21wYXQtbm9uY2U=",
		TrustRootID:           refTrustRoot,
		RequiredSignatures:    2,
	}
	signed, err := auth.SignResumeToken(minted, opAlice, alicePriv, now.Add(-20*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	signed, err = auth.SignResumeToken(signed, opBob, bobPriv, now.Add(-10*time.Second))
	if err != nil {
		t.Fatal(err)
	}

	wire, err := json.Marshal(signed)
	if err != nil {
		t.Fatal(err)
	}
	var token ResumeToken
	if err := json.Unmarshal(wire, &token); err != nil {
		t.Fatalf("hub cannot decode the sentinel-signed token: %v", err)
	}
	reg := NewStaticOperatorKeyRegistry(
		OperatorKeyEntry{OperatorID: opAlice, KeyID: ComputeKeyID(alicePub), PublicKey: alicePub},
		OperatorKeyEntry{OperatorID: opBob, KeyID: ComputeKeyID(bobPub), PublicKey: bobPub},
	)
	target := TargetRef{AgentID: "remote-api-0", Namespace: "tenant-a"}
	if err := VerifyResumeToken(token, target, reg, dualPolicy(), now); err != nil {
		t.Fatalf("hub verifier rejected a sentinel-signed token: %v", err)
	}
}
