package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// ── Test key material ────────────────────────────────────────────────────────
//
// These seeds are literal ASCII strings committed on purpose. They are NOT
// secrets and never were: they exist so the worked example payload in
// docs/signalloom/ is byte-reproducible, so a P4-3 engineer implementing the
// verifier in another module can check their implementation against a known
// signature rather than against their own. A test vector with a hidden key is
// not a test vector.
const (
	seedOperatorAlice = "SLER-P1-3 example operator ALICE"
	seedOperatorBob   = "SLER-P1-3 example operator BOBBY"
	seedOperatorMal   = "SLER-P1-3 example operator MALLO"
)

const (
	opAlice = "spiffe://signalloom.io/operator/alice"
	opBob   = "spiffe://signalloom.io/operator/bob"
	opMal   = "spiffe://signalloom.io/operator/mallory"
)

func keyFromSeed(t *testing.T, seed string) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	if len(seed) != ed25519.SeedSize {
		t.Fatalf("seed %q is %d bytes, ed25519 needs %d", seed, len(seed), ed25519.SeedSize)
	}
	priv := ed25519.NewKeyFromSeed([]byte(seed))
	return priv.Public().(ed25519.PublicKey), priv
}

var refNow = time.Date(2026, 9, 15, 12, 0, 0, 0, time.UTC)

func refTarget() TargetRef {
	return TargetRef{AgentID: "agent-llm-classifier", Namespace: "fe-signalloom-agents"}
}

// unsignedToken is the reference token body, before any signature.
func unsignedToken() ResumeToken {
	return ResumeToken{
		SchemaVersion:         FrozenSchemaVersion,
		TokenID:               "rt-2026-09-15-0001",
		Algorithm:             ResumeTokenAlgEd25519,
		AgentID:               "agent-llm-classifier",
		Namespace:             "fe-signalloom-agents",
		Audience:              "signalloom-fleet/local",
		GovernanceApprovalRef: "CHG-2026-09-15-0042",
		IssuedAt:              refNow.Add(-2 * time.Minute).Format(time.RFC3339),
		ExpiresAt:             refNow.Add(8 * time.Minute).Format(time.RFC3339),
		Nonce:                 base64.StdEncoding.EncodeToString([]byte("sler-p1-3-nonce!")),
		TrustRootID:           refTrustRoot,
		RequiredSignatures:    2,
	}
}

// dualSignedToken returns a token signed by Alice then Bob, and a registry
// holding both keys plus Mallory's (registered, so "unknown key" and "wrong
// signer" stay distinguishable faults).
func dualSignedToken(t *testing.T) (ResumeToken, *StaticOperatorKeyRegistry) {
	t.Helper()
	alicePub, alicePriv := keyFromSeed(t, seedOperatorAlice)
	bobPub, bobPriv := keyFromSeed(t, seedOperatorBob)
	malPub, _ := keyFromSeed(t, seedOperatorMal)

	token, err := SignResumeToken(unsignedToken(), opAlice, alicePriv, refNow.Add(-2*time.Minute))
	if err != nil {
		t.Fatalf("alice sign: %v", err)
	}
	token, err = SignResumeToken(token, opBob, bobPriv, refNow.Add(-90*time.Second))
	if err != nil {
		t.Fatalf("bob sign: %v", err)
	}
	reg := NewStaticOperatorKeyRegistry(
		OperatorKeyEntry{OperatorID: opAlice, KeyID: ComputeKeyID(alicePub), PublicKey: alicePub},
		OperatorKeyEntry{OperatorID: opBob, KeyID: ComputeKeyID(bobPub), PublicKey: bobPub},
		OperatorKeyEntry{OperatorID: opMal, KeyID: ComputeKeyID(malPub), PublicKey: malPub},
	)
	return token, reg
}

const refTrustRoot = "signalloom-operator-root/2026-q3"

func dualPolicy() ResumeTokenPolicy {
	return DefaultResumeTokenPolicy("signalloom-fleet/local", refTrustRoot)
}

