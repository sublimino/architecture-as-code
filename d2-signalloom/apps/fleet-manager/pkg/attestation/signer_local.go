// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package attestation

import (
	"context"
	"crypto"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"strings"
)

// LocalEd25519Signer implements Signer using an in-memory Ed25519 private key.
type LocalEd25519Signer struct {
	privateKey ed25519.PrivateKey
	publicKey  ed25519.PublicKey
	keyID      string
	keyVersion string
}

// NewLocalEd25519Signer loads an Ed25519 private key from a PKCS#8 or raw PEM file path.
func NewLocalEd25519Signer(path string, keyVersion ...string) (*LocalEd25519Signer, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read Ed25519 key file %s: %w", path, err)
	}
	return NewLocalEd25519SignerFromPEM(raw, keyVersion...)
}

// NewLocalEd25519SignerFromPEM parses Ed25519 private key bytes in PEM format.
func NewLocalEd25519SignerFromPEM(pemBytes []byte, keyVersion ...string) (*LocalEd25519Signer, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("parse Ed25519 key: no PEM block found")
	}

	// Try standard PKCS#8 parsing
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err == nil {
		privateKey, ok := parsed.(ed25519.PrivateKey)
		if !ok {
			return nil, fmt.Errorf("parsed key is %T, not ed25519.PrivateKey", parsed)
		}
		return NewLocalEd25519SignerFromKey(privateKey, keyVersion...)
	}

	// Fallback for raw 32/64 byte seed/private key within PEM
	if len(block.Bytes) == ed25519.PrivateKeySize {
		return NewLocalEd25519SignerFromKey(ed25519.PrivateKey(block.Bytes), keyVersion...)
	}
	if len(block.Bytes) == ed25519.SeedSize {
		priv := ed25519.NewKeyFromSeed(block.Bytes)
		return NewLocalEd25519SignerFromKey(priv, keyVersion...)
	}

	return nil, fmt.Errorf("parse Ed25519 PKCS#8 key: %w", err)
}

// NewLocalEd25519SignerFromKey creates a LocalEd25519Signer from an existing ed25519.PrivateKey.
func NewLocalEd25519SignerFromKey(privateKey ed25519.PrivateKey, keyVersion ...string) (*LocalEd25519Signer, error) {
	if len(privateKey) != ed25519.PrivateKeySize {
		return nil, errors.New("invalid Ed25519 private key length")
	}
	publicKey, ok := privateKey.Public().(ed25519.PublicKey)
	if !ok {
		return nil, errors.New("failed to extract ed25519.PublicKey from private key")
	}
	keyID, err := DeriveKeyID(publicKey)
	if err != nil {
		return nil, fmt.Errorf("derive KeyID: %w", err)
	}

	ver := "witness-ed25519-v1"
	if len(keyVersion) > 0 && strings.TrimSpace(keyVersion[0]) != "" {
		ver = strings.TrimSpace(keyVersion[0])
	}

	return &LocalEd25519Signer{
		privateKey: privateKey,
		publicKey:  publicKey,
		keyID:      keyID,
		keyVersion: ver,
	}, nil
}

// GenerateInMemoryEd25519Signer generates an ephemeral Ed25519 keypair for testing or bootstrapping.
func GenerateInMemoryEd25519Signer(keyVersion ...string) (*LocalEd25519Signer, error) {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generate Ed25519 keypair: %w", err)
	}
	return NewLocalEd25519SignerFromKey(priv, keyVersion...)
}

func (s *LocalEd25519Signer) KeyID() string               { return s.keyID }
func (s *LocalEd25519Signer) KeyVersion() string          { return s.keyVersion }
func (s *LocalEd25519Signer) PublicKey() crypto.PublicKey { return s.publicKey }
func (s *LocalEd25519Signer) Algorithm() string           { return SigningAlgorithmEd25519 }

func (s *LocalEd25519Signer) Sign(ctx context.Context, statement map[string]any) ([]byte, error) {
	if ctx != nil && ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if statement == nil {
		return nil, errors.New("cannot sign nil statement")
	}

	payload, err := dsseMarshalStatement(statement)
	if err != nil {
		return nil, fmt.Errorf("marshal statement: %w", err)
	}

	pae := dssePAE(DSSEPayloadType, payload)
	sig := ed25519.Sign(s.privateKey, pae)

	return FormatDSSE(statement, s.keyID, sig)
}
