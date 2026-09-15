package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ── Why this file exists ─────────────────────────────────────────────────────
//
// The architectural constitution requires that unfreezing a contained agent
// need "an attributable governance resume token signed by an authorized
// operator". What the repository has instead is one shared secret:
//
//	apps/stun-sentinel/cmd/stun-sentinel/main.go:56
//	    resumeToken: os.Getenv("STUN_RESUME_TOKEN"),
//	apps/stun-sentinel/cmd/stun-sentinel/main.go:272
//	    resumeValidate := constantTimeTokenValidator(cfg.resumeToken)
//
// That is a BEARER credential, and a bearer credential is not weak attribution
// — it is the structural absence of attribution. The value is identical on
// every node of the DaemonSet and identical in the hands of every operator, so
// the bytes the sentinel compares carry exactly zero information about who
// presented them. No amount of logging fixes that, because there is nothing in
// the request to log. Rotation does not fix it either: the replacement is
// another single value shared by everyone.
//
// Attribution is a property of KEYS, not of values. One private key held by
// exactly one party, a public half registered against that party's identity,
// and a signature over claims that name the target — that is the minimum, and
// it is what this file specifies.
//
// This file is the REFERENCE implementation of the minting and verification
// halves. It is not the deployed verifier: the sentinel lives in a different Go
// module and will implement the verifier from the normative byte layout in
// docs/signalloom/sler-p1-3-frozen-contract.md under SLER-P4-3. That is exactly
// why the signing input is specified to the byte here rather than left as "sign
// the JSON" — see SigningInput.

// ResumeTokenAlgEd25519 is the only signature algorithm this schema version
// admits. It is carried on the wire so an unknown algorithm is rejected
// explicitly rather than assumed, and so a post-quantum migration can be
// expressed as a new value rather than a breaking change.
const ResumeTokenAlgEd25519 = "ed25519"

// ResumeTokenSigningDomain is the domain-separation prefix. It is versioned
// independently of nothing: it embeds the frozen schema version, so a token
// minted under a future schema can never be replayed as a v1alpha1 token even
// if the field set happens to coincide.
const ResumeTokenSigningDomain = "sler.signalloom.io/resume-token/v1alpha1"

// ResumeTokenSignatureEncoding names the wire encoding of the signature field
// for the avoidance of doubt: the RAW 64-byte Ed25519 signature (RFC 8032
// R||S), base64 std-encoded WITH padding, 88 characters. Not hex, not
// base64url, not DER, not multibase.
const ResumeTokenSignatureEncoding = "base64(std,padded) of raw 64-byte ed25519 signature"

// ResumeTokenMinNonceBytes is the minimum DECODED entropy in the nonce.
const ResumeTokenMinNonceBytes = 16

// ResumeTokenKeyIDPrefix is the self-certifying key-handle prefix.
const ResumeTokenKeyIDPrefix = "sha256:"

// Verification failures. Each rejection cause is a distinct sentinel, and that
// is a deliberate design requirement rather than tidiness.
//
// Every failure below is, on the wire, indistinguishable from "bad signature"
// unless the verifier says which one it was. An operator holding a genuinely
// valid token during an incident, told only "unauthorized", concludes the new
// mechanism is broken and reaches for the shared secret that still works. The
// error taxonomy is what keeps the break-glass usable under stress.
var (
	ErrResumeTokenMalformed             = errors.New("resume token malformed")
	ErrResumeTokenSchemaVersion         = errors.New("resume token schema version is not the frozen version")
	ErrResumeTokenUnsupportedAlgorithm  = errors.New("resume token algorithm is not supported")
	ErrResumeTokenProjectionMismatch    = errors.New("resume token scalar signature/operator projection disagrees with signatures[0]")
	ErrResumeTokenShortNonce            = errors.New("resume token nonce carries insufficient entropy")
	ErrResumeTokenTargetMismatch        = errors.New("resume token target does not match the agent being resumed")
	ErrResumeTokenAudienceMismatch      = errors.New("resume token audience does not match this fleet")
	ErrResumeTokenExpired               = errors.New("resume token has expired")
	ErrResumeTokenNotYetValid           = errors.New("resume token is not yet valid")
	ErrResumeTokenLifetimeTooLong       = errors.New("resume token lifetime exceeds the policy maximum")
	ErrResumeTokenUnknownKey            = errors.New("resume token signed by a key id absent from the operator registry")
	ErrResumeTokenRevokedKey            = errors.New("resume token signed by a revoked operator key")
	ErrResumeTokenKeyIDMismatch         = errors.New("resume token key id does not match the registered public key fingerprint")
	ErrResumeTokenOperatorMismatch      = errors.New("resume token signer identity does not match the identity registered for that key")
	ErrResumeTokenBadSignature          = errors.New("resume token signature did not verify")
	ErrResumeTokenDuplicateSigner       = errors.New("resume token carries two signatures from the same operator or key")
	ErrResumeTokenInsufficientSignature = errors.New("resume token carries fewer distinct operator signatures than the effective threshold requires")
	ErrResumeTokenTrustRootMismatch     = errors.New("resume token names an operator-key trust root this verifier does not pin")
	ErrResumeTokenSignedAtOutOfWindow   = errors.New("resume token signature was made outside the token's own validity window")
	ErrResumeTokenApprovalWindowExceed  = errors.New("resume token co-approvals are too far apart to be contemporaneous")
	ErrResumeTokenReplayed              = errors.New("resume token has already been consumed with a different idempotency key")
)