// TestResumeTokenHappyPath is the positive control. Everything below mutates
// this exact token, so if this one does not verify the whole table is vacuous.
func TestResumeTokenHappyPath(t *testing.T) {
	token, reg := dualSignedToken(t)
	if err := VerifyResumeToken(token, refTarget(), reg, dualPolicy(), refNow); err != nil {
		t.Fatalf("a correctly dual-signed token must verify, got: %v", err)
	}
	if len(token.Signatures) != 2 {
		t.Fatalf("expected 2 signatures, got %d", len(token.Signatures))
	}
	if token.Signature != token.Signatures[0].Signature || token.OperatorID != token.Signatures[0].OperatorID {
		t.Error("the scalar projection was not populated by the first signature")
	}
	raw, err := base64.StdEncoding.DecodeString(token.Signature)
	if err != nil || len(raw) != ed25519.SignatureSize {
		t.Errorf("signature wire encoding must be base64(std) of exactly %d raw bytes, decoded %d (err=%v)", ed25519.SignatureSize, len(raw), err)
	}
	if n := len(token.Signature); n != 88 {
		t.Errorf("base64 std with padding of 64 bytes is 88 characters, got %d; P4-3 must be able to length-check the wire form", n)
	}
}

// TestSigningInputIsLengthPrefixedAndDomainSeparated pins the byte layout.
//
// This is the one thing a cross-module verifier cannot guess. If P4-3 builds a
// different byte string, every signature fails for a reason that has nothing to
// do with a bad signature — so the layout is asserted, not described.
func TestSigningInputIsLengthPrefixedAndDomainSeparated(t *testing.T) {
	tok := unsignedToken()
	tok.OperatorID = opAlice
	in := tok.SigningInput()

	if got := string(in[4 : 4+len(ResumeTokenSigningDomain)]); got != ResumeTokenSigningDomain {
		t.Errorf("signing input must open with the length-prefixed domain, got %q", got)
	}
	if in[0] != 0 || in[1] != 0 || in[2] != 0 || in[3] != byte(len(ResumeTokenSigningDomain)) {
		t.Errorf("domain length prefix must be 4-byte big-endian, got % x", in[:4])
	}

	// The property length-prefixing exists for: no reshuffle of adjacent field
	// content can produce the same bytes. Concatenation without prefixes would
	// make ("ab","c") and ("a","bc") identical.
	a := tok
	a.AgentID, a.Namespace = "ab", "c"
	b := tok
	b.AgentID, b.Namespace = "a", "bc"
	if string(a.SigningInput()) == string(b.SigningInput()) {
		t.Error("field boundaries are not encoded: two different field splits produced identical signing input")
	}

	// The per-signature input must extend the body, not replace it.
	sig := ResumeTokenSignature{OperatorID: opAlice, KeyID: "sha256:deadbeef", Algorithm: ResumeTokenAlgEd25519, SignedAt: refNow.Format(time.RFC3339)}
	full := SigningInputFor(tok, sig)
	if !strings.HasPrefix(string(full), string(in)) {
		t.Error("per-signature input must be the token body followed by the signer's own fields")
	}
	if len(full) <= len(in) {
		t.Error("per-signature input adds no signer binding; the signature would be transplantable")
	}
}

