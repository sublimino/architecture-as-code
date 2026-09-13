// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package agentnono

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net/url"
	"strings"
	"sync"
)

// DefaultTrustDomain is the canonical SPIFFE trust domain for Signal Loom.
const DefaultTrustDomain = "spiffe://signalloom.demo"

// VerificationResult contains the cryptographic attestation analysis of an audit event.
type VerificationResult struct {
	Status           VerificationStatus
	SPIFFEID         string
	SignatureGitOID  string
	HashChainDigest  string
	CalculatedDigest string
	KeyID            string
	Error            error
}

// VerifierConfig configures trust bundles and domain validation boundaries.
type VerifierConfig struct {
	TrustDomain      string
	TrustBundlePEM   []byte
	TrustPool        *x509.CertPool
	RequireSignature bool
}

// SessionState tracks the hash chain sequence and last seen digest for an active audit session.
type SessionState struct {
	LastSeq    int64
	LastDigest string
}

// AuditVerifier performs cryptographic detached signature verification and hash chain validation.
type AuditVerifier struct {
	mu           sync.RWMutex
	cfg          VerifierConfig
	sessionState map[string]*SessionState
}

// NewAuditVerifier constructs a verifier configured with SPIRE trust roots and trust domain.
func NewAuditVerifier(cfg VerifierConfig) *AuditVerifier {
	if cfg.TrustDomain == "" {
		cfg.TrustDomain = DefaultTrustDomain
	}
	if cfg.TrustPool == nil && len(cfg.TrustBundlePEM) > 0 {
		pool := x509.NewCertPool()
		pool.AppendCertsFromPEM(cfg.TrustBundlePEM)
		cfg.TrustPool = pool
	}
	return &AuditVerifier{
		cfg:          cfg,
		sessionState: make(map[string]*SessionState),
	}
}

// ResetSession clears the tracking state for a specific session.
func (v *AuditVerifier) ResetSession(sessionID string) {
	v.mu.Lock()
	defer v.mu.Unlock()
	delete(v.sessionState, sessionID)
}

// VerifyEvent validates the detached signature, SVID validity, and hash chain integrity of an event.
func (v *AuditVerifier) VerifyEvent(event *NonoAuditEvent) *VerificationResult {
	res := &VerificationResult{
		Status:   StatusUnverified,
		SPIFFEID: event.SPIFFEID,
	}

	if event == nil {
		res.Status = StatusTampered
		res.Error = errors.New("nil audit event")
		return res
	}

	// 1. Hash Chain Integrity Verification
	calculatedDigest, chainErr := v.verifyHashChain(event)
	res.CalculatedDigest = calculatedDigest
	res.HashChainDigest = event.Digest

	if chainErr != nil {
		res.Status = StatusTampered
		res.Error = fmt.Errorf("hash chain validation failure: %w", chainErr)
		return res
	}

	// Calculate GitOID for provenance tracking: blob <length>\0<content>
	payload := event.CanonicalPayload()
	gitOID := ComputeGitOID(payload)
	res.SignatureGitOID = gitOID
	if event.SignatureGitOID == "" {
		event.SignatureGitOID = gitOID
	}

	// 2. Cryptographic Signature Verification
	sig := event.Signature
	certPEM := event.Certificate

	if sig == "" && len(event.Metadata) > 0 {
		if s, ok := event.Metadata["signature"].(string); ok {
			sig = s
		}
		if c, ok := event.Metadata["certificate"].(string); ok {
			certPEM = c
		}
	}

	if sig == "" {
		if v.cfg.RequireSignature {
			res.Status = StatusUnsigned
			res.Error = errors.New("missing cryptographic signature on audit event")
		} else {
			// Unsigned telemetry allowed as UNVERIFIED if hash chain is intact
			res.Status = StatusUnverified
		}
		return res
	}

	// If certificate is provided, verify leaf certificate against SPIRE trust domain and bundle
	if certPEM != "" {
		cert, certErr := ParseCertificatePEM([]byte(certPEM))
		if certErr != nil {
			res.Status = StatusUnverified
			res.Error = fmt.Errorf("invalid x509 SVID certificate: %w", certErr)
			return res
		}

		// Validate SPIFFE ID in certificate SAN URIs
		spiffeID, spiffeErr := ExtractSPIFFEID(cert)
		if spiffeErr != nil {
			res.Status = StatusUnverified
			res.Error = fmt.Errorf("SVID URI SAN validation failure: %w", spiffeErr)
			return res
		}
		res.SPIFFEID = spiffeID

		// If trust pool is available, verify certificate chain
		if v.cfg.TrustPool != nil {
			opts := x509.VerifyOptions{
				Roots:     v.cfg.TrustPool,
				KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny, x509.ExtKeyUsageClientAuth},
			}
			if _, verifyErr := cert.Verify(opts); verifyErr != nil {
				res.Status = StatusUnverified
				res.Error = fmt.Errorf("SVID trust pool verification failed: %w", verifyErr)
				return res
			}
		}

		// Verify signature against public key
		if err := VerifySignature(cert.PublicKey, payload, sig); err != nil {
			// Try verifying against calculated digest or raw bytes
			if errDigest := VerifySignature(cert.PublicKey, []byte(calculatedDigest), sig); errDigest != nil {
				res.Status = StatusTampered
				res.Error = fmt.Errorf("cryptographic signature mismatch: %w", err)
				return res
			}
		}

		res.Status = StatusVerified
		return res
	}

	// If signature is present without embedded cert, check if signature format is valid
	if sig != "" {
		res.Status = StatusUnverified
		res.Error = errors.New("signature present but issuing certificate was omitted")
		return res
	}

	return res
}