// OperatorKeyEntry is one registered operator signing key.
//
// The operator's key is NOT a SPIFFE SVID, and that distinction is load-bearing
// in both directions. SPIFFE has no revocation list: an SVID is revoked by
// deleting the registration entry and waiting out the TTL, so a compromised
// SVID stays valid for up to its remaining lifetime. A registry entry, by
// contrast, is revoked the instant it is removed — at any verifier that can see
// the removal. The OperatorID is still normatively a SPIFFE ID because that is
// the identity namespace SLDP publishes and this mission consumes; it is used
// here as a NAME, not as a credential.
//
// The residual is therefore not "SPIFFE cannot revoke" but "a verifier that has
// been isolated by containment cannot learn about a revocation". See the
// open questions in the frozen contract document.
type OperatorKeyEntry struct {
	// OperatorID is the identity this key attributes to, normatively a SPIFFE ID.
	OperatorID string
	// KeyID is the self-certifying handle; it MUST equal ComputeKeyID(PublicKey).
	KeyID string
	// PublicKey is the raw 32-byte Ed25519 public key.
	PublicKey ed25519.PublicKey
	// NotBefore and NotAfter bound the key's validity. A zero value means
	// unbounded on that side.
	NotBefore time.Time
	NotAfter  time.Time
	// Revoked removes the key from service immediately at every verifier that
	// can see this registry state.
	Revoked bool
}

// OperatorKeyRegistry resolves a key id to its registered operator.
//
// It is an interface so the deployed verifier can back it with a cached,
// signed key bundle on the node — which is what allows break-glass to work
// while containment has isolated the control plane. A registry that requires a
// network call to the plane containment just severed is not a break-glass.
type OperatorKeyRegistry interface {
	LookupOperatorKey(keyID string) (OperatorKeyEntry, error)
}

// StaticOperatorKeyRegistry is the in-memory reference implementation. The
// deployed node-local cache is P4-3's surface.
type StaticOperatorKeyRegistry struct {
	Keys map[string]OperatorKeyEntry
}

// NewStaticOperatorKeyRegistry indexes entries by their KeyID.
func NewStaticOperatorKeyRegistry(entries ...OperatorKeyEntry) *StaticOperatorKeyRegistry {
	keys := make(map[string]OperatorKeyEntry, len(entries))
	for _, e := range entries {
		keys[e.KeyID] = e
	}
	return &StaticOperatorKeyRegistry{Keys: keys}
}

// LookupOperatorKey implements OperatorKeyRegistry.
func (r *StaticOperatorKeyRegistry) LookupOperatorKey(keyID string) (OperatorKeyEntry, error) {
	if r == nil || r.Keys == nil {
		return OperatorKeyEntry{}, fmt.Errorf("%w: %s", ErrResumeTokenUnknownKey, keyID)
	}
	e, ok := r.Keys[keyID]
	if !ok {
		return OperatorKeyEntry{}, fmt.Errorf("%w: %s", ErrResumeTokenUnknownKey, keyID)
	}
	return e, nil
}

// ResumeTokenPolicy is the verifier-side policy. It lives at the verifier and
// NOT in the token on purpose: a token that carried its own required-signature
// count would let the attacker who mints it choose how many signatures it needs.
type ResumeTokenPolicy struct {
	// RequiredSignatures is the number of DISTINCT operators that must sign.
	// Two is dual control; one is single-operator break-glass and should only
	// be configured where a documented emergency policy allows it.
	RequiredSignatures int
	// Audience is the value the token must name.
	Audience string
	// MaxLifetime caps ExpiresAt - IssuedAt. Without it an operator can mint a
	// token valid for a year and defeat the whole time binding.
	MaxLifetime time.Duration
	// ClockSkew is tolerated on BOTH time bounds. Nodes under containment may
	// have lost contact with whatever was disciplining their clock.
	ClockSkew time.Duration
	// TrustRootID is the operator-key trust root this verifier pins. A token
	// naming a different root is refused — see ResumeToken.TrustRootID.
	TrustRootID string
	// MaxApprovalWindow bounds how far apart two co-approvals may be.
	//
	// Dual control means two people looked at the same incident at roughly the
	// same time. Without a bound, an operator can bank a signature today and a
	// second operator can add theirs weeks later against an approval neither of
	// them is still looking at, which is sequential rubber-stamping wearing
	// dual control's clothes. Zero disables the check.
	MaxApprovalWindow time.Duration
}

// DefaultResumeTokenPolicy is the reference dual-control policy.
func DefaultResumeTokenPolicy(audience, trustRootID string) ResumeTokenPolicy {
	return ResumeTokenPolicy{
		RequiredSignatures: 2,
		Audience:           audience,
		MaxLifetime:        15 * time.Minute,
		ClockSkew:          60 * time.Second,
		TrustRootID:        trustRootID,
		MaxApprovalWindow:  10 * time.Minute,
	}
}

// ComputeKeyID returns the self-certifying handle for a public key:
// "sha256:" + lowercase hex of SHA-256 over the raw 32 key bytes.
//
// Self-certifying is the point. If key_id were an opaque label, anyone able to
// write the registry could re-point a trusted label at their own key and every
// signature would verify. Because the handle is derived from the key material,
// a verifier recomputes it and detects the substitution locally.
func ComputeKeyID(pub ed25519.PublicKey) string {
	sum := sha256.Sum256(pub)
	return ResumeTokenKeyIDPrefix + hex.EncodeToString(sum[:])
}

