// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package identity

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

// MinPseudonymRootKeyBytes is the minimum accepted root key material length. HMAC-SHA256's
// security target is 256 bits; accepting less would let a short passphrase masquerade as a key.
const MinPseudonymRootKeyBytes = 32

// PseudonymHexLen is the length of a hex-encoded HMAC-SHA256 pseudonym.
const PseudonymHexLen = 64

var (
	// ErrPseudonymRootKeyTooShort is returned when root key material is absent or under-length.
	// This is a fail-closed refusal: there is no weaker pseudonymisation mode to fall back to.
	ErrPseudonymRootKeyTooShort = fmt.Errorf("identity: pseudonym root key must be at least %d bytes of key material", MinPseudonymRootKeyBytes)
	// ErrPseudonymTenantRequired is returned when no tenant scope is supplied.
	// An empty tenant would collapse every tenant into one correlation domain.
	ErrPseudonymTenantRequired = errors.New("identity: pseudonym tenant identifier is required; an empty tenant would merge tenant correlation domains")
	// ErrPseudonymValueRequired is returned when the value to pseudonymise is empty.
	// Returning "" here would make an error value indistinguishable from a legitimate answer.
	ErrPseudonymValueRequired = errors.New("identity: pseudonym input value is required")
)

// PseudonymKeyRing derives per-tenant, per-epoch pseudonymisation keys from KMS-supplied root
// key material and computes keyed HMAC-SHA256 pseudonyms with them.
//
// Scope rationale. The pseudonym is a join key: the actor graph resolves aliases by comparing
// pseudonyms, so it must be deterministic for a given (tenant, epoch, value). A per-row random
// salt would be cryptographically stronger and functionally useless. A single global key would
// be deterministic but would let one tenant's pseudonym set be compared against another's, which
// is a cross-tenant correlation channel no key length fixes. Tenant-and-epoch scope is the
// smallest scope that preserves the join.
//
// Epoch rotation. Incrementing the epoch changes every pseudonym for every tenant at once, which
// re-keys the entire join surface. It is therefore a planned migration, never an automatic or
// time-triggered event. See docs/signalloom/sldp-p2-1-proof.md for the rotation procedure.
type PseudonymKeyRing struct {
	root  []byte
	epoch uint32

	// derived caches tenant keys so HKDF runs once per tenant rather than once per lookup.
	derived sync.Map // map[string][]byte
}

// NewPseudonymKeyRing constructs a key ring from root key material and an epoch.
// It fails closed: absent or under-length key material is an error, never a degraded mode.
func NewPseudonymKeyRing(root []byte, epoch uint32) (*PseudonymKeyRing, error) {
	if len(root) < MinPseudonymRootKeyBytes {
		return nil, ErrPseudonymRootKeyTooShort
	}
	cp := make([]byte, len(root))
	copy(cp, root)
	return &PseudonymKeyRing{root: cp, epoch: epoch}, nil
}

// Epoch returns the rotation epoch bound into every key this ring derives.
func (k *PseudonymKeyRing) Epoch() uint32 { return k.epoch }

// pseudonymInfo builds the HKDF info parameter.
//
// Unambiguity. Every variable-length component is length-prefixed and every fixed-width component
// is a fixed-width big-endian integer, so no two distinct (epoch, tenant) pairs can serialise to
// the same byte string. Without the length prefix, tenant "ab" and tenant "a" followed by a value
// beginning "b" would be indistinguishable.
func pseudonymInfo(epoch uint32, tenantID string) []byte {
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

// tenantKey returns the HKDF-derived 32-byte key for a tenant, deriving and caching on first use.
func (k *PseudonymKeyRing) tenantKey(tenantID string) ([]byte, error) {
	if cached, ok := k.derived.Load(tenantID); ok {
		return cached.([]byte), nil
	}
	key, err := hkdf.Key(sha256.New, k.root, nil, string(pseudonymInfo(k.epoch, tenantID)), 32)
	if err != nil {
		return nil, fmt.Errorf("identity: pseudonym key derivation failed: %w", err)
	}
	actual, _ := k.derived.LoadOrStore(tenantID, key)
	return actual.([]byte), nil
}

// Pseudonym returns the hex-encoded, tenant-and-epoch-scoped HMAC-SHA256 pseudonym for value.
//
// It is deterministic within a (tenant, epoch) scope and incomparable across scopes. It never
// returns a non-empty string alongside an error, and never returns "" alongside a nil error —
// an empty pseudonym would be indistinguishable from "this identifier has no pseudonym".
func (k *PseudonymKeyRing) Pseudonym(tenantID, value string) (string, error) {
	if tenantID == "" {
		return "", ErrPseudonymTenantRequired
	}
	if value == "" {
		return "", ErrPseudonymValueRequired
	}
	key, err := k.tenantKey(tenantID)
	if err != nil {
		return "", err
	}
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(value))
	return hex.EncodeToString(mac.Sum(nil)), nil
}

// IsPseudonym reports whether s has the exact shape of a pseudonym produced by this package:
// PseudonymHexLen lowercase hex characters. Used by the schema-level fail-closed check and by
// tests that must distinguish a real pseudonym from a truncated or absent one.
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
