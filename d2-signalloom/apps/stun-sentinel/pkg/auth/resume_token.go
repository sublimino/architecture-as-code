// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package auth

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// FrozenSchemaVersion is the normative wire schema version.
const FrozenSchemaVersion = "sler.signalloom.io/v1alpha1"

// ResumeTokenAlgEd25519 is the only signature algorithm this schema version admits.
const ResumeTokenAlgEd25519 = "ed25519"

// ResumeTokenSigningDomain is the domain-separation prefix.
const ResumeTokenSigningDomain = "sler.signalloom.io/resume-token/v1alpha1"

// ResumeTokenSignatureEncoding names the wire encoding of the signature field.
const ResumeTokenSignatureEncoding = "base64(std,padded) of raw 64-byte ed25519 signature"

// ResumeTokenMinNonceBytes is the minimum decoded entropy in the nonce.
const ResumeTokenMinNonceBytes = 16

// ResumeTokenKeyIDPrefix is the self-certifying key-handle prefix.
const ResumeTokenKeyIDPrefix = "sha256:"

// Typed verification errors matching P1-3 frozen contract.
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

// TargetRef names the entity being resumed.
type TargetRef struct {
	AgentID   string `json:"agent_id"`
	Namespace string `json:"namespace"`
	PodUID    string `json:"pod_uid,omitempty"`
}

// ResumeTokenSignature is one operator's Ed25519 signature over a ResumeToken.
type ResumeTokenSignature struct {
	OperatorID string `json:"operator_id"`
	KeyID      string `json:"key_id"`
	Algorithm  string `json:"alg"`
	SignedAt   string `json:"signed_at"`
	Signature  string `json:"signature"`
}

// ResumeToken carries an attributable governance token required to reverse a stun.
type ResumeToken struct {
	SchemaVersion         string                 `json:"schema_version"`
	TokenID               string                 `json:"token_id"`
	Algorithm             string                 `json:"alg"`
	AgentID               string                 `json:"agent_id"`
	Namespace             string                 `json:"namespace"`
	Audience              string                 `json:"audience"`
	OperatorID            string                 `json:"operator_id"`
	GovernanceApprovalRef string                 `json:"governance_approval_ref"`
	IssuedAt              string                 `json:"issued_at"`
	ExpiresAt             string                 `json:"expires_at"`
	Nonce                 string                 `json:"nonce"`
	TrustRootID           string                 `json:"trust_root_id"`
	RequiredSignatures    int                    `json:"required_signatures"`
	Signature             string                 `json:"signature"`
	Signatures            []ResumeTokenSignature `json:"signatures"`
}

