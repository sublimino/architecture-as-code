// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

//go:build frostdb

package store

import (
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strconv"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/pseudonym"
)

// SegmentPseudonymKeyEnv holds hex-encoded root key material for segment pseudonymisation.
const SegmentPseudonymKeyEnv = "SIGNAL_SEGMENT_PSEUDONYM_KEY"

// SegmentPseudonymEpochEnv holds the rotation epoch. Absent means epoch 0.
const SegmentPseudonymEpochEnv = "SIGNAL_SEGMENT_PSEUDONYM_EPOCH"

// SegmentPseudonymTenantEnv names the tenant correlation scope for this store.
const SegmentPseudonymTenantEnv = "SIGNAL_SEGMENT_PSEUDONYM_TENANT"

// DefaultSegmentTenantScope matches the checkpoint's tenant_scope so evidence and segments agree
// about which correlation domain a pseudonym belongs to.
const DefaultSegmentTenantScope = "signaldb/observations"

// evidenceRefDomain separates the evidence-reference digest from the identity pseudonym space.
//
// Without it, a raw_evidence_ref that happened to equal an actor_hint would produce the same
// digest, which is a correlation channel across two columns that should be unlinkable.
const evidenceRefDomain = "signalloom/segment/evidence-ref/v1\x00"

var (
	// ErrSegmentPseudonymKeyRequired is a fail-closed refusal. There is no weaker mode to fall
	// back to: a store that cannot pseudonymise must not write identity, and a store that writes
	// identity unpseudonymised is the defect this card exists to remove.
	ErrSegmentPseudonymKeyRequired = fmt.Errorf(
		"store: segment pseudonymisation key is required; set %s to at least %d bytes of hex-encoded key material",
		SegmentPseudonymKeyEnv, pseudonym.MinRootKeyBytes)

	// ErrSegmentPseudonymTenantRequired refuses an empty tenant scope, which would merge every
	// tenant into one correlation domain.
	ErrSegmentPseudonymTenantRequired = errors.New(
		"store: segment pseudonymisation tenant scope is required; an empty scope would merge tenant correlation domains")
)

// SegmentPseudonymiser converts direct identifiers into keyed pseudonyms for the columnar store.
//
// It wraps pseudonym.KeyRing rather than computing its own HMAC. That ring is already
// audited, already tenant-and-epoch scoped, and already fails closed below 32 bytes of key
// material; a second HMAC implementation here would be a second thing to get wrong and a second
// key space to reconcile at erasure time.
//
// Why pseudonymise rather than encrypt. An encrypted column has no usable equality or ordering, so
// Arrow predicate pushdown degrades to a full scan and decrypt — measured at 19.43 ms p95 against
// a 2.75 ms budget (SLDP-P3-PRE §6.2). A keyed HMAC is deterministic, so equality on the pseudonym
// is exactly equality on the plaintext and the query plan does not change at all.
type SegmentPseudonymiser struct {
	ring   *pseudonym.KeyRing
	tenant string
}

// NewSegmentPseudonymiser builds a pseudonymiser from raw root key material.
//
// It never returns a usable pseudonymiser alongside an error.
func NewSegmentPseudonymiser(root []byte, tenant string, epoch uint32) (*SegmentPseudonymiser, error) {
	if tenant == "" {
		return nil, ErrSegmentPseudonymTenantRequired
	}
	if len(root) < pseudonym.MinRootKeyBytes {
		return nil, ErrSegmentPseudonymKeyRequired
	}
	ring, err := pseudonym.NewKeyRing(root, epoch)
	if err != nil {
		return nil, fmt.Errorf("store: segment pseudonymiser: %w", err)
	}
	return &SegmentPseudonymiser{ring: ring, tenant: tenant}, nil
}

// NewSegmentPseudonymiserFromEnv builds a pseudonymiser from the environment.
//
// An unset or short key is an error, never a default. SLDP-P2-1 removed exactly this defect from
// the secret scrubber, where an absent salt fell back to a committed literal and every deployment
// that never set the variable shared one attacker-known key.
func NewSegmentPseudonymiserFromEnv() (*SegmentPseudonymiser, error) {
	raw := os.Getenv(SegmentPseudonymKeyEnv)
	if raw == "" {
		return nil, ErrSegmentPseudonymKeyRequired
	}
	root, err := hex.DecodeString(raw)
	if err != nil {
		return nil, fmt.Errorf("store: %s must be hex-encoded: %w", SegmentPseudonymKeyEnv, err)
	}
	if len(root) < pseudonym.MinRootKeyBytes {
		return nil, ErrSegmentPseudonymKeyRequired
	}

	// KNOWN INCONSISTENCY (SLDP-P3-1 finding F9): the key path fails closed here and the tenant
	// path does not. ErrSegmentPseudonymTenantRequired exists because "an empty scope would merge
	// tenant correlation domains" — and this default does exactly that, silently, for any
	// multi-tenant deployment that forgets the variable. It is retained for now only because every
	// current caller is single-scope and changing it is a deployment-breaking change that belongs
	// with the P4 key hierarchy, not smuggled in here. Do not read this as safe.
	tenant := os.Getenv(SegmentPseudonymTenantEnv)
	if tenant == "" {
		tenant = DefaultSegmentTenantScope
	}

	var epoch uint32
	if rawEpoch := os.Getenv(SegmentPseudonymEpochEnv); rawEpoch != "" {
		parsed, parseErr := strconv.ParseUint(rawEpoch, 10, 32)
		if parseErr != nil {
			return nil, fmt.Errorf("store: %s must be a uint32: %w", SegmentPseudonymEpochEnv, parseErr)
		}
		epoch = uint32(parsed)
	}

	return NewSegmentPseudonymiser(root, tenant, epoch)
}

// Epoch returns the rotation epoch bound into every pseudonym this instance produces.
func (p *SegmentPseudonymiser) Epoch() uint32 { return p.ring.Epoch() }

// Tenant returns the correlation scope bound into every pseudonym this instance produces.
func (p *SegmentPseudonymiser) Tenant() string { return p.tenant }

// Pseudonym returns the keyed pseudonym for an identifier.
//
// An empty input returns an empty output with a nil error. That is deliberate and is not the
// "error value is a legal answer" defect: the question being answered is "what is the pseudonym of
// this identifier", and an observation with no actor_hint has no actor_hint pseudonym. Hashing ""
// would instead write a constant 64-hex value into every such row, which is a join key linking
// every identity-free observation to every other — a correlation channel invented by the fix.
func (p *SegmentPseudonymiser) Pseudonym(value string) (string, error) {
	if value == "" {
		return "", nil
	}
	out, err := p.ring.Pseudonym(p.tenant, value)
	if err != nil {
		return "", fmt.Errorf("store: segment pseudonym: %w", err)
	}
	return out, nil
}

// EvidenceRefDigest returns the keyed digest for a raw evidence reference.
//
// raw_evidence_ref is a URI, not a join key, so it does not need to be comparable with anything.
// It is domain-separated from the identity pseudonym space so the same string appearing as both an
// evidence URI and an actor hint does not produce one linkable value in two columns.
func (p *SegmentPseudonymiser) EvidenceRefDigest(value string) (string, error) {
	if value == "" {
		return "", nil
	}
	out, err := p.ring.Pseudonym(p.tenant, evidenceRefDomain+value)
	if err != nil {
		return "", fmt.Errorf("store: evidence ref digest: %w", err)
	}
	return out, nil
}
