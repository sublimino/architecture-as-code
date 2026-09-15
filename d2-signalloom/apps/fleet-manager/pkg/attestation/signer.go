// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package attestation

import (
	"context"
	"crypto"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
)

// Signer abstracts cryptographic signing of in-toto Statement DSSE attestation envelopes.
// Call sites never interact directly with raw private key bytes.
type Signer interface {
	// KeyID returns the canonical SPKI SHA-256 hex digest identifier of the public key.
	KeyID() string

	// KeyVersion returns the version tag of the signing key (e.g. "witness-key-v1").
	KeyVersion() string

	// PublicKey returns the crypto.PublicKey corresponding to the signing key.
	PublicKey() crypto.PublicKey

	// Algorithm returns the algorithm identifier ("ed25519").
	Algorithm() string

	// Sign receives an in-toto statement payload and returns the marshaled DSSE envelope bytes.
	Sign(ctx context.Context, statement map[string]any) ([]byte, error)
}

// DSSESignature represents a single signature inside a DSSE envelope.
type DSSESignature struct {
	KeyID string `json:"keyid"`
	Sig   string `json:"sig"` // Base64 standard encoded
}

// DSSEEnvelope represents the canonical Dead Simple Signing Envelope (DSSE).
type DSSEEnvelope struct {
	PayloadType string          `json:"payloadType"` // "application/vnd.in-toto+json"
	Payload     string          `json:"payload"`     // Base64 standard encoded
	Signatures  []DSSESignature `json:"signatures"`
}

// DeriveKeyID calculates the canonical SPKI SHA-256 hex digest for any public key.
func DeriveKeyID(pub crypto.PublicKey) (string, error) {
	if pub == nil {
		return "", errors.New("cannot derive key ID from nil public key")
	}
	spki, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		return "", fmt.Errorf("marshal PKIX public key: %w", err)
	}
	digest := sha256.Sum256(spki)
	return hex.EncodeToString(digest[:]), nil
}

// FormatDSSE builds a canonical DSSE envelope from an in-toto statement and cryptographic signature.
func FormatDSSE(statement map[string]any, keyID string, signature []byte) ([]byte, error) {
	payload, err := dsseMarshalStatement(statement)
	if err != nil {
		return nil, fmt.Errorf("marshal signed statement: %w", err)
	}
	env := DSSEEnvelope{
		PayloadType: DSSEPayloadType,
		Payload:     base64.StdEncoding.EncodeToString(payload),
		Signatures: []DSSESignature{
			{
				KeyID: keyID,
				Sig:   base64.StdEncoding.EncodeToString(signature),
			},
		},
	}
	return json.Marshal(env)
}

// dssePAE formats canonical Pre-Authentication Encoding:
// "PAE;" + payloadTypeLen + ";" + payloadType + ";" + payloadLen + ";" + payload
func dssePAE(payloadType string, payload []byte) []byte {
	return []byte(fmt.Sprintf("PAE;%s;%s;%s;%s",
		strconv.Itoa(len(payloadType)),
		payloadType,
		strconv.Itoa(len(payload)),
		string(payload),
	))
}

func dsseMarshalStatement(statement map[string]any) ([]byte, error) {
	return json.Marshal(statement)
}
