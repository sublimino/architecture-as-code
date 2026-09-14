// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package subjectkey implements the per-subject key hierarchy and the idempotent erasure saga that
// makes GDPR Article 17 crypto-shredding erase ONE data subject rather than all of them (SLDP-P4-1).
//
// # Why this package exists
//
// Before this card every envelope in the identity graph wrapped its per-record data key under one
// global service root key (identity/encryption.go, AESGCMEncryptor.key). One key, every subject,
// every tenant. Destroying it erases everybody and breaks operational access; not destroying it
// erases nobody. "Crypto-shredding" on that layout is a claim that cannot be true, which is worse
// than an absent feature because it gets reported to a data subject and to a regulator as done.
//
// # The hierarchy
//
//	Master root KEK                      (32+ bytes, operator-supplied, never stored by this package)
//	  └─ HKDF-SHA256 ─> Tenant KEK       (derived on demand; NEVER destroyed, so derivation is safe)
//	       └─ AES-256-GCM wrap ─> Subject DEK version N   <── THE CRYPTO-SHRED BOUNDARY
//	            └─ AES-256-GCM ─> the subject's ciphertext
//
// # The decision the whole package rests on
//
// The per-subject DEK is read from crypto/rand and persisted ONLY in wrapped form. The tidy
// alternative — DEK = HKDF(tenantKEK, subjectPseudonym) — needs no storage, no provisioning and no
// version table, and it draws an identical diagram. It is also a complete defeat of the feature:
// anyone holding the master KEK re-derives the DEK after "destruction", so the destroy is theatre
// and nothing about the code says so. A derived key cannot be destroyed. A random key stored in
// exactly one wrapped copy can.
//
// The tenant KEK is derived precisely BECAUSE it is never destroyed. That asymmetry is the design:
// derivation is correct for the key that must survive and fatal for the key that must not.
//
// # What erasure actually achieves, stated plainly
//
// Destroying a subject DEK removes the ability to RESOLVE the subject's ciphertext. It does not
// remove the ciphertext, and it cannot remove a pseudonym already written into a signed, chained
// Parquet segment — rewriting one would break checkpoint continuity for everything after it. So:
//
//   - Article 17 (erasure): satisfied, by loss of resolvability.
//   - Article 5(1)(e) (storage limitation): NOT satisfied. The ciphertext persists indefinitely.
//     Reconciling that with the checkpoint chain is SLDP-P6-1's retention controller, not this card.
//
// Both facts are recorded in every DestructionReceipt rather than left to a reader's optimism.
package subjectkey

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"sync"
)

// Domain is the version-pinned domain-separation label bound into every derived tenant KEK.
//
// Changing it invalidates every tenant KEK in existence and therefore every wrapped subject DEK, so
// it is versioned rather than edited: a new scheme takes a new /vN suffix.
const Domain = "signalloom/identity/subject-key-hierarchy/v1"

// wrapDomain is the separate label bound into the AAD of a wrapped DEK. It is distinct from Domain
// so that a wrap AAD can never be confused with an HKDF info string even if both were logged.
const wrapDomain = "signalloom/identity/subject-dek-wrap/v1"

// MinMasterKeyBytes is the minimum accepted master root KEK length. HKDF-SHA256's security target is
// 256 bits; accepting less would let a short passphrase masquerade as a key.
const MinMasterKeyBytes = 32

// DEKBytes is the size of a per-subject data encryption key. AES-256 needs exactly 32 bytes, and a
// shorter value would be silently stretched by the cipher constructors rather than rejected.
const DEKBytes = 32

// TenantKEKBytes is the size of a derived tenant key encryption key.
const TenantKEKBytes = 32

// wrappedDEKLen is the exact length of a wrapped DEK: 12-byte nonce + 32-byte key + 16-byte GCM tag.
// Pinning it turns a length field from an attacker-influenced value into a checked constant.
const wrappedDEKLen = 12 + DEKBytes + 16

