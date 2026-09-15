// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package attestation

import (
	"crypto"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// VerificationResult contains the parsed forensic record and signature audit details.
type VerificationResult struct {
	Record          *ForensicLedgerRecord `json:"record"`
	KeyID           string                `json:"key_id"`
	KeyVersion      string                `json:"key_version,omitempty"`
	Algorithm       string                `json:"algorithm"`
	StatementDigest string                `json:"statement_digest"`
	VerifiedAt      string                `json:"verified_at"`
	Valid           bool                  `json:"valid"`
}

// ForensicVerifier cryptographically validates DSSE-enveloped in-toto forensic statements.
type ForensicVerifier struct {
	history *KeyHistoryStore
}

// NewForensicVerifier initializes a verifier backed by a key history store.
func NewForensicVerifier(history *KeyHistoryStore) *ForensicVerifier {
	if history == nil {
		history = NewKeyHistoryStore()
	}
	return &ForensicVerifier{
		history: history,
	}
}

// VerifyEnvelope decodes and cryptographically validates a raw JSON DSSE envelope against the key history store.
func (v *ForensicVerifier) VerifyEnvelope(rawEnvelope []byte) (*VerificationResult, error) {
	if len(rawEnvelope) == 0 {
		return nil, errors.New("empty DSSE envelope bytes")
	}

	var env DSSEEnvelope
	if err := json.Unmarshal(rawEnvelope, &env); err != nil {
		return nil, fmt.Errorf("unmarshal DSSE envelope: %w", err)
	}

	if env.PayloadType != DSSEPayloadType {
		return nil, fmt.Errorf("unsupported DSSE payloadType %q (expected %q)", env.PayloadType, DSSEPayloadType)
	}
	if len(env.Signatures) == 0 {
		return nil, errors.New("DSSE envelope contains zero signatures")
	}

	payloadBytes, err := base64.StdEncoding.DecodeString(env.Payload)
	if err != nil {
		return nil, fmt.Errorf("decode DSSE base64 payload: %w", err)
	}

	pae := dssePAE(env.PayloadType, payloadBytes)

	// Verify at least one signature
	var lastErr error
	for _, sig := range env.Signatures {
		sigBytes, err := base64.StdEncoding.DecodeString(sig.Sig)
		if err != nil {
			lastErr = fmt.Errorf("decode signature base64: %w", err)
			continue
		}

		keyEntry, err := v.history.GetKey(sig.KeyID)
		if err != nil {
			lastErr = fmt.Errorf("lookup key %s in history: %w", sig.KeyID, err)
			continue
		}

		if err := v.verifyRawSignature(keyEntry.PublicKey, pae, sigBytes); err != nil {
			lastErr = fmt.Errorf("cryptographic signature verification failed for key %s: %w", sig.KeyID, err)
			continue
		}

		// Signature is valid — parse the in-toto Statement
		var statement map[string]any
		if err := json.Unmarshal(payloadBytes, &statement); err != nil {
			return nil, fmt.Errorf("unmarshal in-toto statement from payload: %w", err)
		}

		stmtType, _ := statement["_type"].(string)
		if stmtType != InTotoStatementType {
			return nil, fmt.Errorf("invalid in-toto statement _type %q", stmtType)
		}

		predType, _ := statement["predicateType"].(string)
		if predType != ContainmentPredicateType && predType != ResumePredicateType {
			return nil, fmt.Errorf("unrecognized predicateType %q", predType)
		}

		predicateRaw, ok := statement["predicate"]
		if !ok {
			return nil, errors.New("in-toto statement missing predicate")
		}

		predicateJSON, err := json.Marshal(predicateRaw)
		if err != nil {
			return nil, fmt.Errorf("remarshal predicate: %w", err)
		}

		var record ForensicLedgerRecord
		if err := json.Unmarshal(predicateJSON, &record); err != nil {
			return nil, fmt.Errorf("unmarshal predicate into ForensicLedgerRecord: %w", err)
		}

		if err := record.Validate(); err != nil {
			return nil, fmt.Errorf("validate forensic ledger record: %w", err)
		}

		digest, err := ComputeStatementDigest(statement)
		if err != nil {
			return nil, fmt.Errorf("compute statement digest: %w", err)
		}

		// Populate attestation metadata on the returned record
		record.Attestation = AttestationEnvelopeMetadata{
			KeyID:           sig.KeyID,
			Algorithm:       SigningAlgorithmEd25519,
			StatementDigest: digest,
			Signature:       sig.Sig,
		}

		return &VerificationResult{
			Record:          &record,
			KeyID:           sig.KeyID,
			KeyVersion:      keyEntry.KeyVersion,
			Algorithm:       SigningAlgorithmEd25519,
			StatementDigest: digest,
			Valid:           true,
		}, nil
	}

	if lastErr != nil {
		return nil, fmt.Errorf("DSSE verification failed: %w", lastErr)
	}
	return nil, errors.New("no valid signature found in DSSE envelope")
}

// VerifyWithPublicKey validates a DSSE envelope directly against a specific public key.
func (v *ForensicVerifier) VerifyWithPublicKey(rawEnvelope []byte, pub crypto.PublicKey) (*VerificationResult, error) {
	keyID, err := DeriveKeyID(pub)
	if err != nil {
		return nil, fmt.Errorf("derive key ID: %w", err)
	}

	tempStore := NewKeyHistoryStore()
	_ = tempStore.RegisterKey(keyID, pub, "direct-pubkey", time.Time{}, KeyStatusActive)

	verifier := NewForensicVerifier(tempStore)
	return verifier.VerifyEnvelope(rawEnvelope)
}

func (v *ForensicVerifier) verifyRawSignature(pub crypto.PublicKey, pae []byte, sig []byte) error {
	edPub, ok := pub.(ed25519.PublicKey)
	if !ok {
		return fmt.Errorf("unsupported public key type %T (expected ed25519.PublicKey)", pub)
	}

	if !ed25519.Verify(edPub, pae, sig) {
		return errors.New("invalid cryptographic signature (tampered payload or invalid key)")
	}
	return nil
}