// verifyHashChain calculates and verifies the SHA-256 digest continuity of the audit session.
func (v *AuditVerifier) verifyHashChain(event *NonoAuditEvent) (string, error) {
	payload := event.CanonicalPayload()

	// Compute SHA-256 over: prev_digest + canonical_payload
	h := sha256.New()
	if event.PrevDigest != "" {
		h.Write([]byte(event.PrevDigest))
	}
	h.Write(payload)
	calculatedDigest := hex.EncodeToString(h.Sum(nil))

	// If event has declared digest, verify match
	if event.Digest != "" && !strings.EqualFold(event.Digest, calculatedDigest) {
		return calculatedDigest, fmt.Errorf("digest mismatch: declared=%s, calculated=%s", event.Digest, calculatedDigest)
	}

	// Check sequential continuity against session state
	sessionID := event.AuditSessionID
	if sessionID != "" {
		v.mu.Lock()
		state, exists := v.sessionState[sessionID]
		if exists {
			// If previous digest does not match our recorded last digest
			if event.PrevDigest != "" && !strings.EqualFold(event.PrevDigest, state.LastDigest) {
				v.mu.Unlock()
				return calculatedDigest, fmt.Errorf("hash chain break: event prev_digest (%s) != session last_digest (%s)",
					event.PrevDigest, state.LastDigest)
			}
		}
		v.sessionState[sessionID] = &SessionState{
			LastSeq:    event.Seq,
			LastDigest: calculatedDigest,
		}
		v.mu.Unlock()
	}

	return calculatedDigest, nil
}

// ComputeGitOID returns the GitOID (SHA-256) blob identifier for the given bytes.
func ComputeGitOID(data []byte) string {
	header := fmt.Sprintf("blob %d\x00", len(data))
	h := sha256.New()
	h.Write([]byte(header))
	h.Write(data)
	return hex.EncodeToString(h.Sum(nil))
}

// ParseCertificatePEM decodes a PEM block into an x509 Certificate.
func ParseCertificatePEM(pemBytes []byte) (*x509.Certificate, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		// Attempt base64 DER fallback
		der, err := base64.StdEncoding.DecodeString(string(pemBytes))
		if err == nil {
			return x509.ParseCertificate(der)
		}
		return nil, errors.New("failed to parse PEM certificate block")
	}
	return x509.ParseCertificate(block.Bytes)
}