// OperatorKeyEntry is one registered operator signing key.
type OperatorKeyEntry struct {
	OperatorID string            `json:"operator_id"`
	KeyID      string            `json:"key_id"`
	PublicKey  ed25519.PublicKey `json:"public_key"`
	NotBefore  time.Time         `json:"not_before,omitempty"`
	NotAfter   time.Time         `json:"not_after,omitempty"`
	Revoked    bool              `json:"revoked,omitempty"`
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

// OperatorKeyRegistry resolves a key ID to its registered operator entry.
type OperatorKeyRegistry interface {
	LookupOperatorKey(keyID string) (OperatorKeyEntry, error)
	AllKeys() []OperatorKeyEntry
}

// StaticOperatorKeyRegistry is an in-memory map of key entries.
type StaticOperatorKeyRegistry struct {
	mu   sync.RWMutex
	keys map[string]OperatorKeyEntry
}

// NewStaticOperatorKeyRegistry constructs a registry from entries.
func NewStaticOperatorKeyRegistry(entries ...OperatorKeyEntry) *StaticOperatorKeyRegistry {
	m := make(map[string]OperatorKeyEntry, len(entries))
	for _, e := range entries {
		if e.KeyID == "" && len(e.PublicKey) == ed25519.PublicKeySize {
			e.KeyID = ComputeKeyID(e.PublicKey)
		}
		m[e.KeyID] = e
	}
	return &StaticOperatorKeyRegistry{keys: m}
}

// LookupOperatorKey implements OperatorKeyRegistry.
func (r *StaticOperatorKeyRegistry) LookupOperatorKey(keyID string) (OperatorKeyEntry, error) {
	if r == nil {
		return OperatorKeyEntry{}, fmt.Errorf("%w: nil registry", ErrResumeTokenUnknownKey)
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.keys[keyID]
	if !ok {
		return OperatorKeyEntry{}, fmt.Errorf("%w: %s", ErrResumeTokenUnknownKey, keyID)
	}
	return e, nil
}

// AllKeys returns all key entries in the registry.
func (r *StaticOperatorKeyRegistry) AllKeys() []OperatorKeyEntry {
	if r == nil {
		return nil
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	res := make([]OperatorKeyEntry, 0, len(r.keys))
	for _, v := range r.keys {
		res = append(res, v)
	}
	return res
}

// AddEntry adds or updates an entry in the static registry.
func (r *StaticOperatorKeyRegistry) AddEntry(entry OperatorKeyEntry) {
	if r == nil {
		return
	}
	if entry.KeyID == "" && len(entry.PublicKey) == ed25519.PublicKeySize {
		entry.KeyID = ComputeKeyID(entry.PublicKey)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.keys == nil {
		r.keys = make(map[string]OperatorKeyEntry)
	}
	r.keys[entry.KeyID] = entry
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
	// Try Base64 decoding first
	pubBytes, err = base64.StdEncoding.DecodeString(raw.PublicKey)
	if err != nil || len(pubBytes) != ed25519.PublicKeySize {
		// Try Hex decoding
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

// LoadOperatorKeyRegistry loads keys from a bundle file or directory.
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
			reg.AddEntry(*entry)
			return reg, nil
		}
		entries, err := LoadOperatorKeysFromJSON(data)
		if err != nil {
			return nil, err
		}
		for _, e := range entries {
			reg.AddEntry(e)
		}
		return reg, nil
	}

	// Walk directory for *.json and *.pub files
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
			reg.AddEntry(*entry)
			continue
		}
		if strings.HasSuffix(f.Name(), ".json") {
			entries, err := LoadOperatorKeysFromJSON(data)
			if err != nil {
				return nil, fmt.Errorf("parse key file %s: %w", fullPath, err)
			}
			for _, e := range entries {
				reg.AddEntry(e)
			}
		}
	}
	return reg, nil
}

// ResumeTokenPolicy contains the verifier-side governance policy.
type ResumeTokenPolicy struct {
	RequiredSignatures int
	Audience           string
	MaxLifetime        time.Duration
	ClockSkew          time.Duration
	TrustRootID        string
	MaxApprovalWindow  time.Duration
}

// DefaultResumeTokenPolicy creates standard policy.
func DefaultResumeTokenPolicy(audience, trustRootID string) ResumeTokenPolicy {
	return ResumeTokenPolicy{
		RequiredSignatures: 1, // Default for single node verifier, can be raised by token claim
		Audience:           audience,
		MaxLifetime:        15 * time.Minute,
		ClockSkew:          60 * time.Second,
		TrustRootID:        trustRootID,
		MaxApprovalWindow:  10 * time.Minute,
	}
}

// ComputeKeyID returns "sha256:<hex>" over raw 32-byte Ed25519 public key.
func ComputeKeyID(pub ed25519.PublicKey) string {
	sum := sha256.Sum256(pub)
	return ResumeTokenKeyIDPrefix + hex.EncodeToString(sum[:])
}

func lengthPrefix(dst []byte, s string) []byte {
	var n [4]byte
	binary.BigEndian.PutUint32(n[:], uint32(len(s)))
	dst = append(dst, n[:]...)
	return append(dst, s...)
}

// SigningInput returns length-prefixed canonical bytes of token body.
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

// SigningInputFor returns length-prefixed canonical bytes for one signer.
func SigningInputFor(t ResumeToken, sig ResumeTokenSignature) []byte {
	buf := t.SigningInput()
	buf = lengthPrefix(buf, sig.OperatorID)
	buf = lengthPrefix(buf, sig.KeyID)
	buf = lengthPrefix(buf, sig.Algorithm)
	buf = lengthPrefix(buf, sig.SignedAt)
	return buf
}

// ValidateStructure checks all structural invariants without checking signatures or clocks.
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

// SignResumeToken appends one operator's signature and returns the updated token.
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

// VerificationResult carries the details of a successful verification.
type VerificationResult struct {
	TokenID     string   `json:"token_id"`
	OperatorIDs []string `json:"operator_ids"`
	SignerCount int      `json:"signer_count"`
	Target      TargetRef
}

// VerifyResumeToken verifies all signatures and policy constraints for a token against target.
func VerifyResumeToken(token ResumeToken, target TargetRef, registry OperatorKeyRegistry, policy ResumeTokenPolicy, now time.Time) (*VerificationResult, error) {
	if err := token.ValidateStructure(); err != nil {
		return nil, err
	}
	if target.AgentID != "" && token.AgentID != target.AgentID {
		return nil, fmt.Errorf("%w: token names %s/%s, target is %s/%s",
			ErrResumeTokenTargetMismatch, token.Namespace, token.AgentID, target.Namespace, target.AgentID)
	}
	if target.Namespace != "" && token.Namespace != target.Namespace {
		return nil, fmt.Errorf("%w: token names %s/%s, target is %s/%s",
			ErrResumeTokenTargetMismatch, token.Namespace, token.AgentID, target.Namespace, target.AgentID)
	}
	if policy.Audience != "" && token.Audience != policy.Audience {
		return nil, fmt.Errorf("%w: token audience %q, this fleet %q",
			ErrResumeTokenAudienceMismatch, token.Audience, policy.Audience)
	}
	if policy.TrustRootID != "" && token.TrustRootID != policy.TrustRootID {
		return nil, fmt.Errorf("%w: token names %q, this verifier pins %q",
			ErrResumeTokenTrustRootMismatch, token.TrustRootID, policy.TrustRootID)
	}

	issued, _ := time.Parse(time.RFC3339, token.IssuedAt)
	expires, _ := time.Parse(time.RFC3339, token.ExpiresAt)
	if policy.MaxLifetime > 0 && expires.Sub(issued) > policy.MaxLifetime {
		return nil, fmt.Errorf("%w: %s > %s", ErrResumeTokenLifetimeTooLong, expires.Sub(issued), policy.MaxLifetime)
	}
	if now.Before(issued.Add(-policy.ClockSkew)) {
		return nil, fmt.Errorf("%w: issued_at %s, now %s", ErrResumeTokenNotYetValid, token.IssuedAt, now.UTC().Format(time.RFC3339))
	}
	if now.After(expires.Add(policy.ClockSkew)) {
		return nil, fmt.Errorf("%w: expires_at %s, now %s", ErrResumeTokenExpired, token.ExpiresAt, now.UTC().Format(time.RFC3339))
	}

	var operatorIDs []string
	var earliestSigned, latestSigned time.Time
	for i, sig := range token.Signatures {
		signedAt, _ := time.Parse(time.RFC3339, sig.SignedAt)
		if signedAt.Before(issued.Add(-policy.ClockSkew)) || signedAt.After(expires.Add(policy.ClockSkew)) {
			return nil, fmt.Errorf("%w: signatures[%d] signed at %s, token valid %s..%s",
				ErrResumeTokenSignedAtOutOfWindow, i, sig.SignedAt, token.IssuedAt, token.ExpiresAt)
		}
		if earliestSigned.IsZero() || signedAt.Before(earliestSigned) {
			earliestSigned = signedAt
		}
		if latestSigned.IsZero() || signedAt.After(latestSigned) {
			latestSigned = signedAt
		}

		if registry == nil {
			return nil, fmt.Errorf("%w: signatures[%d] key %s (no registry configured)", ErrResumeTokenUnknownKey, i, sig.KeyID)
		}
		entry, err := registry.LookupOperatorKey(sig.KeyID)
		if err != nil {
			return nil, fmt.Errorf("signatures[%d]: %w", i, err)
		}
		if entry.Revoked {
			return nil, fmt.Errorf("%w: signatures[%d] key %s", ErrResumeTokenRevokedKey, i, sig.KeyID)
		}
		if !entry.NotBefore.IsZero() && now.Before(entry.NotBefore.Add(-policy.ClockSkew)) {
			return nil, fmt.Errorf("%w: signatures[%d] key %s not valid until %s",
				ErrResumeTokenNotYetValid, i, sig.KeyID, entry.NotBefore.UTC().Format(time.RFC3339))
		}
		if !entry.NotAfter.IsZero() && now.After(entry.NotAfter.Add(policy.ClockSkew)) {
			return nil, fmt.Errorf("%w: signatures[%d] key %s expired at %s",
				ErrResumeTokenExpired, i, sig.KeyID, entry.NotAfter.UTC().Format(time.RFC3339))
		}
		if want := ComputeKeyID(entry.PublicKey); want != sig.KeyID {
			return nil, fmt.Errorf("%w: signatures[%d] presented %s, key fingerprints as %s",
				ErrResumeTokenKeyIDMismatch, i, sig.KeyID, want)
		}
		if entry.OperatorID != sig.OperatorID {
			return nil, fmt.Errorf("%w: signatures[%d] claims %s, key %s is registered to %s",
				ErrResumeTokenOperatorMismatch, i, sig.OperatorID, sig.KeyID, entry.OperatorID)
		}
		raw, err := base64.StdEncoding.DecodeString(sig.Signature)
		if err != nil {
			return nil, fmt.Errorf("%w: signatures[%d]: %v", ErrResumeTokenMalformed, i, err)
		}
		if !ed25519.Verify(entry.PublicKey, SigningInputFor(token, sig), raw) {
			return nil, fmt.Errorf("%w: signatures[%d] by %s", ErrResumeTokenBadSignature, i, sig.OperatorID)
		}
		operatorIDs = append(operatorIDs, sig.OperatorID)
	}

	if policy.MaxApprovalWindow > 0 && latestSigned.Sub(earliestSigned) > policy.MaxApprovalWindow {
		return nil, fmt.Errorf("%w: %s between first and last approval, maximum %s",
			ErrResumeTokenApprovalWindowExceed, latestSigned.Sub(earliestSigned), policy.MaxApprovalWindow)
	}

	effective := policy.RequiredSignatures
	if token.RequiredSignatures > effective {
		effective = token.RequiredSignatures
	}
	if effective > 0 && len(operatorIDs) < effective {
		return nil, fmt.Errorf("%w: %d distinct operators; effective threshold is %d",
			ErrResumeTokenInsufficientSignature, len(operatorIDs), effective)
	}

	return &VerificationResult{
		TokenID:     token.TokenID,
		OperatorIDs: operatorIDs,
		SignerCount: len(operatorIDs),
		Target:      target,
	}, nil
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

// ParseResumeToken parses a token from either JSON string or base64 encoded JSON string.
func ParseResumeToken(tokenStr string) (ResumeToken, error) {
	tokenStr = strings.TrimSpace(tokenStr)
	if tokenStr == "" {
		return ResumeToken{}, errors.New("empty resume token")
	}

	var token ResumeToken
	// First try JSON unmarshal directly
	if err := json.Unmarshal([]byte(tokenStr), &token); err == nil && token.TokenID != "" {
		return token, nil
	}

	// Try Base64 decoding
	decoded, err := base64.StdEncoding.DecodeString(tokenStr)
	if err == nil {
		if err := json.Unmarshal(decoded, &token); err == nil && token.TokenID != "" {
			return token, nil
		}
	}

	// Try checking if it's wrapped in a ResumeRequest
	var req struct {
		Token ResumeToken `json:"token"`
	}
	if err := json.Unmarshal([]byte(tokenStr), &req); err == nil && req.Token.TokenID != "" {
		return req.Token, nil
	}

	return ResumeToken{}, errors.New("cannot parse resume token as JSON or base64-JSON")
}
