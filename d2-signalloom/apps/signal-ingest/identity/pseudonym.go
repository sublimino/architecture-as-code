// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package identity

import "github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/pseudonym"

// The keyed-pseudonym primitive built by SLDP-P2-1 moved to the leaf package `pseudonym` in
// SLDP-P3-1. It had to: the columnar store needs the same primitive, and `identity` already imports
// `store` (identity/claim_verifier.go), so `store` importing `identity` is an import cycle. A second
// HMAC implementation inside `store` would have been a second thing to get wrong and a second key
// space to reconcile at erasure time, so the primitive moved down instead of being duplicated.
//
// Everything below is a type alias or a value re-export, so this is a compile-time relocation with
// no behavioural change whatsoever. `identity.PseudonymKeyRing` IS `pseudonym.KeyRing` — not a
// wrapper around it — so existing callers, existing tests, and `errors.Is` against the sentinel
// errors all behave exactly as before. The HKDF domain string, the epoch framing and every error
// message are byte-identical, which matters because changing any of them would invalidate every
// pseudonym already written.

// PseudonymDomain is the version-pinned domain-separation label bound into every derived key.
const PseudonymDomain = pseudonym.Domain

// MinPseudonymRootKeyBytes is the minimum accepted root key material length.
const MinPseudonymRootKeyBytes = pseudonym.MinRootKeyBytes

// PseudonymHexLen is the length of a hex-encoded HMAC-SHA256 pseudonym.
const PseudonymHexLen = pseudonym.HexLen

var (
	// ErrPseudonymRootKeyTooShort is returned when root key material is absent or under-length.
	ErrPseudonymRootKeyTooShort = pseudonym.ErrRootKeyTooShort
	// ErrPseudonymTenantRequired is returned when no tenant scope is supplied.
	ErrPseudonymTenantRequired = pseudonym.ErrTenantRequired
	// ErrPseudonymValueRequired is returned when the value to pseudonymise is empty.
	ErrPseudonymValueRequired = pseudonym.ErrValueRequired
)

// PseudonymKeyRing derives per-tenant, per-epoch pseudonymisation keys and computes keyed
// HMAC-SHA256 pseudonyms with them.
type PseudonymKeyRing = pseudonym.KeyRing

// NewPseudonymKeyRing constructs a key ring from root key material and an epoch.
// It fails closed: absent or under-length key material is an error, never a degraded mode.
func NewPseudonymKeyRing(root []byte, epoch uint32) (*PseudonymKeyRing, error) {
	return pseudonym.NewKeyRing(root, epoch)
}

// IsPseudonym reports whether s has the exact shape of a pseudonym produced by this package.
func IsPseudonym(s string) bool { return pseudonym.IsPseudonym(s) }