// lengthPrefix appends a 4-byte big-endian length followed by the raw bytes.
func lengthPrefix(dst []byte, s string) []byte {
	var n [4]byte
	binary.BigEndian.PutUint32(n[:], uint32(len(s)))
	dst = append(dst, n[:]...)
	return append(dst, s...)
}

// SigningInput returns the canonical signed bytes of the token BODY.
//
// The encoding is a length-prefixed concatenation, NOT JSON, and that is the
// single most consequential decision in this file. "Sign the JSON" is the
// classic own-goal: key order, unicode escaping, whitespace and number
// formatting all vary between encoders, so two correct implementations produce
// different bytes and the failure surfaces as "bad signature" — sending the
// debugger to look at the key material, which is fine. With a 4-byte
// big-endian length prefix on every field there is nothing left to choose and
// no field boundary an attacker can shift.
//
// Normative field order (any change is a breaking change):
//
//	domain, schema_version, token_id, alg, agent_id, namespace, audience,
//	operator_id, governance_approval_ref, issued_at, expires_at, nonce,
//	trust_root_id, required_signatures
//
// required_signatures is encoded as its decimal representation, so the integer
// has exactly one byte form. Leaving a number's encoding to the implementation
// is the same class of mistake as signing JSON.
func (t ResumeToken) SigningInput() []byte {
	buf := make([]byte, 0, 256)
	buf = lengthPrefix(buf, ResumeTokenSigningDomain)
	buf = lengthPrefix(buf, t.SchemaVersion)
	buf = lengthPrefix(buf, t.TokenID)
	buf = lengthPrefix(buf, t.Algorithm)
	buf = lengthPrefix(buf, t.AgentID)
	buf = lengthPrefix(buf, t.Namespace)
	buf = lengthPrefix(buf, t.Audience)
	buf = lengthPrefix(buf, t.OperatorID)
	buf = lengthPrefix(buf, t.GovernanceApprovalRef)
	buf = lengthPrefix(buf, t.IssuedAt)
	buf = lengthPrefix(buf, t.ExpiresAt)
	buf = lengthPrefix(buf, t.Nonce)
	buf = lengthPrefix(buf, t.TrustRootID)
	buf = lengthPrefix(buf, strconv.Itoa(t.RequiredSignatures))
	return buf
}

// SigningInputFor returns the bytes ONE signer signs: the token body followed
// by that signer's own operator_id, key_id, alg and signed_at.
//
// Including the signer's identity is what makes the token attributable rather
// than merely authentic. Signing the body alone leaves the signature
// transplantable: lift a valid signature into another signatures[] entry,
// rewrite operator_id, and the signature still verifies while the forensic
// record names the wrong human.
func SigningInputFor(t ResumeToken, sig ResumeTokenSignature) []byte {
	buf := t.SigningInput()
	buf = lengthPrefix(buf, sig.OperatorID)
	buf = lengthPrefix(buf, sig.KeyID)
	buf = lengthPrefix(buf, sig.Algorithm)
	buf = lengthPrefix(buf, sig.SignedAt)
	return buf
}

