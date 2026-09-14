package store

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"strings"
)

// LocalEd25519Signer implements Signer using a local in-memory Ed25519 private key.
type LocalEd25519Signer struct {
	privateKey ed25519.PrivateKey
	publicKey  ed25519.PublicKey
	keyID      string
	keyVersion string
}

// newEd25519Signer is a compatibility alias for NewLocalEd25519Signer.
func newEd25519Signer(path string) (*LocalEd25519Signer, error) {
	return NewLocalEd25519Signer(path)
}

// NewLocalEd25519Signer loads an Ed25519 private key from a PKCS#8 or raw PEM file.
func NewLocalEd25519Signer(path string, keyVersion ...string) (*LocalEd25519Signer, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read Ed25519 key %s: %w", path, err)
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, fmt.Errorf("parse Ed25519 key %s: no PEM block", path)
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		// Fallback for raw private key bytes or OPENSSH / RSA if any
		return nil, fmt.Errorf("parse Ed25519 PKCS8 key %s: %w", path, err)
	}
	privateKey, ok := parsed.(ed25519.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("key %s is %T, not Ed25519", path, parsed)
	}
	return NewLocalEd25519SignerFromKey(privateKey, keyVersion...)
}

// NewLocalEd25519SignerFromKey creates a LocalEd25519Signer from an existing ed25519.PrivateKey.
func NewLocalEd25519SignerFromKey(privateKey ed25519.PrivateKey, keyVersion ...string) (*LocalEd25519Signer, error) {
	publicKey, ok := privateKey.Public().(ed25519.PublicKey)
	if !ok {
		return nil, errors.New("cannot extract ed25519.PublicKey from private key")
	}
	keyID, err := DeriveKeyID(publicKey)
	if err != nil {
		return nil, err
	}
	ver := "local-ed25519-v1"
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

func (s *LocalEd25519Signer) KeyID() string               { return s.keyID }
func (s *LocalEd25519Signer) KeyVersion() string          { return s.keyVersion }
func (s *LocalEd25519Signer) PublicKey() crypto.PublicKey { return s.publicKey }
func (s *LocalEd25519Signer) Algorithm() string           { return "ed25519" }

func (s *LocalEd25519Signer) sign(statement map[string]any) ([]byte, error) {
	return s.Sign(context.Background(), statement)
}

func (s *LocalEd25519Signer) Sign(ctx context.Context, statement map[string]any) ([]byte, error) {
	if ctx != nil && ctx.Err() != nil {
		return nil, ctx.Err()
	}
	payload, err := dsseMarshalStatement(statement)
	if err != nil {
		return nil, fmt.Errorf("marshal statement: %w", err)
	}
	pae := dssePAE(dssePayloadType, payload)
	sig := ed25519.Sign(s.privateKey, pae)
	return FormatDSSE(statement, s.keyID, sig)
}

// LocalECDSASigner implements Signer for local ECDSA private keys (P-256, P-384, P-521).
type LocalECDSASigner struct {
	privateKey *ecdsa.PrivateKey
	publicKey  *ecdsa.PublicKey
	keyID      string
	keyVersion string
	algorithm  string
}

// NewLocalECDSASigner creates a Signer from an ecdsa.PrivateKey.
func NewLocalECDSASigner(privateKey *ecdsa.PrivateKey, keyVersion ...string) (*LocalECDSASigner, error) {
	if privateKey == nil {
		return nil, errors.New("nil ECDSA private key")
	}
	publicKey := &privateKey.PublicKey
	keyID, err := DeriveKeyID(publicKey)
	if err != nil {
		return nil, err
	}
	algo := "ecdsa-p256-sha256"
	switch privateKey.Curve {
	case elliptic.P384():
		algo = "ecdsa-p384-sha384"
	case elliptic.P521():
		algo = "ecdsa-p521-sha512"
	}
	ver := "local-ecdsa-v1"
	if len(keyVersion) > 0 && strings.TrimSpace(keyVersion[0]) != "" {
		ver = strings.TrimSpace(keyVersion[0])
	}
	return &LocalECDSASigner{
		privateKey: privateKey,
		publicKey:  publicKey,
		keyID:      keyID,
		keyVersion: ver,
		algorithm:  algo,
	}, nil
}

func (s *LocalECDSASigner) KeyID() string               { return s.keyID }
func (s *LocalECDSASigner) KeyVersion() string          { return s.keyVersion }
func (s *LocalECDSASigner) PublicKey() crypto.PublicKey { return s.publicKey }
func (s *LocalECDSASigner) Algorithm() string           { return s.algorithm }

func (s *LocalECDSASigner) Sign(ctx context.Context, statement map[string]any) ([]byte, error) {
	if ctx != nil && ctx.Err() != nil {
		return nil, ctx.Err()
	}
	payload, err := dsseMarshalStatement(statement)
	if err != nil {
		return nil, fmt.Errorf("marshal statement: %w", err)
	}
	pae := dssePAE(dssePayloadType, payload)
	var digest []byte
	switch s.privateKey.Curve {
	case elliptic.P384():
		h := sha512.Sum384(pae)
		digest = h[:]
	case elliptic.P521():
		h := sha512.Sum512(pae)
		digest = h[:]
	default:
		h := sha256.Sum256(pae)
		digest = h[:]
	}
	sig, err := ecdsa.SignASN1(rand.Reader, s.privateKey, digest)
	if err != nil {
		return nil, fmt.Errorf("ecdsa sign: %w", err)
	}
	return FormatDSSE(statement, s.keyID, sig)
}

// LocalRSASigner implements Signer for local RSA private keys.
type LocalRSASigner struct {
	privateKey *rsa.PrivateKey
	publicKey  *rsa.PublicKey
	keyID      string
	keyVersion string
	algorithm  string
}

// NewLocalRSASigner creates a Signer from an rsa.PrivateKey.
func NewLocalRSASigner(privateKey *rsa.PrivateKey, keyVersion ...string) (*LocalRSASigner, error) {
	if privateKey == nil {
		return nil, errors.New("nil RSA private key")
	}
	publicKey := &privateKey.PublicKey
	keyID, err := DeriveKeyID(publicKey)
	if err != nil {
		return nil, err
	}
	ver := "local-rsa-v1"
	if len(keyVersion) > 0 && strings.TrimSpace(keyVersion[0]) != "" {
		ver = strings.TrimSpace(keyVersion[0])
	}
	return &LocalRSASigner{
		privateKey: privateKey,
		publicKey:  publicKey,
		keyID:      keyID,
		keyVersion: ver,
		algorithm:  "rsa-pss-2048-sha256",
	}, nil
}

func (s *LocalRSASigner) KeyID() string               { return s.keyID }
func (s *LocalRSASigner) KeyVersion() string          { return s.keyVersion }
func (s *LocalRSASigner) PublicKey() crypto.PublicKey { return s.publicKey }
func (s *LocalRSASigner) Algorithm() string           { return s.algorithm }

func (s *LocalRSASigner) Sign(ctx context.Context, statement map[string]any) ([]byte, error) {
	if ctx != nil && ctx.Err() != nil {
		return nil, ctx.Err()
	}
	payload, err := dsseMarshalStatement(statement)
	if err != nil {
		return nil, fmt.Errorf("marshal statement: %w", err)
	}
	pae := dssePAE(dssePayloadType, payload)
	h := sha256.Sum256(pae)
	sig, err := rsa.SignPSS(rand.Reader, s.privateKey, crypto.SHA256, h[:], nil)
	if err != nil {
		return nil, fmt.Errorf("rsa pss sign: %w", err)
	}
	return FormatDSSE(statement, s.keyID, sig)
}

// NewLocalSignerFromPath parses PKCS#8 or PKCS#1 PEM file and returns the appropriate Signer.
func NewLocalSignerFromPath(path string, keyVersion ...string) (Signer, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read private key %s: %w", path, err)
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, fmt.Errorf("parse private key %s: no PEM block", path)
	}
	// Try PKCS#8 first
	if parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		switch k := parsed.(type) {
		case ed25519.PrivateKey:
			return NewLocalEd25519SignerFromKey(k, keyVersion...)
		case *ecdsa.PrivateKey:
			return NewLocalECDSASigner(k, keyVersion...)
		case *rsa.PrivateKey:
			return NewLocalRSASigner(k, keyVersion...)
		default:
			return nil, fmt.Errorf("unsupported private key type %T in %s", parsed, path)
		}
	}
	// Try EC private key
	if ecKey, err := x509.ParseECPrivateKey(block.Bytes); err == nil {
		return NewLocalECDSASigner(ecKey, keyVersion...)
	}
	// Try PKCS#1 RSA private key
	if rsaKey, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return NewLocalRSASigner(rsaKey, keyVersion...)
	}
	return nil, fmt.Errorf("failed to parse private key %s as PKCS#8, EC, or PKCS#1", path)
}

func dsseMarshalStatement(statement map[string]any) ([]byte, error) {
	return json.Marshal(statement)
}