// TestVerifyResumeTokenRejects is the fault table. Each case mutates the happy
// token in exactly one way and names the sentinel it must produce.
//
// Distinct sentinels are asserted, not just "an error": every one of these is
// indistinguishable from "bad signature" on the wire unless the verifier says
// which, and an operator holding a valid token who is told only "unauthorized"
// will conclude the mechanism is broken and reach for the shared secret.
func TestVerifyResumeTokenRejects(t *testing.T) {
	_, malPriv := keyFromSeed(t, seedOperatorMal)
	_, alicePriv := keyFromSeed(t, seedOperatorAlice)
	unknownPriv := ed25519.NewKeyFromSeed([]byte("SLER-P1-3 operator NOT in registry"[:ed25519.SeedSize]))

	cases := []struct {
		name    string
		mutate  func(*ResumeToken, *StaticOperatorKeyRegistry)
		target  *TargetRef
		policy  *ResumeTokenPolicy
		now     *time.Time
		wantErr error
	}{
		{
			name:    "body tampered after signing",
			mutate:  func(tk *ResumeToken, _ *StaticOperatorKeyRegistry) { tk.GovernanceApprovalRef = "CHG-FORGED" },
			wantErr: ErrResumeTokenBadSignature,
		},
		{
			name: "signature transplanted onto a different signer",
			mutate: func(tk *ResumeToken, _ *StaticOperatorKeyRegistry) {
				// Keep Alice's signature bytes, relabel the entry as Mallory.
				// Without per-signature identity binding this would verify and
				// the forensic record would name the wrong human.
				tk.Signatures[1].OperatorID = opMal
			},
			wantErr: ErrResumeTokenOperatorMismatch,
		},
		{
			name: "key id re-pointed at another registered key",
			mutate: func(tk *ResumeToken, reg *StaticOperatorKeyRegistry) {
				malPub, _ := keyFromSeedRaw(seedOperatorMal)
				entry := reg.Keys[tk.Signatures[1].KeyID]
				entry.PublicKey = malPub
				reg.Keys[tk.Signatures[1].KeyID] = entry
			},
			wantErr: ErrResumeTokenKeyIDMismatch,
		},
		{
			name: "signed by a key absent from the registry",
			mutate: func(tk *ResumeToken, _ *StaticOperatorKeyRegistry) {
				resigned, err := SignResumeToken(stripSignatures(*tk), opAlice, unknownPriv, refNow)
				if err != nil {
					panic(err)
				}
				*tk = resigned
			},
			wantErr: ErrResumeTokenUnknownKey,
		},
		{
			name: "signed by a revoked key",
			mutate: func(tk *ResumeToken, reg *StaticOperatorKeyRegistry) {
				entry := reg.Keys[tk.Signatures[0].KeyID]
				entry.Revoked = true
				reg.Keys[tk.Signatures[0].KeyID] = entry
			},
			wantErr: ErrResumeTokenRevokedKey,
		},
		{
			name:    "expired",
			now:     timePtr(refNow.Add(30 * time.Minute)),
			wantErr: ErrResumeTokenExpired,
		},
		{
			name:    "not yet valid",
			now:     timePtr(refNow.Add(-30 * time.Minute)),
			wantErr: ErrResumeTokenNotYetValid,
		},
		{
			name:    "target agent mismatch",
			target:  &TargetRef{AgentID: "agent-cardvault", Namespace: "fe-signalloom-agents"},
			wantErr: ErrResumeTokenTargetMismatch,
		},
		{
			name:    "target namespace mismatch",
			target:  &TargetRef{AgentID: "agent-llm-classifier", Namespace: "fe-signalloom-prod"},
			wantErr: ErrResumeTokenTargetMismatch,
		},
		{
			name:    "audience mismatch",
			policy:  policyPtr(DefaultResumeTokenPolicy("signalloom-fleet/production", refTrustRoot)),
			wantErr: ErrResumeTokenAudienceMismatch,
		},
		{
			name: "lifetime exceeds policy maximum",
			mutate: func(tk *ResumeToken, _ *StaticOperatorKeyRegistry) {
				body := stripSignatures(*tk)
				body.ExpiresAt = refNow.Add(72 * time.Hour).Format(time.RFC3339)
				resigned, err := SignResumeToken(body, opAlice, alicePriv, refNow)
				if err != nil {
					panic(err)
				}
				*tk = resigned
			},
			policy:  policyPtr(ResumeTokenPolicy{RequiredSignatures: 1, Audience: "signalloom-fleet/local", MaxLifetime: 15 * time.Minute, ClockSkew: time.Minute, TrustRootID: refTrustRoot}),
			wantErr: ErrResumeTokenLifetimeTooLong,
		},
		{
			name: "single signature under a dual-control policy",
			mutate: func(tk *ResumeToken, _ *StaticOperatorKeyRegistry) {
				tk.Signatures = tk.Signatures[:1]
			},
			wantErr: ErrResumeTokenInsufficientSignature,
		},
		{
			name: "same operator signing twice is not dual control",
			mutate: func(tk *ResumeToken, _ *StaticOperatorKeyRegistry) {
				body := stripSignatures(*tk)
				once, err := SignResumeToken(body, opAlice, alicePriv, refNow)
				if err != nil {
					panic(err)
				}
				twice, err := SignResumeToken(once, opAlice, alicePriv, refNow)
				if err != nil {
					panic(err)
				}
				*tk = twice
			},
			wantErr: ErrResumeTokenDuplicateSigner,
		},
		{
			name: "unsupported algorithm on the token",
			mutate: func(tk *ResumeToken, _ *StaticOperatorKeyRegistry) {
				tk.Algorithm = "hmac-sha256"
			},
			wantErr: ErrResumeTokenUnsupportedAlgorithm,
		},
		{
			name: "unsupported algorithm on a signature entry",
			mutate: func(tk *ResumeToken, _ *StaticOperatorKeyRegistry) {
				tk.Signatures[1].Algorithm = "ecdsa-p256"
			},
			wantErr: ErrResumeTokenUnsupportedAlgorithm,
		},
		{
			name: "signature is not 64 raw bytes",
			mutate: func(tk *ResumeToken, _ *StaticOperatorKeyRegistry) {
				tk.Signatures[1].Signature = base64.StdEncoding.EncodeToString([]byte("far too short"))
			},
			wantErr: ErrResumeTokenMalformed,
		},
		{
			name: "scalar projection disagrees with signatures[0]",
			mutate: func(tk *ResumeToken, _ *StaticOperatorKeyRegistry) {
				tk.OperatorID = opBob
			},
			wantErr: ErrResumeTokenProjectionMismatch,
		},
		{
			name: "nonce carries too little entropy",
			mutate: func(tk *ResumeToken, _ *StaticOperatorKeyRegistry) {
				tk.Nonce = base64.StdEncoding.EncodeToString([]byte("short"))
			},
			wantErr: ErrResumeTokenShortNonce,
		},
		{
			name: "schema version is not the frozen one",
			mutate: func(tk *ResumeToken, _ *StaticOperatorKeyRegistry) {
				tk.SchemaVersion = "sler.signalloom.io/v1alpha2"
			},
			wantErr: ErrResumeTokenSchemaVersion,
		},
		{
			name: "required claim missing",
			mutate: func(tk *ResumeToken, _ *StaticOperatorKeyRegistry) {
				tk.GovernanceApprovalRef = ""
			},
			wantErr: ErrResumeTokenMalformed,
		},
		{
			name: "no signatures at all",
			mutate: func(tk *ResumeToken, _ *StaticOperatorKeyRegistry) {
				tk.Signatures = nil
			},
			wantErr: ErrResumeTokenMalformed,
		},
		{
			name: "an extra invalid signature alongside two valid ones",
			mutate: func(tk *ResumeToken, _ *StaticOperatorKeyRegistry) {
				// Mallory appends a signature over the WRONG bytes. Counting
				// "at least two valid" rather than "all valid" would let this
				// through and leave the rejection reason ambiguous.
				bogus := ResumeTokenSignature{
					OperatorID: opMal,
					KeyID:      ComputeKeyID(malPriv.Public().(ed25519.PublicKey)),
					Algorithm:  ResumeTokenAlgEd25519,
					SignedAt:   refNow.Format(time.RFC3339),
					Signature:  base64.StdEncoding.EncodeToString(ed25519.Sign(malPriv, []byte("not the signing input"))),
				}
				tk.Signatures = append(tk.Signatures, bogus)
			},
			wantErr: ErrResumeTokenBadSignature,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			token, reg := dualSignedToken(t)
			if tc.mutate != nil {
				tc.mutate(&token, reg)
			}
			target := refTarget()
			if tc.target != nil {
				target = *tc.target
			}
			policy := dualPolicy()
			if tc.policy != nil {
				policy = *tc.policy
			}
			now := refNow
			if tc.now != nil {
				now = *tc.now
			}
			err := VerifyResumeToken(token, target, reg, policy, now)
			if err == nil {
				t.Fatalf("expected rejection with %v, token verified", tc.wantErr)
			}
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("expected %v, got %v", tc.wantErr, err)
			}
		})
	}
}