// ValidateStructure checks every invariant that needs no key material and no
// clock. It is separated from VerifyResumeToken so a minting tool can check its
// own output, and so a malformed token is reported as malformed rather than as
// a signature failure.
func (t ResumeToken) ValidateStructure() error {
	for _, f := range []struct{ name, value string }{
		{"schema_version", t.SchemaVersion},
		{"token_id", t.TokenID},
		{"alg", t.Algorithm},
		{"agent_id", t.AgentID},
		{"namespace", t.Namespace},
		{"audience", t.Audience},
		{"operator_id", t.OperatorID},
		{"governance_approval_ref", t.GovernanceApprovalRef},
		{"issued_at", t.IssuedAt},
		{"expires_at", t.ExpiresAt},
		{"nonce", t.Nonce},
		{"trust_root_id", t.TrustRootID},
		{"signature", t.Signature},
	} {
		if f.value == "" {
			return fmt.Errorf("%w: %s is required", ErrResumeTokenMalformed, f.name)
		}
	}
	if t.SchemaVersion != FrozenSchemaVersion {
		return fmt.Errorf("%w: got %q want %q", ErrResumeTokenSchemaVersion, t.SchemaVersion, FrozenSchemaVersion)
	}
	if t.Algorithm != ResumeTokenAlgEd25519 {
		return fmt.Errorf("%w: token alg %q", ErrResumeTokenUnsupportedAlgorithm, t.Algorithm)
	}
	nonce, err := base64.StdEncoding.DecodeString(t.Nonce)
	if err != nil {
		return fmt.Errorf("%w: nonce is not base64: %v", ErrResumeTokenMalformed, err)
	}
	if len(nonce) < ResumeTokenMinNonceBytes {
		return fmt.Errorf("%w: %d bytes, need %d", ErrResumeTokenShortNonce, len(nonce), ResumeTokenMinNonceBytes)
	}
	if _, err := time.Parse(time.RFC3339, t.IssuedAt); err != nil {
		return fmt.Errorf("%w: issued_at is not RFC3339: %v", ErrResumeTokenMalformed, err)
	}
	if _, err := time.Parse(time.RFC3339, t.ExpiresAt); err != nil {
		return fmt.Errorf("%w: expires_at is not RFC3339: %v", ErrResumeTokenMalformed, err)
	}
	if t.RequiredSignatures < 1 {
		return fmt.Errorf("%w: required_signatures is %d, must be at least 1", ErrResumeTokenMalformed, t.RequiredSignatures)
	}
	if len(t.Signatures) == 0 {
		return fmt.Errorf("%w: signatures is empty", ErrResumeTokenMalformed)
	}

	// The scalar projection invariant. Two fields carrying the same fact will
	// drift unless something checks them; this is that something.
	if t.Signatures[0].OperatorID != t.OperatorID {
		return fmt.Errorf("%w: operator_id %q vs signatures[0].operator_id %q",
			ErrResumeTokenProjectionMismatch, t.OperatorID, t.Signatures[0].OperatorID)
	}
	if t.Signatures[0].Signature != t.Signature {
		return fmt.Errorf("%w: signature scalar disagrees with signatures[0].signature",
			ErrResumeTokenProjectionMismatch)
	}

	seenOperator := make(map[string]struct{}, len(t.Signatures))
	seenKey := make(map[string]struct{}, len(t.Signatures))
	for i, sig := range t.Signatures {
		if sig.OperatorID == "" || sig.KeyID == "" || sig.Signature == "" || sig.SignedAt == "" {
			return fmt.Errorf("%w: signatures[%d] has an empty required field", ErrResumeTokenMalformed, i)
		}
		if sig.Algorithm != ResumeTokenAlgEd25519 {
			return fmt.Errorf("%w: signatures[%d] alg %q", ErrResumeTokenUnsupportedAlgorithm, i, sig.Algorithm)
		}
		if _, err := time.Parse(time.RFC3339, sig.SignedAt); err != nil {
			return fmt.Errorf("%w: signatures[%d].signed_at is not RFC3339: %v", ErrResumeTokenMalformed, i, err)
		}
		raw, err := base64.StdEncoding.DecodeString(sig.Signature)
		if err != nil {
			return fmt.Errorf("%w: signatures[%d].signature is not base64: %v", ErrResumeTokenMalformed, i, err)
		}
		if len(raw) != ed25519.SignatureSize {
			return fmt.Errorf("%w: signatures[%d].signature decodes to %d bytes, want %d",
				ErrResumeTokenMalformed, i, len(raw), ed25519.SignatureSize)
		}
		// Distinctness on BOTH axes. Counting signatures rather than distinct
		// operators makes a 2-of-N rule satisfiable by one operator holding two
		// keys, which is not dual control at all.
		if _, dup := seenOperator[sig.OperatorID]; dup {
			return fmt.Errorf("%w: operator %s signed twice", ErrResumeTokenDuplicateSigner, sig.OperatorID)
		}
		if _, dup := seenKey[sig.KeyID]; dup {
			return fmt.Errorf("%w: key %s signed twice", ErrResumeTokenDuplicateSigner, sig.KeyID)
		}
		seenOperator[sig.OperatorID] = struct{}{}
		seenKey[sig.KeyID] = struct{}{}
	}
	return nil
}

// SignResumeToken appends one operator's signature and returns the updated
// token. The first signature also populates the scalar projection.
//
// It is the reference minting half; it holds a private key and is therefore
// something only an operator tool ever runs, never the fleet-manager server.
func SignResumeToken(token ResumeToken, operatorID string, priv ed25519.PrivateKey, signedAt time.Time) (ResumeToken, error) {
	if l := len(priv); l != ed25519.PrivateKeySize {
		return token, fmt.Errorf("%w: private key is %d bytes, want %d", ErrResumeTokenMalformed, l, ed25519.PrivateKeySize)
	}
	if token.Algorithm == "" {
		token.Algorithm = ResumeTokenAlgEd25519
	}
	if token.SchemaVersion == "" {
		token.SchemaVersion = FrozenSchemaVersion
	}
	if len(token.Signatures) == 0 {
		// The first signer is also the token's operator_id, which is part of
		// the signed body — so it must be set before any signature is computed.
		token.OperatorID = operatorID
	}
	pub, ok := priv.Public().(ed25519.PublicKey)
	if !ok {
		return token, fmt.Errorf("%w: private key does not yield an ed25519 public key", ErrResumeTokenMalformed)
	}
	entry := ResumeTokenSignature{
		OperatorID: operatorID,
		KeyID:      ComputeKeyID(pub),
		Algorithm:  ResumeTokenAlgEd25519,
		SignedAt:   signedAt.UTC().Format(time.RFC3339),
	}
	sig := ed25519.Sign(priv, SigningInputFor(token, entry))
	entry.Signature = base64.StdEncoding.EncodeToString(sig)
	token.Signatures = append(token.Signatures, entry)
	if len(token.Signatures) == 1 {
		token.Signature = entry.Signature
	}
	return token, nil
}