// MaxKeyVersionsPerSubject bounds how many live key versions one subject may accumulate.
//
// An unbounded version history is itself a retention problem: every retained version is another
// wrapped key that must be destroyed on erasure and another row that outlives its purpose. The bound
// is enforced on provision, and the surplus oldest version is destroyed rather than left to grow.
// Eight is a policy choice, stated here rather than buried at a call site: it survives a quarterly
// rotation cadence for two years, and is small enough that an erasure's destruction set is bounded.
const MaxKeyVersionsPerSubject = 8

var (
	// ErrMasterKeyTooShort is a fail-closed refusal. There is no weaker hierarchy to fall back to.
	ErrMasterKeyTooShort = fmt.Errorf("subjectkey: master root KEK must be at least %d bytes of key material", MinMasterKeyBytes)

	// ErrTenantRequired is returned when no tenant scope is supplied. An empty tenant would collapse
	// every tenant into one key domain, which is the defect this hierarchy exists to prevent.
	ErrTenantRequired = errors.New("subjectkey: tenant identifier is required; an empty tenant would merge tenant key domains")

	// ErrSubjectRequired is returned when no subject pseudonym is supplied.
	ErrSubjectRequired = errors.New("subjectkey: subject pseudonym is required")

	// ErrInvalidVersion is returned when a key version is not a positive integer.
	ErrInvalidVersion = errors.New("subjectkey: key version must be a positive integer")

	// ErrUnwrapFailed is returned when a wrapped DEK does not open. Every cause — wrong tenant,
	// wrong subject, wrong version, tampering, destruction — returns this same class deliberately,
	// so a caller checking only one of them cannot miss the others.
	ErrUnwrapFailed = errors.New("subjectkey: wrapped data key did not open: wrong scope, tampered, or destroyed")

	// ErrWrappedKeyMalformed is returned when wrapped bytes are not the pinned length.
	ErrWrappedKeyMalformed = fmt.Errorf("subjectkey: wrapped data key must be exactly %d bytes", wrappedDEKLen)
)

// KeyScope names exactly one wrapped DEK. Every field is bound into the wrap AAD, so a wrapped key
// only opens in the scope it was created for: moving ciphertext between subjects, versions, epochs
// or tenants fails the GCM tag rather than decrypting into a value that silently disagrees.
type KeyScope struct {
	TenantID         string
	SubjectPseudonym string
	KeyEpoch         uint32
	KeyVersion       int
}

// Validate rejects a scope that could not name a real key.
func (s KeyScope) Validate() error {
	if s.TenantID == "" {
		return ErrTenantRequired
	}
	if s.SubjectPseudonym == "" {
		return ErrSubjectRequired
	}
	if s.KeyVersion <= 0 {
		return ErrInvalidVersion
	}
	return nil
}

// Hierarchy derives tenant KEKs from a master root KEK and wraps or unwraps per-subject DEKs.
//
// It deliberately exposes NO method returning raw tenant KEK bytes and NO method that destroys,
// deletes or zeroes a tenant KEK. A tenant KEK has no durable representation at all — it is derived
// on demand — so the per-subject erasure path has nothing to reach even if it tried. That is the
// guard: not a check that refuses, but an absence of surface. TestHierarchy_NoTenantKEKDestruction
// greps this package's source and fails on any symbol that would reintroduce one.
type Hierarchy struct {
	master []byte

	// derived caches tenant KEKs so HKDF runs once per (tenant, epoch) rather than once per wrap.
	//
	// This cache is deliberately NOT purged by a per-subject erasure. It holds tenant keys, which
	// survive erasure by design; purging it would be a cross-subject side effect dressed up as
	// hygiene, and would not make any destroyed subject DEK less destroyed. See cacheRegistry.
	derived sync.Map // map[string][]byte
}

// NewHierarchy constructs a hierarchy from master root key material.
//
// It fails closed on short or absent key material. There is deliberately no development opt-in and
// no passthrough mode: for encryption at rest a passthrough yields weaker data that still exists,
// whereas for a destruction hierarchy a passthrough is a lie about an irreversible act.
func NewHierarchy(masterKey []byte) (*Hierarchy, error) {
	if len(masterKey) < MinMasterKeyBytes {
		return nil, ErrMasterKeyTooShort
	}
	cp := make([]byte, len(masterKey))
	copy(cp, masterKey)
	return &Hierarchy{master: cp}, nil
}