// ── Cases predicted by the commitment-boundary advisor review ────────────────

// TestQuorumStrippingIsRejectedByTheSignedThreshold.
//
// The advisor's highest-probability finding: "every signature must verify" is a
// VALIDITY predicate, not a QUORUM one. An attacker who observes a genuine
// two-approval token strips one signature; the remainder satisfies every other
// check, and the attested record then shows a legitimate-looking single-operator
// resume. The fix is the signed required_signatures claim, enforced as
// max(policy, token) — the token can raise the bar, never lower it.
func TestQuorumStrippingIsRejectedByTheSignedThreshold(t *testing.T) {
	token, reg := dualSignedToken(t)
	stripped := token
	stripped.Signatures = token.Signatures[:1]

	// Even a verifier whose OWN policy would accept one signature must refuse,
	// because the surviving signed body still records that two were required.
	permissive := ResumeTokenPolicy{
		RequiredSignatures: 1,
		Audience:           "signalloom-fleet/local",
		TrustRootID:        refTrustRoot,
		MaxLifetime:        15 * time.Minute,
		ClockSkew:          time.Minute,
	}
	err := VerifyResumeToken(stripped, refTarget(), reg, permissive, refNow)
	if !errors.Is(err, ErrResumeTokenInsufficientSignature) {
		t.Fatalf("a stripped co-approval must be rejected on the token's own threshold, got %v", err)
	}

	// And an attacker cannot mint their way around it by claiming 1, because
	// the effective threshold is the maximum, not the token's value.
	_, malPriv := keyFromSeed(t, seedOperatorMal)
	forged := stripSignatures(unsignedToken())
	forged.RequiredSignatures = 1
	forged, err = SignResumeToken(forged, opMal, malPriv, refNow)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	if err := VerifyResumeToken(forged, refTarget(), reg, dualPolicy(), refNow); !errors.Is(err, ErrResumeTokenInsufficientSignature) {
		t.Fatalf("a token claiming a threshold of 1 must not lower a dual-control policy, got %v", err)
	}
}

