// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package attestation

import (
	"crypto"
	"crypto/ed25519"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// KeyStatus represents the lifecycle state of a signing key in the history ledger.
type KeyStatus string

const (
	KeyStatusActive  KeyStatus = "active"
	KeyStatusRetired KeyStatus = "retired"
	KeyStatusRevoked KeyStatus = "revoked"
)

// KeyEntry represents an immutable entry in the key history ledger.
type KeyEntry struct {
	KeyID      string           `json:"key_id"`
	KeyVersion string           `json:"key_version"`
	Algorithm  string           `json:"algorithm"`
	PublicKey  crypto.PublicKey `json:"-"`
	PublicKeyPEM string         `json:"public_key_pem,omitempty"`
	ValidFrom  time.Time        `json:"valid_from"`
	ValidUntil time.Time        `json:"valid_until,omitempty"`
	RetiredAt  time.Time        `json:"retired_at,omitempty"`
	Status     KeyStatus        `json:"status"`
}

// KeyHistoryStore manages the active signing key and historical public keys for archive verification.
type KeyHistoryStore struct {
	mu          sync.RWMutex
	keys        map[string]*KeyEntry
	activeKeyID string
}

// NewKeyHistoryStore initializes an empty key history ledger.
func NewKeyHistoryStore() *KeyHistoryStore {
	return &KeyHistoryStore{
		keys: make(map[string]*KeyEntry),
	}
}

// RegisterKey adds a public key entry to the history ledger.
func (s *KeyHistoryStore) RegisterKey(keyID string, pub crypto.PublicKey, keyVersion string, validFrom time.Time, status KeyStatus) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if keyID == "" {
		derived, err := DeriveKeyID(pub)
		if err != nil {
			return fmt.Errorf("derive key ID: %w", err)
		}
		keyID = derived
	}

	spkiBytes, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		return fmt.Errorf("marshal PKIX public key: %w", err)
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{
		Type:  "PUBLIC KEY",
		Bytes: spkiBytes,
	})

	entry := &KeyEntry{
		KeyID:        keyID,
		KeyVersion:   keyVersion,
		Algorithm:    SigningAlgorithmEd25519,
		PublicKey:    pub,
		PublicKeyPEM: string(pemBytes),
		ValidFrom:    validFrom,
		Status:       status,
	}

	s.keys[keyID] = entry
	if status == KeyStatusActive {
		s.activeKeyID = keyID
	}
	return nil
}

// RegisterActiveSigner registers a signer as the current active key and records it in history.
func (s *KeyHistoryStore) RegisterActiveSigner(signer Signer, validFrom time.Time) error {
	if signer == nil {
		return errors.New("cannot register nil signer")
	}
	return s.RegisterKey(signer.KeyID(), signer.PublicKey(), signer.KeyVersion(), validFrom, KeyStatusActive)
}

// Rotate marks the currently active key as retired and installs a new active signer.
func (s *KeyHistoryStore) Rotate(newSigner Signer, rotationTime time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if newSigner == nil {
		return errors.New("cannot rotate to nil signer")
	}

	// Retire old active key if present
	if s.activeKeyID != "" {
		if old, exists := s.keys[s.activeKeyID]; exists {
			old.Status = KeyStatusRetired
			old.RetiredAt = rotationTime
			old.ValidUntil = rotationTime
		}
	}

	newKeyID := newSigner.KeyID()
	spkiBytes, err := x509.MarshalPKIXPublicKey(newSigner.PublicKey())
	if err != nil {
		return fmt.Errorf("marshal new public key: %w", err)
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{
		Type:  "PUBLIC KEY",
		Bytes: spkiBytes,
	})

	entry := &KeyEntry{
		KeyID:        newKeyID,
		KeyVersion:   newSigner.KeyVersion(),
		Algorithm:    newSigner.Algorithm(),
		PublicKey:    newSigner.PublicKey(),
		PublicKeyPEM: string(pemBytes),
		ValidFrom:    rotationTime,
		Status:       KeyStatusActive,
	}

	s.keys[newKeyID] = entry
	s.activeKeyID = newKeyID
	return nil
}

// GetKey retrieves a key entry by KeyID.
func (s *KeyHistoryStore) GetKey(keyID string) (*KeyEntry, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	entry, ok := s.keys[keyID]
	if !ok {
		return nil, fmt.Errorf("key ID %s not found in key history ledger", keyID)
	}
	return entry, nil
}

// GetActiveKey returns the currently active KeyEntry.
func (s *KeyHistoryStore) GetActiveKey() (*KeyEntry, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.activeKeyID == "" {
		return nil, errors.New("no active signing key configured")
	}
	return s.keys[s.activeKeyID], nil
}

// LoadPublicKeysFromDir reads all PEM public keys in a directory and registers them.
func (s *KeyHistoryStore) LoadPublicKeysFromDir(dirPath string) (int, error) {
	entries, err := os.ReadDir(dirPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return 0, nil
		}
		return 0, fmt.Errorf("read key directory %s: %w", dirPath, err)
	}

	loaded := 0
	for _, entry := range entries {
		if entry.IsDir() || (!strings.HasSuffix(entry.Name(), ".pem") && !strings.HasSuffix(entry.Name(), ".pub")) {
			continue
		}
		path := filepath.Join(dirPath, entry.Name())
		raw, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		block, _ := pem.Decode(raw)
		if block == nil {
			continue
		}
		pub, err := x509.ParsePKIXPublicKey(block.Bytes)
		if err != nil {
			continue
		}
		if edPub, ok := pub.(ed25519.PublicKey); ok {
			keyID, err := DeriveKeyID(edPub)
			if err == nil {
				_ = s.RegisterKey(keyID, edPub, entry.Name(), time.Now().UTC(), KeyStatusActive)
				loaded++
			}
		}
	}
	return loaded, nil
}