// deriveInfo builds the HKDF info string from length-prefixed fields.
//
// Length prefixing is not decoration: without it, tenant "ab"+"c" and "a"+"bc" produce the same
// concatenation and therefore the same tenant KEK, which is a cross-tenant key collision reachable
// by choosing tenant names.
func deriveInfo(epoch uint32, tenantID string) []byte {
	info := make([]byte, 0, 4+len(Domain)+4+4+len(tenantID))
	info = binary.BigEndian.AppendUint32(info, uint32(len(Domain)))
	info = append(info, Domain...)
	info = binary.BigEndian.AppendUint32(info, epoch)
	info = binary.BigEndian.AppendUint32(info, uint32(len(tenantID)))
	info = append(info, tenantID...)
	return info
}

// tenantKEK returns the derived tenant key, deriving and caching on first use.
//
// It is unexported and returns a slice that never leaves this package's wrap/unwrap paths. There is
// no exported accessor; see the Hierarchy doc comment for why.
func (h *Hierarchy) tenantKEK(tenantID string, epoch uint32) ([]byte, error) {
	if tenantID == "" {
		return nil, ErrTenantRequired
	}
	cacheKey := fmt.Sprintf("%d\x00%s", epoch, tenantID)
	if cached, ok := h.derived.Load(cacheKey); ok {
		return cached.([]byte), nil
	}
	key, err := hkdf.Key(sha256.New, h.master, nil, string(deriveInfo(epoch, tenantID)), TenantKEKBytes)
	if err != nil {
		return nil, fmt.Errorf("subjectkey: tenant KEK derivation failed: %w", err)
	}
	actual, _ := h.derived.LoadOrStore(cacheKey, key)
	return actual.([]byte), nil
}

// TenantKEKFingerprint returns a non-invertible fingerprint of a tenant KEK.
//
// Tests and operators need to say "the tenant KEK is unchanged" without anything being able to say
// what it is. The fingerprint is HMAC-shaped rather than a bare digest of the key: it is
// SHA-256 over a domain label plus the key, so it cannot be compared against a precomputed table of
// candidate keys without also knowing the label, and it is one-way regardless.
func (h *Hierarchy) TenantKEKFingerprint(tenantID string, epoch uint32) ([]byte, error) {
	kek, err := h.tenantKEK(tenantID, epoch)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(append([]byte(Domain+"/fingerprint\x00"), kek...))
	out := make([]byte, len(sum))
	copy(out, sum[:])
	return out, nil
}

// wrapAAD builds the additional authenticated data binding a wrapped DEK to its exact scope.
//
// Every component is length-prefixed so the concatenation is unambiguous, for the same reason
// deriveInfo prefixes: without it, (subject "ab", version 1) and (subject "a", version "b1") could
// produce the same AAD and a wrapped key would open in the wrong row.
func wrapAAD(s KeyScope) []byte {
	parts := []string{wrapDomain, s.TenantID, s.SubjectPseudonym}
	out := make([]byte, 0, 64)
	for _, p := range parts {
		out = binary.BigEndian.AppendUint32(out, uint32(len(p)))
		out = append(out, p...)
	}
	out = binary.BigEndian.AppendUint32(out, s.KeyEpoch)
	out = binary.BigEndian.AppendUint32(out, uint32(s.KeyVersion))
	return out
}

// NewDEK mints a fresh per-subject data encryption key from the system CSPRNG.
//
// It is a package function rather than a Hierarchy method to make the independence explicit: the DEK
// is NOT a function of the master key, the tenant, the subject or the version. Nothing about it can
// be recomputed. That is the entire reason destruction works.
func NewDEK() ([]byte, error) {
	dek := make([]byte, DEKBytes)
	if _, err := io.ReadFull(rand.Reader, dek); err != nil {
		return nil, fmt.Errorf("subjectkey: system CSPRNG unavailable, refusing to mint a data key: %w", err)
	}
	return dek, nil
}