// TestTrustRootMismatchIsRejected. A token minted for one operator-key trust
// root must not verify at a fleet pinning a different one.
func TestTrustRootMismatchIsRejected(t *testing.T) {
	token, reg := dualSignedToken(t)
	policy := dualPolicy()
	policy.TrustRootID = "signalloom-operator-root/2025-q1"
	if err := VerifyResumeToken(token, refTarget(), reg, policy, refNow); !errors.Is(err, ErrResumeTokenTrustRootMismatch) {
		t.Fatalf("expected trust root mismatch, got %v", err)
	}
}

// TestRegistryWriteAdversaryIsNotClosedByTheTokenFormat documents a RESIDUAL.
//
// This test asserts that the attack SUCCEEDS, and that is deliberate. The
// self-certifying key_id closes registry MIS-INDEXING — an existing entry
// re-pointed at a different key — because the verifier recomputes the
// fingerprint. It does NOT close an adversary who can WRITE the registry and
// add a whole new entry binding their own key to a victim's operator_id: every
// check then passes cleanly, and the self-certifying handle makes the
// substitution MORE silent, not less.
//
// No token format can close this; it is a trust-root problem. The contract's
// response is to name the root in the signed body (TrustRootID) so the pinning
// obligation is part of the wire contract, and to route "who may write the
// operator key registry at runtime, and is that the same write path an agent
// compromise reaches" to P1-GOV as an open question.
//
// The test exists so the boundary is asserted rather than assumed. If a future
// change closes the attack, this test fails and someone re-reads the residual.
func TestRegistryWriteAdversaryIsNotClosedByTheTokenFormat(t *testing.T) {
	_, malPriv := keyFromSeed(t, seedOperatorMal)
	malPub, _ := keyFromSeedRaw(seedOperatorMal)
	_, bobPriv := keyFromSeed(t, seedOperatorBob)
	bobPub, _ := keyFromSeedRaw(seedOperatorBob)

	// Mallory writes an entry binding HER OWN key to Alice's operator id.
	poisoned := NewStaticOperatorKeyRegistry(
		OperatorKeyEntry{OperatorID: opAlice, KeyID: ComputeKeyID(malPub), PublicKey: malPub},
		OperatorKeyEntry{OperatorID: opBob, KeyID: ComputeKeyID(bobPub), PublicKey: bobPub},
	)
	token, err := SignResumeToken(unsignedToken(), opAlice, malPriv, refNow)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	token, err = SignResumeToken(token, opBob, bobPriv, refNow)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}

	err = VerifyResumeToken(token, refTarget(), poisoned, dualPolicy(), refNow)
	if err != nil {
		t.Fatalf("RESIDUAL CHANGED: a registry-write adversary is now caught (%v). "+
			"That is good news, but docs/signalloom/sler-p1-3-frozen-contract.md section 7 documents this as an OPEN residual routed to P1-GOV. "+
			"Update the document before changing this test.", err)
	}
	t.Log("documented residual confirmed: a registry-WRITE adversary defeats operator attribution; " +
		"TrustRootID makes the pinning obligation explicit but registry integrity is P4-3's to deliver")
}