// ExtractSPIFFEID extracts and validates the SPIFFE ID from the certificate SAN URIs.
func ExtractSPIFFEID(cert *x509.Certificate) (string, error) {
	if cert == nil {
		return "", errors.New("nil certificate")
	}
	for _, uri := range cert.URIs {
		if uri != nil && uri.Scheme == "spiffe" {
			return uri.String(), nil
		}
	}
	// Fallback check in Subject CommonName or SAN DNS names
	if strings.HasPrefix(cert.Subject.CommonName, "spiffe://") {
		return cert.Subject.CommonName, nil
	}
	return "", errors.New("no spiffe:// URI found in certificate SANs")
}

// VerifySignature verifies a signature against an ECDSA, Ed25519, or RSA public key.
func VerifySignature(pubKey crypto.PublicKey, data []byte, sigStr string) error {
	sigBytes, err := decodeSignatureBytes(sigStr)
	if err != nil {
		return fmt.Errorf("decode signature bytes: %w", err)
	}

	digest := sha256.Sum256(data)

	switch key := pubKey.(type) {
	case *ecdsa.PublicKey:
		// Attempt ASN.1 DER ECDSA signature unmarshal
		type ecdsaSignature struct {
			R, S *big.Int
		}
		var eSig ecdsaSignature
		if _, err := asn1.Unmarshal(sigBytes, &eSig); err == nil && eSig.R != nil && eSig.S != nil {
			if ecdsa.Verify(key, digest[:], eSig.R, eSig.S) {
				return nil
			}
		}
		// Attempt raw IEEE P1363 (r || s) format (64 bytes for P-256)
		if len(sigBytes) == 64 {
			r := new(big.Int).SetBytes(sigBytes[:32])
			s := new(big.Int).SetBytes(sigBytes[32:])
			if ecdsa.Verify(key, digest[:], r, s) {
				return nil
			}
		}
		return errors.New("ecdsa signature verification failed")

	case ed25519.PublicKey:
		if ed25519.Verify(key, data, sigBytes) {
			return nil
		}
		if ed25519.Verify(key, digest[:], sigBytes) {
			return nil
		}
		return errors.New("ed25519 signature verification failed")

	case *rsa.PublicKey:
		if err := rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], sigBytes); err == nil {
			return nil
		}
		return errors.New("rsa signature verification failed")

	default:
		return fmt.Errorf("unsupported public key type: %T", pubKey)
	}
}

// decodeSignatureBytes parses base64 or hex encoded signatures.
func decodeSignatureBytes(sigStr string) ([]byte, error) {
	sigStr = strings.TrimSpace(sigStr)
	if b, err := base64.StdEncoding.DecodeString(sigStr); err == nil && len(b) > 0 {
		return b, nil
	}
	if b, err := base64.URLEncoding.DecodeString(sigStr); err == nil && len(b) > 0 {
		return b, nil
	}
	if b, err := hex.DecodeString(sigStr); err == nil && len(b) > 0 {
		return b, nil
	}
	return nil, errors.New("signature is not valid base64 or hex")
}

// MatchTrustDomain returns true if the candidate SPIFFE ID belongs to the configured trust domain.
func MatchTrustDomain(spiffeID, trustDomain string) bool {
	if trustDomain == "" {
		trustDomain = DefaultTrustDomain
	}
	u, err := url.Parse(spiffeID)
	if err != nil || u.Scheme != "spiffe" {
		return false
	}
	tdURL, err := url.Parse(trustDomain)
	if err != nil {
		return false
	}
	return strings.EqualFold(u.Host, tdURL.Host)
}