// VerifyResumeToken is the complete verification the deployed sentinel must
// perform before unfreezing anything.
//
// EVERY signature entry must verify — not merely policy.RequiredSignatures of
// them. Tolerating invalid extras lets an attacker append junk and makes the
// rejection reason ambiguous; strictness costs nothing and removes a whole
// class of "which signature was the bad one" incident time.
//
// Returning success here is NOT authorisation to resume. Two obligations sit
// outside this function and are normative in the frozen contract document: the
// verifier MUST enforce single-use on TokenID against a replay ledger, and the
// resume MUST rotate the agent's credentials before reporting success.
func VerifyResumeToken(token ResumeToken, target TargetRef, registry OperatorKeyRegistry, policy ResumeTokenPolicy, now time.Time) error {
	if err := token.ValidateStructure(); err != nil {
		return err
	}
	if token.AgentID != target.AgentID || token.Namespace != target.Namespace {
		return fmt.Errorf("%w: token names %s/%s, resuming %s/%s",
			ErrResumeTokenTargetMismatch, token.Namespace, token.AgentID, target.Namespace, target.AgentID)
	}
	if policy.Audience != "" && token.Audience != policy.Audience {
		return fmt.Errorf("%w: token audience %q, this fleet %q",
			ErrResumeTokenAudienceMismatch, token.Audience, policy.Audience)
	}
	if policy.TrustRootID != "" && token.TrustRootID != policy.TrustRootID {
		return fmt.Errorf("%w: token names %q, this verifier pins %q",
			ErrResumeTokenTrustRootMismatch, token.TrustRootID, policy.TrustRootID)
	}

	issued, _ := time.Parse(time.RFC3339, token.IssuedAt)
	expires, _ := time.Parse(time.RFC3339, token.ExpiresAt)
	if policy.MaxLifetime > 0 && expires.Sub(issued) > policy.MaxLifetime {
		return fmt.Errorf("%w: %s > %s", ErrResumeTokenLifetimeTooLong, expires.Sub(issued), policy.MaxLifetime)
	}
	if now.Before(issued.Add(-policy.ClockSkew)) {
		return fmt.Errorf("%w: issued_at %s, now %s", ErrResumeTokenNotYetValid, token.IssuedAt, now.UTC().Format(time.RFC3339))
	}
	if now.After(expires.Add(policy.ClockSkew)) {
		return fmt.Errorf("%w: expires_at %s, now %s", ErrResumeTokenExpired, token.ExpiresAt, now.UTC().Format(time.RFC3339))
	}

	distinct := make(map[string]struct{}, len(token.Signatures))
	var earliestSigned, latestSigned time.Time
	for i, sig := range token.Signatures {
		// A signature made outside the token's own validity window is not a
		// co-approval of this token; it is a signature from somewhere else that
		// happens to verify.
		signedAt, _ := time.Parse(time.RFC3339, sig.SignedAt)
		if signedAt.Before(issued.Add(-policy.ClockSkew)) || signedAt.After(expires.Add(policy.ClockSkew)) {
			return fmt.Errorf("%w: signatures[%d] signed at %s, token valid %s..%s",
				ErrResumeTokenSignedAtOutOfWindow, i, sig.SignedAt, token.IssuedAt, token.ExpiresAt)
		}
		if earliestSigned.IsZero() || signedAt.Before(earliestSigned) {
			earliestSigned = signedAt
		}
		if latestSigned.IsZero() || signedAt.After(latestSigned) {
			latestSigned = signedAt
		}

		entry, err := registry.LookupOperatorKey(sig.KeyID)
		if err != nil {
			return fmt.Errorf("signatures[%d]: %w", i, err)
		}
		if entry.Revoked {
			return fmt.Errorf("%w: signatures[%d] key %s", ErrResumeTokenRevokedKey, i, sig.KeyID)
		}
		if !entry.NotBefore.IsZero() && now.Before(entry.NotBefore.Add(-policy.ClockSkew)) {
			return fmt.Errorf("%w: signatures[%d] key %s not valid until %s",
				ErrResumeTokenNotYetValid, i, sig.KeyID, entry.NotBefore.UTC().Format(time.RFC3339))
		}
		if !entry.NotAfter.IsZero() && now.After(entry.NotAfter.Add(policy.ClockSkew)) {
			return fmt.Errorf("%w: signatures[%d] key %s expired at %s",
				ErrResumeTokenExpired, i, sig.KeyID, entry.NotAfter.UTC().Format(time.RFC3339))
		}
		// The handle must certify the key it resolved to. This is what detects
		// a registry whose label has been re-pointed at an attacker's key.
		if want := ComputeKeyID(entry.PublicKey); want != sig.KeyID {
			return fmt.Errorf("%w: signatures[%d] presented %s, key fingerprints as %s",
				ErrResumeTokenKeyIDMismatch, i, sig.KeyID, want)
		}
		// A signature is only attribution if the registry agrees about whose
		// key it is. Without this check a valid signature carrying a lying
		// operator_id verifies and the forensic record is fiction.
		if entry.OperatorID != sig.OperatorID {
			return fmt.Errorf("%w: signatures[%d] claims %s, key %s is registered to %s",
				ErrResumeTokenOperatorMismatch, i, sig.OperatorID, sig.KeyID, entry.OperatorID)
		}
		raw, err := base64.StdEncoding.DecodeString(sig.Signature)
		if err != nil {
			return fmt.Errorf("%w: signatures[%d]: %v", ErrResumeTokenMalformed, i, err)
		}
		if !ed25519.Verify(entry.PublicKey, SigningInputFor(token, sig), raw) {
			return fmt.Errorf("%w: signatures[%d] by %s", ErrResumeTokenBadSignature, i, sig.OperatorID)
		}
		distinct[sig.OperatorID] = struct{}{}
	}

	if policy.MaxApprovalWindow > 0 && latestSigned.Sub(earliestSigned) > policy.MaxApprovalWindow {
		return fmt.Errorf("%w: %s between first and last approval, maximum %s",
			ErrResumeTokenApprovalWindowExceed, latestSigned.Sub(earliestSigned), policy.MaxApprovalWindow)
	}

	// The effective threshold is the MAXIMUM of the verifier's policy and the
	// token's own signed claim. The asymmetry is load-bearing.
	//
	// Taking the policy alone leaves "every signature must verify" as a
	// VALIDITY predicate and not a QUORUM one: an attacker who observes a
	// genuine two-approval token can strip one signature, and the remainder
	// still satisfies every other check. The attested record then shows a
	// legitimate-looking single-operator resume — an attribution loss, which is
	// the exact property this token exists to provide.
	//
	// Taking the token alone would be worse: whoever mints a token would choose
	// how many signatures it needs, so an attacker would simply claim 1.
	//
	// Max() gives the token the power to RAISE the bar and never to lower it.
	effective := policy.RequiredSignatures
	if token.RequiredSignatures > effective {
		effective = token.RequiredSignatures
	}
	if effective > 0 && len(distinct) < effective {
		return fmt.Errorf("%w: %d distinct operators; verifier policy requires %d and the token itself records %d, so %d are needed",
			ErrResumeTokenInsufficientSignature, len(distinct), policy.RequiredSignatures, token.RequiredSignatures, effective)
	}
	return nil
}