// TestCoApprovalsMustBeContemporaneous. Dual control means two people looked at
// the same incident at roughly the same time, not one signature banked weeks
// before the other.
func TestCoApprovalsMustBeContemporaneous(t *testing.T) {
	_, alicePriv := keyFromSeed(t, seedOperatorAlice)
	alicePub, _ := keyFromSeedRaw(seedOperatorAlice)
	_, bobPriv := keyFromSeed(t, seedOperatorBob)
	bobPub, _ := keyFromSeedRaw(seedOperatorBob)

	body := stripSignatures(unsignedToken())
	body.IssuedAt = refNow.Add(-60 * time.Minute).Format(time.RFC3339)
	body.ExpiresAt = refNow.Add(60 * time.Minute).Format(time.RFC3339)

	token, err := SignResumeToken(body, opAlice, alicePriv, refNow.Add(-55*time.Minute))
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	token, err = SignResumeToken(token, opBob, bobPriv, refNow.Add(-1*time.Minute))
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	reg := NewStaticOperatorKeyRegistry(
		OperatorKeyEntry{OperatorID: opAlice, KeyID: ComputeKeyID(alicePub), PublicKey: alicePub},
		OperatorKeyEntry{OperatorID: opBob, KeyID: ComputeKeyID(bobPub), PublicKey: bobPub},
	)
	policy := dualPolicy()
	policy.MaxLifetime = 3 * time.Hour
	if err := VerifyResumeToken(token, refTarget(), reg, policy, refNow); !errors.Is(err, ErrResumeTokenApprovalWindowExceed) {
		t.Fatalf("54 minutes between co-approvals must exceed a 10-minute window, got %v", err)
	}

	policy.MaxApprovalWindow = 0 // disabled
	if err := VerifyResumeToken(token, refTarget(), reg, policy, refNow); err != nil {
		t.Errorf("with the window disabled the same token must verify: %v", err)
	}
}

// TestSignatureMadeOutsideTheTokenWindowIsRejected. A signature dated outside
// the token's own validity is not a co-approval OF THIS TOKEN.
func TestSignatureMadeOutsideTheTokenWindowIsRejected(t *testing.T) {
	token, reg := dualSignedToken(t)
	token.Signatures[1].SignedAt = refNow.Add(-72 * time.Hour).Format(time.RFC3339)
	if err := VerifyResumeToken(token, refTarget(), reg, dualPolicy(), refNow); !errors.Is(err, ErrResumeTokenSignedAtOutOfWindow) {
		t.Fatalf("expected signed_at window rejection, got %v", err)
	}
}