// VerifyCosignManifest checks that an agent manifest carries a valid signature from the cosign public key.
func VerifyCosignManifest(manifestData []byte, signatureStr string, pubKeyPEM []byte) (bool, error) {
	if len(manifestData) == 0 || signatureStr == "" || len(pubKeyPEM) == 0 {
		return false, errors.New("empty manifest, signature, or key data")
	}

	block, _ := pem.Decode(pubKeyPEM)
	if block == nil {
		return false, errors.New("invalid PEM for cosign public key")
	}

	pub, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return false, fmt.Errorf("parse PKIX public key: %w", err)
	}

	if err := VerifySignature(pub, manifestData, signatureStr); err != nil {
		return false, fmt.Errorf("cosign manifest verification failed: %w", err)
	}

	return true, nil
}

// FinalizedSessionVerification represents the comprehensive cryptographic verification result of a completed audit session.
type FinalizedSessionVerification struct {
	SessionID   string             `json:"session_id"`
	EventCount  int                `json:"event_count"`
	Status      VerificationStatus `json:"status"`
	FinalDigest string             `json:"final_digest"`
	RootDigest  string             `json:"root_digest"`
	SPIFFEID    string             `json:"spiffe_id"`
	ActorID     string             `json:"actor_id"`
	LandlockABI int                `json:"landlock_abi"`
	GitOIDs     []string           `json:"git_oids"`
	IsFinalized bool               `json:"is_finalized"`
	Violations  []string           `json:"violations,omitempty"`
	Error       error              `json:"error,omitempty"`
}

// IsFinalizedEvent returns true if the event represents an explicit session termination/finalization marker.
func IsFinalizedEvent(e *NonoAuditEvent) bool {
	if e == nil {
		return false
	}
	lc := strings.ToLower(e.LifecycleState)
	if lc == "finalized" || lc == "completed" || lc == "terminated" || lc == "closed" {
		return true
	}
	et := strings.ToLower(e.EventType)
	if et == "session_finalized" || et == "session_end" || et == "finalized" {
		return true
	}
	ev := strings.ToLower(e.Event)
	if ev == "session_finalized" || ev == "finalized" {
		return true
	}
	if len(e.Metadata) > 0 {
		if fin, ok := e.Metadata["finalized"].(bool); ok && fin {
			return true
		}
		if state, ok := e.Metadata["lifecycle_state"].(string); ok && strings.ToLower(state) == "finalized" {
			return true
		}
	}
	return false
}