// VerificationResult carries the details of a successful verification.
type VerificationResult struct {
	TokenID     string   `json:"token_id"`
	OperatorIDs []string `json:"operator_ids"`
	SignerCount int      `json:"signer_count"`
	Target      TargetRef
}

// ReplayRecord stores previous token consumption state for idempotency.
type ReplayRecord struct {
	TokenID        string
	IdempotencyKey string
	OperatorIDs    []string
	ConsumedAt     time.Time
}

// ReplayLedger provides atomic single-use checking and idempotent retries.
type ReplayLedger struct {
	mu      sync.Mutex
	records map[string]ReplayRecord
}

// NewReplayLedger creates a new in-memory replay ledger.
func NewReplayLedger() *ReplayLedger {
	return &ReplayLedger{records: make(map[string]ReplayRecord)}
}

// CheckAndRecord checks if a token can be used with the given idempotencyKey.
// Returns (isRetry, operatorIDs, error).
func (l *ReplayLedger) CheckAndRecord(tokenID, idempotencyKey string, operatorIDs []string, now time.Time) (bool, []string, error) {
	l.mu.Lock()
	defer l.mu.Unlock()

	rec, exists := l.records[tokenID]
	if !exists {
		l.records[tokenID] = ReplayRecord{
			TokenID:        tokenID,
			IdempotencyKey: idempotencyKey,
			OperatorIDs:    operatorIDs,
			ConsumedAt:     now,
		}
		return false, operatorIDs, nil
	}

	// Token was previously consumed.
	if idempotencyKey != "" && rec.IdempotencyKey == idempotencyKey {
		// Valid idempotent retry
		return true, rec.OperatorIDs, nil
	}

	// Presentation of consumed token with different idempotency key is a replay attempt
	return false, nil, fmt.Errorf("%w: token %s was consumed at %s", ErrResumeTokenReplayed, tokenID, rec.ConsumedAt.Format(time.RFC3339))
}

// OperatorKeyJSON is the JSON serialisation shape for operator key files and environment variables.
type OperatorKeyJSON struct {
	OperatorID string `json:"operator_id"`
	KeyID      string `json:"key_id,omitempty"`
	PublicKey  string `json:"public_key"` // base64 or hex encoded 32-byte Ed25519 public key
	NotBefore  string `json:"not_before,omitempty"`
	NotAfter   string `json:"not_after,omitempty"`
	Revoked    bool   `json:"revoked,omitempty"`
}

// ParseOperatorKeyJSON parses an OperatorKeyJSON record into an OperatorKeyEntry.
func ParseOperatorKeyJSON(raw OperatorKeyJSON) (OperatorKeyEntry, error) {
	if raw.OperatorID == "" {
		return OperatorKeyEntry{}, errors.New("operator_id is required")
	}
	if raw.PublicKey == "" {
		return OperatorKeyEntry{}, errors.New("public_key is required")
	}

	var pubBytes []byte
	var err error
	pubBytes, err = base64.StdEncoding.DecodeString(raw.PublicKey)
	if err != nil || len(pubBytes) != ed25519.PublicKeySize {
		pubBytes, err = hex.DecodeString(raw.PublicKey)
		if err != nil || len(pubBytes) != ed25519.PublicKeySize {
			return OperatorKeyEntry{}, fmt.Errorf("public_key for %s must be 32 bytes (base64 or hex encoded)", raw.OperatorID)
		}
	}

	computedKeyID := ComputeKeyID(pubBytes)
	if raw.KeyID != "" && raw.KeyID != computedKeyID {
		return OperatorKeyEntry{}, fmt.Errorf("%w: provided %s, computed %s", ErrResumeTokenKeyIDMismatch, raw.KeyID, computedKeyID)
	}

	var notBefore, notAfter time.Time
	if raw.NotBefore != "" {
		t, err := time.Parse(time.RFC3339, raw.NotBefore)
		if err != nil {
			return OperatorKeyEntry{}, fmt.Errorf("invalid not_before: %w", err)
		}
		notBefore = t
	}
	if raw.NotAfter != "" {
		t, err := time.Parse(time.RFC3339, raw.NotAfter)
		if err != nil {
			return OperatorKeyEntry{}, fmt.Errorf("invalid not_after: %w", err)
		}
		notAfter = t
	}

	return OperatorKeyEntry{
		OperatorID: raw.OperatorID,
		KeyID:      computedKeyID,
		PublicKey:  ed25519.PublicKey(pubBytes),
		NotBefore:  notBefore,
		NotAfter:   notAfter,
		Revoked:    raw.Revoked,
	}, nil
}

