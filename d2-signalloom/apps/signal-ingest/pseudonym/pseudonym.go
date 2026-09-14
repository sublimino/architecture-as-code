// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package pseudonym

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

// Domain is the version-pinned domain-separation label bound into every derived
// pseudonym key. Changing it invalidates every pseudonym in existence, so it is versioned
// rather than edited: a new scheme takes a new /vN suffix and a new epoch.
const Domain = "signalloom/identity/alias-pseudonym/v1"

// MinRootKeyBytes is the minimum accepted root key material length. HMAC-SHA256's
// security target is 256 bits; accepting less would let a short passphrase masquerade as a key.
const MinRootKeyBytes = 32

// HexLen is the length of a hex-encoded HMAC-SHA256 pseudonym.
const HexLen = 64

var (
	// ErrRootKeyTooShort is returned when root key material is absent or under-length.
	// This is a fail-closed refusal: there is no weaker pseudonymisation mode to fall back to.
	ErrRootKeyTooShort = fmt.Errorf("identity: pseudonym root key must be at least %d bytes of key material", MinRootKeyBytes)
	// ErrTenantRequired is returned when no tenant scope is supplied.
	// An empty tenant would collapse every tenant into one correlation domain.
	ErrTenantRequired = errors.New("identity: pseudonym tenant identifier is required; an empty tenant would merge tenant correlation domains")
	// ErrValueRequired is returned when the value to pseudonymise is empty.
	// Returning "" here would make an error value indistinguishable from a legitimate answer.
	ErrValueRequired = errors.New("identity: pseudonym input value is required")
)

// KeyRing derives per-tenant, per-epoch pseudonymisation keys from KMS-supplied root
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
type KeyRing struct {
	root  []byte
	epoch uint32

	// derived caches tenant keys so HKDF runs once per tenant rather than once per lookup.
	derived sync.Map // map[string][]byte
}

// NewKeyRing constructs a key ring from root key material and an epoch.
// It fails closed: absent or under-length key material is an error, never a degraded mode.
func NewKeyRing(root []byte, epoch uint32) (*KeyRing, error) {
	if len(root) < MinRootKeyBytes {
		return nil, ErrRootKeyTooShort
	}
	cp := make([]byte, len(root))
	copy(cp, root)
	return &KeyRing{root: cp, epoch: epoch}, nil
}

// Epoch returns the rotation epoch bound into every key this ring derives.
func (k *KeyRing) Epoch() uint32 { return k.epoch }

// deriveInfo builds the HKDF info parameter.
//
// Unambiguity. Every variable-length component is length-prefixed and every fixed-width component
// is a fixed-width big-endian integer, so no two distinct (epoch, tenant) pairs can serialise to
// the same byte string. Without the length prefix, tenant "ab" and tenant "a" followed by a value
// beginning "b" would be indistinguishable.
func deriveInfo(epoch uint32, tenantID string) []byte {
	domain := []byte(Domain)
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
func (k *KeyRing) tenantKey(tenantID string) ([]byte, error) {
	if cached, ok := k.derived.Load(tenantID); ok {
		return cached.([]byte), nil
	}
	key, err := hkdf.Key(sha256.New, k.root, nil, string(deriveInfo(k.epoch, tenantID)), 32)
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
func (k *KeyRing) Pseudonym(tenantID, value string) (string, error) {
	if tenantID == "" {
		return "", ErrTenantRequired
	}
	if value == "" {
		return "", ErrValueRequired
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
// HexLen lowercase hex characters. Used by the schema-level fail-closed check and by
// tests that must distinguish a real pseudonym from a truncated or absent one.
func IsPseudonym(s string) bool {
	if len(s) != HexLen {
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

// IsTenantKeyCached reports whether the HKDF-derived key for a tenant is already memoised.
//
// Exported purely as a test seam. The cache is the reason HKDF runs once per tenant rather than
// once per lookup, and a regression there is a silent performance cliff rather than a failure — so
// it is asserted rather than assumed. The key material itself is never exposed.
func (k *KeyRing) IsTenantKeyCached(tenantID string) bool {
	_, ok := k.derived.Load(tenantID)
	return ok
}