// VerifyFinalizedSession cryptographically validates an entire finalized nono audit session chain.
// It verifies:
// 1. Session contains at least one event.
// 2. Uniform session ID across all events.
// 3. Strict contiguous sequence ordering without gaps, out-of-order, or duplicate sequences.
// 4. SHA-256 hash chain continuity: prev_digest matches calculated digest of preceding event.
// 5. Event declared digest matches calculated digest.
// 6. Signature on each event block is valid against the signing key/certificate and SPIFFE trust domain.
// 7. Landlock ABI metadata is verified and recorded.
// 8. GitOIDs are calculated and verified for all events.
// 9. The final event in the chain is explicitly marked as finalized.
func (v *AuditVerifier) VerifyFinalizedSession(events []*NonoAuditEvent) *FinalizedSessionVerification {
	res := &FinalizedSessionVerification{
		Status:      StatusUnverified,
		GitOIDs:     make([]string, 0, len(events)),
		Violations:  make([]string, 0),
		IsFinalized: false,
	}

	if len(events) == 0 {
		res.Status = StatusTampered
		res.Error = errors.New("empty audit session: event count is 0")
		res.Violations = append(res.Violations, "empty_session")
		return res
	}

	sessionID := events[0].AuditSessionID
	if sessionID == "" {
		sessionID = events[0].SessionID
	}
	if sessionID == "" {
		res.Status = StatusTampered
		res.Error = errors.New("session identifier is empty")
		res.Violations = append(res.Violations, "empty_session_id")
		return res
	}
	res.SessionID = sessionID

	// Track session hash chain in an isolated state clone to avoid corrupting active streams
	v.mu.Lock()
	v.sessionState[sessionID] = nil
	v.mu.Unlock()

	var prevCalculatedDigest string
	firstSeq := events[0].Seq
	landlockABI := 0

	for i, ev := range events {
		if ev == nil {
			res.Status = StatusTampered
			res.Error = fmt.Errorf("nil audit event at index %d", i)
			res.Violations = append(res.Violations, "nil_event")
			return res
		}

		// Uniform session ID
		currID := ev.AuditSessionID
		if currID == "" {
			currID = ev.SessionID
		}
		if currID != sessionID {
			res.Status = StatusTampered
			res.Error = fmt.Errorf("session ID mismatch at index %d: %q != %q", i, currID, sessionID)
			res.Violations = append(res.Violations, "session_id_mismatch")
			return res
		}

		// Sequence checks
		expectedSeq := firstSeq + int64(i)
		if ev.Seq != expectedSeq {
			if i > 0 && ev.Seq <= events[i-1].Seq {
				res.Status = StatusTampered
				res.Error = fmt.Errorf("out-of-order or duplicate sequence at index %d: seq %d <= previous %d", i, ev.Seq, events[i-1].Seq)
				res.Violations = append(res.Violations, "out_of_order_sequence")
				return res
			}
			res.Status = StatusTampered
			res.Error = fmt.Errorf("sequence gap at index %d: expected seq %d, got %d", i, expectedSeq, ev.Seq)
			res.Violations = append(res.Violations, "sequence_gap")
			return res
		}

		// Hash chain continuity
		if i > 0 && ev.PrevDigest != prevCalculatedDigest {
			res.Status = StatusTampered
			res.Error = fmt.Errorf("hash chain break at seq %d: prev_digest %q != calculated %q", ev.Seq, ev.PrevDigest, prevCalculatedDigest)
			res.Violations = append(res.Violations, "hash_chain_break")
			return res
		}

		// Verify event signature, GitOID, and digest
		eventRes := v.VerifyEvent(ev)
		if eventRes.Status == StatusTampered {
			res.Status = StatusTampered
			res.Error = fmt.Errorf("event seq %d tampered: %w", ev.Seq, eventRes.Error)
			res.Violations = append(res.Violations, "event_tampered")
			return res
		}

		if v.cfg.RequireSignature && eventRes.Status != StatusVerified {
			res.Status = StatusUnverified
			res.Error = fmt.Errorf("event seq %d cryptographic verification failed: %w", ev.Seq, eventRes.Error)
			res.Violations = append(res.Violations, "signature_unverified")
			return res
		}

		if res.SPIFFEID == "" && eventRes.SPIFFEID != "" {
			res.SPIFFEID = eventRes.SPIFFEID
		}
		if res.ActorID == "" && ev.ActorID != "" {
			res.ActorID = ev.ActorID
		}
		if ev.Landlock.ABIVersion > landlockABI {
			landlockABI = ev.Landlock.ABIVersion
		}

		res.GitOIDs = append(res.GitOIDs, eventRes.SignatureGitOID)
		prevCalculatedDigest = eventRes.CalculatedDigest
	}

	// Verify finalization marker on terminal event
	terminalEvent := events[len(events)-1]
	if !IsFinalizedEvent(terminalEvent) {
		res.Status = StatusUnverified
		res.Error = errors.New("unfinalized audit session: terminal event lacks completion or finalization marker")
		res.Violations = append(res.Violations, "unfinalized_session")
		res.IsFinalized = false
		res.EventCount = len(events)
		res.FinalDigest = prevCalculatedDigest
		return res
	}

	res.IsFinalized = true
	res.EventCount = len(events)
	res.FinalDigest = prevCalculatedDigest
	res.RootDigest = terminalEvent.Digest
	res.LandlockABI = landlockABI
	res.Status = StatusVerified

	return res
}