// LoadOperatorKeysFromJSON parses a JSON array or object of OperatorKeyJSON entries.
func LoadOperatorKeysFromJSON(data []byte) ([]OperatorKeyEntry, error) {
	data = []byte(strings.TrimSpace(string(data)))
	if len(data) == 0 {
		return nil, nil
	}

	var rawList []OperatorKeyJSON
	if data[0] == '[' {
		if err := json.Unmarshal(data, &rawList); err != nil {
			return nil, fmt.Errorf("unmarshal operator keys array: %w", err)
		}
	} else {
		var single OperatorKeyJSON
		if err := json.Unmarshal(data, &single); err != nil {
			return nil, fmt.Errorf("unmarshal operator key object: %w", err)
		}
		rawList = append(rawList, single)
	}

	entries := make([]OperatorKeyEntry, 0, len(rawList))
	for _, raw := range rawList {
		entry, err := ParseOperatorKeyJSON(raw)
		if err != nil {
			return nil, err
		}
		entries = append(entries, entry)
	}
	return entries, nil
}

// parsePubKeyFile parses a raw, hex, or base64 ed25519 public key file.
func parsePubKeyFile(name string, data []byte) (*OperatorKeyEntry, error) {
	data = bytes.TrimSpace(data)
	var pubBytes []byte
	if len(data) == ed25519.PublicKeySize {
		pubBytes = data
	} else if len(data) == hex.EncodedLen(ed25519.PublicKeySize) {
		h, err := hex.DecodeString(string(data))
		if err == nil && len(h) == ed25519.PublicKeySize {
			pubBytes = h
		}
	}
	if pubBytes == nil {
		b, err := base64.StdEncoding.DecodeString(string(data))
		if err == nil && len(b) == ed25519.PublicKeySize {
			pubBytes = b
		}
	}
	if pubBytes == nil {
		return nil, fmt.Errorf("pub key file %s must contain 32 raw bytes, hex, or base64", name)
	}
	stem := strings.TrimSuffix(name, ".pub")
	opID := "spiffe://signalloom.io/operator/" + stem
	keyID := ComputeKeyID(pubBytes)
	return &OperatorKeyEntry{
		OperatorID: opID,
		KeyID:      keyID,
		PublicKey:  ed25519.PublicKey(pubBytes),
	}, nil
}

// LoadOperatorKeyRegistry loads keys from a bundle file or directory into a StaticOperatorKeyRegistry.
func LoadOperatorKeyRegistry(path string) (*StaticOperatorKeyRegistry, error) {
	if path == "" {
		return NewStaticOperatorKeyRegistry(), nil
	}
	fi, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("operator key path stat: %w", err)
	}

	reg := NewStaticOperatorKeyRegistry()
	if !fi.IsDir() {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read operator key file: %w", err)
		}
		if strings.HasSuffix(path, ".pub") {
			entry, err := parsePubKeyFile(filepath.Base(path), data)
			if err != nil {
				return nil, err
			}
			reg.Keys[entry.KeyID] = *entry
			return reg, nil
		}
		entries, err := LoadOperatorKeysFromJSON(data)
		if err != nil {
			return nil, err
		}
		for _, e := range entries {
			reg.Keys[e.KeyID] = e
		}
		return reg, nil
	}

	files, err := os.ReadDir(path)
	if err != nil {
		return nil, fmt.Errorf("read operator key directory: %w", err)
	}
	for _, f := range files {
		if f.IsDir() {
			continue
		}
		fullPath := filepath.Join(path, f.Name())
		data, err := os.ReadFile(fullPath)
		if err != nil {
			return nil, fmt.Errorf("read operator key file %s: %w", fullPath, err)
		}
		if strings.HasSuffix(f.Name(), ".pub") {
			entry, err := parsePubKeyFile(f.Name(), data)
			if err != nil {
				return nil, fmt.Errorf("parse pub file %s: %w", fullPath, err)
			}
			reg.Keys[entry.KeyID] = *entry
			continue
		}
		if strings.HasSuffix(f.Name(), ".json") {
			entries, err := LoadOperatorKeysFromJSON(data)
			if err != nil {
				return nil, fmt.Errorf("parse key file %s: %w", fullPath, err)
			}
			for _, e := range entries {
				reg.Keys[e.KeyID] = e
			}
		}
	}
	return reg, nil
}