// TestSchemaVersionAndSigningDomainCannotDisagree. The advisor flagged
// separator/version confusion: if schema_version were attacker-controlled while
// the domain separator is a verifier constant, the two could diverge.
// ValidateStructure pins schema_version to the frozen value before any
// signature is checked, so the pair cannot disagree by construction.
func TestSchemaVersionAndSigningDomainCannotDisagree(t *testing.T) {
	if !strings.HasSuffix(ResumeTokenSigningDomain, "/v1alpha1") {
		t.Fatalf("the signing domain %q must carry the schema version it belongs to", ResumeTokenSigningDomain)
	}
	if !strings.HasSuffix(FrozenSchemaVersion, "/v1alpha1") {
		t.Fatalf("frozen schema version %q and signing domain must name the same version", FrozenSchemaVersion)
	}
	token, reg := dualSignedToken(t)
	token.SchemaVersion = "sler.signalloom.io/v1"
	if err := VerifyResumeToken(token, refTarget(), reg, dualPolicy(), refNow); !errors.Is(err, ErrResumeTokenSchemaVersion) {
		t.Fatalf("a token naming a different schema version must be refused before any signature check, got %v", err)
	}
}

// TestClockSkewIsToleratedOnBothBounds. A node under containment may have lost
// whatever was disciplining its clock, so a token minted seconds ago must not
// be rejected as not-yet-valid by a node running slightly slow.
func TestClockSkewIsToleratedOnBothBounds(t *testing.T) {
	token, reg := dualSignedToken(t)
	issued, _ := time.Parse(time.RFC3339, token.IssuedAt)
	expires, _ := time.Parse(time.RFC3339, token.ExpiresAt)
	policy := dualPolicy()

	if err := VerifyResumeToken(token, refTarget(), reg, policy, issued.Add(-30*time.Second)); err != nil {
		t.Errorf("a node 30s slow inside a 60s skew allowance must accept: %v", err)
	}
	if err := VerifyResumeToken(token, refTarget(), reg, policy, expires.Add(30*time.Second)); err != nil {
		t.Errorf("a node 30s fast inside a 60s skew allowance must accept: %v", err)
	}
	if err := VerifyResumeToken(token, refTarget(), reg, policy, expires.Add(5*time.Minute)); !errors.Is(err, ErrResumeTokenExpired) {
		t.Errorf("skew tolerance must not become an unbounded extension, got %v", err)
	}
}

// TestSingleOperatorPolicyIsRepresentable. Dual control is the default, not the
// only shape: a documented emergency policy may permit one operator.
func TestSingleOperatorPolicyIsRepresentable(t *testing.T) {
	_, alicePriv := keyFromSeed(t, seedOperatorAlice)
	alicePub, _ := keyFromSeedRaw(seedOperatorAlice)
	// A single-operator break-glass token must be MINTED as one. Reusing a body
	// that records a threshold of 2 correctly fails, because max(policy, token)
	// never lets the verifier drop below what the approval recorded.
	body := unsignedToken()
	body.RequiredSignatures = 1
	token, err := SignResumeToken(body, opAlice, alicePriv, refNow)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	reg := NewStaticOperatorKeyRegistry(OperatorKeyEntry{OperatorID: opAlice, KeyID: ComputeKeyID(alicePub), PublicKey: alicePub})
	policy := ResumeTokenPolicy{RequiredSignatures: 1, Audience: "signalloom-fleet/local", MaxLifetime: 15 * time.Minute, ClockSkew: time.Minute, TrustRootID: refTrustRoot}
	if err := VerifyResumeToken(token, refTarget(), reg, policy, refNow); err != nil {
		t.Errorf("single-operator break-glass must be representable: %v", err)
	}
}

