// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package obscel

import (
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"
)

// PseudonymDomain is the version-pinned domain-separation label bound into every derived
// pseudonym key. Changing it invalidates every pseudonym in existence, so it is versioned
// rather than edited: a new scheme takes a new /vN suffix and a new epoch.
const PseudonymDomain = "signalloom/identity/alias-pseudonym/v1"

// MinRootKeyBytes is the minimum accepted root key material length. HMAC-SHA256's
// security target is 256 bits; accepting less would let a short passphrase masquerade as a key.
const MinRootKeyBytes = 32

// PseudonymHexLen is the length of a hex-encoded HMAC-SHA256 pseudonym.
const PseudonymHexLen = 64

var (
	// ErrRootKeyTooShort is returned when root key material is absent or under-length.
	// This is a fail-closed refusal: there is no weaker pseudonymisation mode to fall back to.
	ErrRootKeyTooShort = fmt.Errorf("obscel: pseudonym root key must be at least %d bytes of key material", MinRootKeyBytes)
	// ErrTenantRequired is returned when no tenant scope is supplied.
	// An empty tenant would collapse every tenant into one correlation domain.
	ErrTenantRequired = errors.New("obscel: pseudonym tenant identifier is required; an empty tenant would merge tenant correlation domains")
	// ErrValueRequired is returned when the value to pseudonymise is empty.
	ErrValueRequired = errors.New("obscel: pseudonym input value is required")
)

// HMACPseudonymiser derives tenant-and-epoch-scoped keys from root key material
// and produces deterministic HMAC-SHA256 pseudonyms.
type HMACPseudonymiser struct {
	root   []byte
	tenant string
	epoch  uint32

	once sync.Once
	key  []byte
	err  error
}

// NewHMACPseudonymiser constructs a pseudonymiser for a given root key, tenant, and epoch.
func NewHMACPseudonymiser(root []byte, tenant string, epoch uint32) (*HMACPseudonymiser, error) {
	if len(root) < MinRootKeyBytes {
		return nil, ErrRootKeyTooShort
	}
	if tenant == "" {
		return nil, ErrTenantRequired
	}
	cp := make([]byte, len(root))
	copy(cp, root)
	return &HMACPseudonymiser{
		root:   cp,
		tenant: tenant,
		epoch:  epoch,
	}, nil
}

// Tenant returns the tenant bound to this pseudonymiser.
func (p *HMACPseudonymiser) Tenant() string {
	return p.tenant
}

// Epoch returns the rotation epoch bound to this pseudonymiser.
func (p *HMACPseudonymiser) Epoch() uint32 {
	return p.epoch
}

// deriveInfo builds the HKDF info parameter.
// Unambiguity: Every variable-length component is length-prefixed and every fixed-width component
// is a fixed-width big-endian integer, so no two distinct (epoch, tenant) pairs can serialise to
// the same byte string.
func deriveInfo(epoch uint32, tenantID string) []byte {
	domain := []byte(PseudonymDomain)
	tenant := []byte(tenantID)

	info := make([]byte, 0, 4+len(domain)+4+4+len(tenant))
	info = binary.BigEndian.AppendUint32(info, uint32(len(domain)))
	info = append(info, domain...)
	info = binary.BigEndian.AppendUint32(info, epoch)
	info = binary.BigEndian.AppendUint32(info, uint32(len(tenant)))
	info = append(info, tenant...)
	return info
}

func (p *HMACPseudonymiser) deriveKey() error {
	p.once.Do(func() {
		key, err := hkdf.Key(sha256.New, p.root, nil, string(deriveInfo(p.epoch, p.tenant)), 32)
		if err != nil {
			p.err = fmt.Errorf("obscel: pseudonym key derivation failed: %w", err)
			return
		}
		p.key = key
	})
	return p.err
}

// Pseudonym returns the hex-encoded, tenant-and-epoch-scoped HMAC-SHA256 pseudonym for value.
// An empty input returns an empty output and a nil error.
func (p *HMACPseudonymiser) Pseudonym(value string) (string, error) {
	if value == "" {
		return "", nil
	}
	if err := p.deriveKey(); err != nil {
		return "", err
	}
	mac := hmac.New(sha256.New, p.key)
	mac.Write([]byte(value))
	return hex.EncodeToString(mac.Sum(nil)), nil
}

// IsPseudonym reports whether s has the exact shape of a pseudonym produced by this package:
// PseudonymHexLen lowercase hex characters.
func IsPseudonym(s string) bool {
	if len(s) != PseudonymHexLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') {
			continue
		}
		return false
	}
	return true
}