// WrapDEK seals dek under the tenant KEK, binding scope into the AAD.
func (h *Hierarchy) WrapDEK(scope KeyScope, dek []byte) ([]byte, error) {
	if err := scope.Validate(); err != nil {
		return nil, err
	}
	if len(dek) != DEKBytes {
		return nil, fmt.Errorf("subjectkey: data key is %d bytes, expected %d", len(dek), DEKBytes)
	}
	kek, err := h.tenantKEK(scope.TenantID, scope.KeyEpoch)
	if err != nil {
		return nil, err
	}
	wrapped, err := sealAAD(kek, dek, wrapAAD(scope))
	if err != nil {
		return nil, fmt.Errorf("subjectkey: wrap data key: %w", err)
	}
	if len(wrapped) != wrappedDEKLen {
		return nil, fmt.Errorf("%w: got %d", ErrWrappedKeyMalformed, len(wrapped))
	}
	return wrapped, nil
}

// UnwrapDEK opens a wrapped DEK. Every failure — wrong scope, tampering, or the random bytes left
// behind by destruction — returns ErrUnwrapFailed.
func (h *Hierarchy) UnwrapDEK(scope KeyScope, wrapped []byte) ([]byte, error) {
	if err := scope.Validate(); err != nil {
		return nil, err
	}
	if len(wrapped) != wrappedDEKLen {
		return nil, fmt.Errorf("%w: got %d", ErrWrappedKeyMalformed, len(wrapped))
	}
	kek, err := h.tenantKEK(scope.TenantID, scope.KeyEpoch)
	if err != nil {
		return nil, err
	}
	dek, err := openAAD(kek, wrapped, wrapAAD(scope))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnwrapFailed, err)
	}
	if len(dek) != DEKBytes {
		return nil, fmt.Errorf("%w: unwrapped key is %d bytes", ErrUnwrapFailed, len(dek))
	}
	return dek, nil
}

// sealAAD encrypts plaintext with key and aad using AES-256-GCM, prepending the nonce.
func sealAAD(key, plaintext, aad []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("create cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("create GCM: %w", err)
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("generate nonce: %w", err)
	}
	return gcm.Seal(nonce, nonce, plaintext, aad), nil
}

// openAAD is the inverse of sealAAD.
func openAAD(key, ciphertext, aad []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("create cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("create GCM: %w", err)
	}
	if len(ciphertext) < gcm.NonceSize() {
		return nil, errors.New("ciphertext shorter than nonce")
	}
	nonce, data := ciphertext[:gcm.NonceSize()], ciphertext[gcm.NonceSize():]
	return gcm.Open(nil, nonce, data, aad)
}

// Zero overwrites b with zeroes.
//
// It uses subtle.ConstantTimeCopy rather than a range loop because the Go compiler is permitted to
// elide a write to memory it can prove is never read again, and a "securely zeroed" buffer that the
// optimiser deleted is exactly the kind of control that reads as working and is not. This is a
// best-effort mitigation, not a guarantee: Go's GC may already have copied the slice during a heap
// move, and that copy is unreachable from here. The honest claim is "the reference we hold is
// cleared", which is what the destruction receipt records.
func Zero(b []byte) {
	if len(b) == 0 {
		return
	}
	subtle.ConstantTimeCopy(1, b, make([]byte, len(b)))
}

// TamperWrapped returns a copy of wrapped with one bit flipped, for tests that must show a tampered
// key fails rather than assuming it would.
//
// It is in non-test code deliberately: the fault-injection suite and the destruction proof both need
// it, and a helper duplicated across two _test.go files drifts.
func TamperWrapped(wrapped []byte) []byte {
	out := make([]byte, len(wrapped))
	copy(out, wrapped)
	if len(out) > 0 {
		out[len(out)-1] ^= 0x01
	}
	return out
}