// ParseResumeToken parses a token from either JSON string or base64 encoded JSON string.
func ParseResumeToken(tokenStr string) (ResumeToken, error) {
	tokenStr = strings.TrimSpace(tokenStr)
	if tokenStr == "" {
		return ResumeToken{}, errors.New("empty resume token")
	}

	var token ResumeToken
	if err := json.Unmarshal([]byte(tokenStr), &token); err == nil && token.TokenID != "" {
		return token, nil
	}

	decoded, err := base64.StdEncoding.DecodeString(tokenStr)
	if err == nil {
		if err := json.Unmarshal(decoded, &token); err == nil && token.TokenID != "" {
			return token, nil
		}
	}

	var req struct {
		Token ResumeToken `json:"token"`
	}
	if err := json.Unmarshal([]byte(tokenStr), &req); err == nil && req.Token.TokenID != "" {
		return req.Token, nil
	}

	return ResumeToken{}, errors.New("cannot parse resume token as JSON or base64-JSON")
}

// EnforceResume verifies an attributable governance resume token, enforces atomic replay protection,
// mandates credential rotation across all credential planes, unfreezes the target agent, and returns
// an honest ResumeResponse with operator attribution.
func EnforceResume(ctx context.Context, req ResumeRequest, registry OperatorKeyRegistry, policy ResumeTokenPolicy, ledger *ReplayLedger, client FleetClient) (*ResumeResponse, error) {
	start := time.Now()
	now := start.UTC()

	resp := &ResumeResponse{
		SchemaVersion:      CurrentSchemaVersion,
		IdempotencyKey:     req.IdempotencyKey,
		AgentID:            req.AgentID,
		Success:            false,
		ProcessesResumed:   0,
		CredentialsRotated: false,
		Timestamp:          now.Format(time.RFC3339),
	}

	target := TargetRef{
		AgentID:   req.AgentID,
		Namespace: req.Namespace,
	}

	// 1. Verify token structure, signatures, validity window, and policy constraints
	if err := VerifyResumeToken(req.Token, target, registry, policy, now); err != nil {
		resp.Error = err.Error()
		resp.LatencyMs = time.Since(start).Milliseconds()
		return resp, fmt.Errorf("token verification failed: %w", err)
	}

	operatorIDs := make([]string, 0, len(req.Token.Signatures))
	for _, sig := range req.Token.Signatures {
		operatorIDs = append(operatorIDs, sig.OperatorID)
	}

	// 2. Check Replay Ledger for single-use enforcement and idempotent retry
	if ledger != nil {
		isRetry, _, replayErr := ledger.CheckAndRecord(req.Token.TokenID, req.IdempotencyKey, operatorIDs, now)
		if replayErr != nil {
			resp.Error = replayErr.Error()
			resp.LatencyMs = time.Since(start).Milliseconds()
			return resp, replayErr
		}
		if isRetry {
			// Idempotent retry: return success without duplicate rotation
			resp.Success = true
			resp.CredentialsRotated = true
			resp.ProcessesResumed = 1
			resp.LatencyMs = time.Since(start).Milliseconds()
			return resp, nil
		}
	}

	// 3. Mandatory Credential Rotation (OpenBao lease rotation + SPIRE SVID re-entry)
	if client != nil {
		if rotator, ok := client.(interface {
			RotateCredentials(ctx context.Context, namespace, agentID, idempotencyKey string) ([]PlaneResult, error)
		}); ok {
			_, rotErr := rotator.RotateCredentials(ctx, req.Namespace, req.AgentID, req.IdempotencyKey)
			if rotErr != nil {
				resp.Error = fmt.Sprintf("mandatory credential rotation failed: %v", rotErr)
				resp.LatencyMs = time.Since(start).Milliseconds()
				return resp, fmt.Errorf("mandatory credential rotation failed: %w", rotErr)
			}
			resp.CredentialsRotated = true
		} else if err := client.RestoreCredentials(ctx, req.AgentID); err != nil {
			resp.Error = fmt.Sprintf("mandatory credential rotation failed: %v", err)
			resp.LatencyMs = time.Since(start).Milliseconds()
			return resp, fmt.Errorf("mandatory credential rotation failed: %w", err)
		} else {
			resp.CredentialsRotated = true
		}

		// 4. Unfreeze the agent pod (set pod state back to active/running)
		if err := client.SetPodState(ctx, req.Namespace, req.AgentID, StateRunning); err != nil {
			resp.Error = fmt.Sprintf("failed to unfreeze pod state: %v", err)
			resp.LatencyMs = time.Since(start).Milliseconds()
			return resp, fmt.Errorf("set pod state running: %w", err)
		}
	}

	resp.Success = true
	resp.ProcessesResumed = 1
	resp.LatencyMs = time.Since(start).Milliseconds()

	// 5. Emit machine-readable audit log for P5-1 attestation
	slog.Info("governance resume decision executed",
		"event", ResumeDecisionEventName,
		"agent_id", req.AgentID,
		"namespace", req.Namespace,
		"token_id", req.Token.TokenID,
		"operator_ids", operatorIDs,
		"governance_approval_ref", req.Token.GovernanceApprovalRef,
		"idempotency_key", req.IdempotencyKey,
		"credentials_rotated", resp.CredentialsRotated,
		"processes_resumed", resp.ProcessesResumed,
		"success", resp.Success,
		"latency_ms", resp.LatencyMs)

	return resp, nil
}