// TestComputeKeyIDIsSelfCertifying.
func TestComputeKeyIDIsSelfCertifying(t *testing.T) {
	alicePub, _ := keyFromSeedRaw(seedOperatorAlice)
	bobPub, _ := keyFromSeedRaw(seedOperatorBob)
	a, b := ComputeKeyID(alicePub), ComputeKeyID(bobPub)
	if a == b {
		t.Fatal("two distinct keys produced the same key id")
	}
	if !strings.HasPrefix(a, ResumeTokenKeyIDPrefix) {
		t.Errorf("key id %q does not carry the %q prefix", a, ResumeTokenKeyIDPrefix)
	}
	if want := len(ResumeTokenKeyIDPrefix) + 64; len(a) != want {
		t.Errorf("key id is %d chars, want %d (prefix + 64 hex chars of SHA-256)", len(a), want)
	}
	if ComputeKeyID(alicePub) != a {
		t.Error("ComputeKeyID is not deterministic")
	}
}

// TestSharedSecretCannotAttribute is an executable statement of the finding
// this card exists to record.
//
// It is a property test about bearer credentials, not about any particular
// implementation: with one shared value, the bytes two different operators
// present are identical, so no verifier — however written — can tell them
// apart. With per-operator keys over identical claims, the presented bytes
// differ. That difference IS attribution, and nothing else supplies it.
func TestSharedSecretCannotAttribute(t *testing.T) {
	const sharedSecret = "resume-governor-token" // the STUN_RESUME_TOKEN shape
	alicePresents, bobPresents := sharedSecret, sharedSecret
	if alicePresents != bobPresents {
		t.Fatal("test is malformed: a shared secret is by definition the same value")
	}

	_, alicePriv := keyFromSeed(t, seedOperatorAlice)
	_, bobPriv := keyFromSeed(t, seedOperatorBob)
	body := unsignedToken()
	aliceToken, err := SignResumeToken(body, opAlice, alicePriv, refNow)
	if err != nil {
		t.Fatalf("alice: %v", err)
	}
	bobToken, err := SignResumeToken(body, opBob, bobPriv, refNow)
	if err != nil {
		t.Fatalf("bob: %v", err)
	}
	if aliceToken.Signature == bobToken.Signature {
		t.Fatal("two operators signing the same claims produced identical bytes; attribution would be impossible")
	}
}

// TestGenerateWorkedExamples regenerates the published example payloads.
//
// Guarded because it writes into docs/. It is the maintenance path for the
// artefacts TestWorkedExamplesDecodeUnderTheFrozenContract validates, so the
// examples can be regenerated after an APPROVED bump instead of hand-edited
// into agreement.
//
//	SLER_WRITE_EXAMPLES=1 go test -run TestGenerateWorkedExamples -v .
func TestGenerateWorkedExamples(t *testing.T) {
	if os.Getenv("SLER_WRITE_EXAMPLES") != "1" {
		t.Skip("set SLER_WRITE_EXAMPLES=1 to regenerate docs/signalloom worked examples")
	}
	token, _ := dualSignedToken(t)
	raw, err := json.MarshalIndent(token, "", "  ")
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	wd, _ := os.Getwd()
	out := filepath.Join(wd, "..", "..", "..", "docs/signalloom/sler-p1-3-example-resume-token.json")
	if err := os.WriteFile(out, append(raw, '\n'), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	t.Logf("wrote %s", out)
}

// ── helpers ──────────────────────────────────────────────────────────────────

func keyFromSeedRaw(seed string) (ed25519.PublicKey, ed25519.PrivateKey) {
	priv := ed25519.NewKeyFromSeed([]byte(seed))
	return priv.Public().(ed25519.PublicKey), priv
}

func stripSignatures(tk ResumeToken) ResumeToken {
	tk.Signatures = nil
	tk.Signature = ""
	tk.OperatorID = ""
	return tk
}

func timePtr(t time.Time) *time.Time                   { return &t }
func policyPtr(p ResumeTokenPolicy) *ResumeTokenPolicy { return &p }
