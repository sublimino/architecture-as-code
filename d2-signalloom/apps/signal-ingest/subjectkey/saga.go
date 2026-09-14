// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package subjectkey

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/privacy"
)

// FaultPoint names one injectable failure site.
//
// Faults are a first-class, non-test seam. The saga's whole claim is that it survives a crash at any
// boundary, and a claim about crash behaviour that can only be exercised by actually crashing is a
// claim nothing tests. Every point here is a place a real process can die: a network partition to
// Postgres, an OOM kill, a pod eviction.
type FaultPoint string

const (
	FaultBeforeJournalInsert FaultPoint = "before_journal_insert"
	FaultAfterJournalInsert  FaultPoint = "after_journal_insert"

	FaultBeforeDestroyVersions FaultPoint = "before_destroy_versions"
	FaultAfterDestroyVersions  FaultPoint = "after_destroy_versions"

	FaultBeforeKeysDestroyedTransition FaultPoint = "before_keys_destroyed_transition"
	FaultAfterKeysDestroyedTransition  FaultPoint = "after_keys_destroyed_transition"

	FaultBeforeCacheClear FaultPoint = "before_cache_clear"
	FaultAfterCacheClear  FaultPoint = "after_cache_clear"

	FaultBeforeCachesClearedTransition FaultPoint = "before_caches_cleared_transition"
	FaultAfterCachesClearedTransition  FaultPoint = "after_caches_cleared_transition"

	FaultBeforeReceiptPersist FaultPoint = "before_receipt_persist"
	FaultAfterReceiptPersist  FaultPoint = "after_receipt_persist"

	FaultBeforeCompletedTransition FaultPoint = "before_completed_transition"
	FaultAfterCompletedTransition  FaultPoint = "after_completed_transition"
)

// SagaBoundary pairs the two fault points that bracket one durable boundary crossing.
type SagaBoundary struct {
	Name   string
	Before FaultPoint
	After  FaultPoint
}

// SagaBoundaries enumerates every durable boundary the saga crosses, in execution order.
//
// The fault-injection suite iterates THIS slice rather than a hand-written list of cases, and
// asserts the number of cases it ran equals 2*len(SagaBoundaries). A hand-copied case list drifts
// from the code it covers, and the drift is invisible because both halves stay green — the suite
// still passes, it just stops covering the boundary somebody added.
var SagaBoundaries = []SagaBoundary{
	{"journal_insert", FaultBeforeJournalInsert, FaultAfterJournalInsert},
	{"destroy_versions", FaultBeforeDestroyVersions, FaultAfterDestroyVersions},
	{"keys_destroyed_transition", FaultBeforeKeysDestroyedTransition, FaultAfterKeysDestroyedTransition},
	{"cache_clear", FaultBeforeCacheClear, FaultAfterCacheClear},
	{"caches_cleared_transition", FaultBeforeCachesClearedTransition, FaultAfterCachesClearedTransition},
	{"receipt_persist", FaultBeforeReceiptPersist, FaultAfterReceiptPersist},
	{"completed_transition", FaultBeforeCompletedTransition, FaultAfterCompletedTransition},
}

// FaultInjector returns a non-nil error to simulate a crash at p. A nil injector means no faults.
type FaultInjector func(p FaultPoint) error

// ErrCacheNotEmpty is returned when a purge ran and the cache still reports entries for the subject.
//
// This is the difference between clearing a cache and believing you did. A Purge that matched zero
// entries — wrong composite key, wrong scoping, a typo — is indistinguishable from a Purge that
// correctly evicted everything, unless something re-reads.
var ErrCacheNotEmpty = errors.New("subjectkey: plaintext key cache still holds entries for the subject after purge; erasure would be cosmetic")

// ErrPseudonymiserRequired is returned when no pseudonymiser is configured.
var ErrPseudonymiserRequired = errors.New("subjectkey: subject pseudonymiser is required; the saga must never query or journal a cleartext subject identifier")

// ErrHierarchyRequired is returned when no hierarchy is configured.
var ErrHierarchyRequired = errors.New("subjectkey: key hierarchy is required")

// SagaConfig carries the saga's injectable dependencies. Every external boundary is here.
type SagaConfig struct {
	Hierarchy     *Hierarchy
	Store         KeyStore
	Cache         *PlaintextDEKCache
	Pseudonymiser privacy.SubjectPseudonymiser

	// StorageResidual describes what the configured store leaves behind. It is explicit rather than
	// inferred from the store's type because a caller wiring a Postgres store behind a decorator
	// would otherwise silently record the in-memory residual — a receipt understating its own
	// residue is exactly the kind of comfortable inaccuracy this package refuses.
	StorageResidual StorageResidual

	// Now overrides the clock, for tests and for deterministic replay.
	Now func() time.Time

	// Faults is nil in production.
	Faults FaultInjector
}

// Saga is the idempotent per-subject key erasure saga. It implements privacy.KeyDestroyer.
type Saga struct {
	hierarchy     *Hierarchy
	store         KeyStore
	cache         *PlaintextDEKCache
	pseudonymiser privacy.SubjectPseudonymiser
	residual      StorageResidual
	now           func() time.Time
	faults        FaultInjector
}

// Compile-time proof that the saga satisfies the gate's seam. Without this, a signature drift in
// privacy.KeyDestroyer would only surface at the single wiring line in main.go.
var _ privacy.KeyDestroyer = (*Saga)(nil)

// NewSaga constructs the saga.
//
// Every dependency is rejected when nil, and there is no permissive default. A nil store that read
// as "this subject has no keys" would report every erasure successful while destroying nothing —
// the same fail-open shape privacy.NewService refuses for its IncidentSource.
func NewSaga(cfg SagaConfig) (*Saga, error) {
	if cfg.Hierarchy == nil {
		return nil, ErrHierarchyRequired
	}
	if cfg.Store == nil {
		return nil, ErrStoreRequired
	}
	if cfg.Cache == nil {
		return nil, errors.New("subjectkey: plaintext key cache is required; a nil cache cannot be asserted empty")
	}
	if cfg.Pseudonymiser == nil {
		return nil, ErrPseudonymiserRequired
	}
	if cfg.StorageResidual == "" {
		return nil, errors.New("subjectkey: storage residual must be stated explicitly; an empty value would read as 'no residual'")
	}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	return &Saga{
		hierarchy:     cfg.Hierarchy,
		store:         cfg.Store,
		cache:         cfg.Cache,
		pseudonymiser: cfg.Pseudonymiser,
		residual:      cfg.StorageResidual,
		now:           now,
		faults:        cfg.Faults,
	}, nil
}

// clock returns the saga's current time, truncated to MICROSECOND resolution.
//
// Every timestamp the saga writes goes through here. PostgreSQL's timestamptz holds microseconds and
// rounds to nearest; Go holds nanoseconds and truncates toward zero. Writing a nanosecond value means
// the durable copy differs from the in-memory one, and the two rounding rules differ, so a resumed
// saga rebuilds a receipt whose digest disagrees with the one it persisted. Truncating at the source
// makes the write a no-op for the database and the round trip exactly identity.
func (s *Saga) clock() time.Time {
	return s.now().UTC().Truncate(time.Microsecond)
}

// fault fires the injector if one is configured.
func (s *Saga) fault(p FaultPoint) error {
	if s.faults == nil {
		return nil
	}
	if err := s.faults(p); err != nil {
		return fmt.Errorf("injected fault at %s: %w", p, err)
	}
	return nil
}

// opIDDomain is the domain label for operation-ID derivation.
const opIDDomain = "signalloom/identity/erasure-operation-id/v1"

// OperationID derives the deterministic identifier for erasing one subject.
//
// It is a keyed HMAC under a key derived from the master KEK, not a bare digest. A bare SHA-256 of
// (tenant, pseudonym) would be a re-identification oracle in exactly the way an unkeyed identifier
// hash always is: the pseudonym space is enumerable given the tenant key, so anyone holding a
// candidate could confirm it against a published operation ID.
//
// The REQUEST identifier is deliberately NOT an input, and this is the load-bearing choice. Two
// Article 17 requests naming the same subject are the same destruction. Including the request ID
// would start a second saga that destroys nothing (everything is already destroyed) and then emits a
// SECOND receipt and a second tombstone — one destruction, two tombstones, which is precisely the
// divergence this card exists to prevent. Idempotency has to be keyed on the subject, not the paperwork.
func (s *Saga) OperationID(tenantID, pseudonym string) (string, error) {
	if tenantID == "" {
		return "", ErrTenantRequired
	}
	if pseudonym == "" {
		return "", ErrSubjectRequired
	}
	kek, err := s.hierarchy.tenantKEK(tenantID, 0)
	if err != nil {
		return "", err
	}
	mac := hmac.New(sha256.New, kek)
	put := func(v string) {
		var l [4]byte
		binary.BigEndian.PutUint32(l[:], uint32(len(v)))
		mac.Write(l[:])
		mac.Write([]byte(v))
	}
	put(opIDDomain)
	put(tenantID)
	put(pseudonym)
	return hex.EncodeToString(mac.Sum(nil)), nil
}

// DestroySubjectKeys implements privacy.KeyDestroyer.
//
// subjectID arrives in CLEARTEXT space (privacy.ErasureRequest.SubjectID) and is pseudonymised
// before it reaches any query or any durable row, so neither the key store nor the saga journal ever
// holds a cleartext subject identifier.
func (s *Saga) DestroySubjectKeys(ctx context.Context, tenantID, subjectID string) (privacy.KeyDestructionReceipt, error) {
	receipt, err := s.Erase(ctx, tenantID, subjectID)
	if err != nil {
		return privacy.KeyDestructionReceipt{}, err
	}
	digest, err := receipt.Digest()
	if err != nil {
		return privacy.KeyDestructionReceipt{}, err
	}
	destroyed := 0
	for range receipt.Versions {
		destroyed++
	}
	return privacy.KeyDestructionReceipt{
		SubjectID:         subjectID,
		TenantID:          tenantID,
		KeysRemoved:       destroyed,
		DestroyedAt:       receipt.CompletedAt,
		OperationID:       receipt.OperationID,
		ReceiptDigest:     digest,
		ReceiptSchema:     receipt.Schema,
		ResidualPseudonym: string(receipt.ResidualPseudonym),
		StorageResidual:   string(receipt.StorageResidual),
		ComplianceNote:    receipt.ComplianceNote,
	}, nil
}

// Erase runs, or resumes, the erasure saga for one subject and returns the full receipt.
//
// # The invariant, stated exactly
//
// It is NOT "the journal and the key store are never divergent". Two durable systems with a
// non-atomic crossing will, under a crash between them, show keys destroyed with no receipt
// recorded. No amount of ordering removes that; claiming otherwise would be the comfortable
// half-truth. What IS guaranteed:
//
//  1. A receipt is never recorded while any targeted version remains live. Ordering gives this:
//     the digest is persisted only from StateCachesCleared, reachable only from StateKeysDestroyed,
//     reachable only after every targeted version was READ BACK destroyed.
//  2. Destruction without a recorded receipt is durably VISIBLE — the journal row names the
//     operation, its target versions and its state — and resuming completes it.
//  3. Resuming from any state converges on a byte-identical receipt digest, because every input to
//     the digest is read back from durable state and the nonce is persisted.
//
// So the pair (tombstone without destruction) is impossible, and (destruction without tombstone) is
// transient, nameable and recoverable. That is the strongest true statement available.
func (s *Saga) Erase(ctx context.Context, tenantID, subjectID string) (DestructionReceipt, error) {
	if tenantID == "" {
		return DestructionReceipt{}, ErrTenantRequired
	}
	if subjectID == "" {
		return DestructionReceipt{}, ErrSubjectRequired
	}
	if s.store == nil {
		return DestructionReceipt{}, ErrStoreRequired
	}

	pseudonym, err := s.pseudonymiser.Pseudonym(tenantID, subjectID)
	if err != nil {
		return DestructionReceipt{}, fmt.Errorf("subjectkey: pseudonymise subject: %w", err)
	}
	opID, err := s.OperationID(tenantID, pseudonym)
	if err != nil {
		return DestructionReceipt{}, err
	}

	// ---- Boundary 1: the journal row, written BEFORE anything is destroyed. -------------------
	if err := s.fault(FaultBeforeJournalInsert); err != nil {
		return DestructionReceipt{}, err
	}
	live, err := s.store.ListVersions(ctx, tenantID, pseudonym)
	if err != nil {
		return DestructionReceipt{}, fmt.Errorf("subjectkey: list key versions: %w", err)
	}
	nonce, err := NewReceiptNonce()
	if err != nil {
		return DestructionReceipt{}, err
	}
	saga, created, err := s.store.BeginSaga(ctx, SagaRecord{
		OperationID:      opID,
		TenantID:         tenantID,
		SubjectPseudonym: pseudonym,
		TargetVersions:   versionNumbers(live),
		Nonce:            nonce,
		StartedAt:        s.clock(),
	})
	if err != nil {
		return DestructionReceipt{}, fmt.Errorf("subjectkey: begin erasure saga: %w", err)
	}
	if !created {
		slog.Info("resuming existing erasure saga",
			"operation_id", opID, "tenant_id", tenantID, "state", string(saga.State))
	}
	if err := s.fault(FaultAfterJournalInsert); err != nil {
		return DestructionReceipt{}, err
	}

	// A version provisioned after the snapshot must not be silently missed.
	//
	// At StatePending nothing has been certified, so the honest response is to WIDEN the target set:
	// refusing here would leave the new key live forever, because the operation ID is deterministic
	// and a re-issued request resolves to this same stuck saga. After StateKeysDestroyed the saga has
	// already certified "every targeted version is destroyed", so a newly-appeared version means that
	// certification is now false and the only safe answer is to refuse loudly.
	current := versionNumbers(live)
	if drift := newVersions(saga.TargetVersions, current); len(drift) > 0 {
		if saga.State != StatePending {
			return DestructionReceipt{}, fmt.Errorf("%w: versions %v appeared after state %q", ErrVersionDrift, drift, saga.State)
		}
		saga.TargetVersions = current
	}

	// ---- Boundary 2: the irreversible act, per version, idempotent per version. ----------------
	results := make(map[int]DestroyResult, len(saga.TargetVersions))
	if saga.State == StatePending {
		if err := s.fault(FaultBeforeDestroyVersions); err != nil {
			return DestructionReceipt{}, err
		}
		for _, v := range saga.TargetVersions {
			scope := KeyScope{TenantID: tenantID, SubjectPseudonym: pseudonym, KeyVersion: v}
			rec, err := findVersion(live, v)
			if err != nil {
				return DestructionReceipt{}, err
			}
			scope.KeyEpoch = rec.KeyEpoch
			res, err := s.store.DestroyVersion(ctx, scope, s.clock())
			if err != nil {
				return DestructionReceipt{}, fmt.Errorf("subjectkey: destroy version %d: %w", v, err)
			}
			results[v] = res
		}
		if err := s.fault(FaultAfterDestroyVersions); err != nil {
			return DestructionReceipt{}, err
		}

		// ---- Boundary 3: certify, then advance. ------------------------------------------------
		// The read-back is the certification. Advancing on the strength of the destroy calls'
		// return values would make the state a record of what we asked for rather than what happened.
		if err := s.certifyAllDestroyed(ctx, tenantID, pseudonym, saga.TargetVersions); err != nil {
			return DestructionReceipt{}, err
		}
		if err := s.fault(FaultBeforeKeysDestroyedTransition); err != nil {
			return DestructionReceipt{}, err
		}
		targets := saga.TargetVersions
		saga, err = s.store.AdvanceSaga(ctx, opID, StatePending, func(r *SagaRecord) {
			r.TargetVersions = targets
		})
		if err != nil {
			return DestructionReceipt{}, fmt.Errorf("subjectkey: advance to %s: %w", StateKeysDestroyed, err)
		}
		if err := s.fault(FaultAfterKeysDestroyedTransition); err != nil {
			return DestructionReceipt{}, err
		}
	}

	// ---- Boundary 4: purge every cache the registry marks Cleared, then ASSERT emptiness. ------
	if saga.State == StateKeysDestroyed {
		if err := s.fault(FaultBeforeCacheClear); err != nil {
			return DestructionReceipt{}, err
		}
		s.cache.PurgeSubject(tenantID, pseudonym)
		// The assertion runs unconditionally, including when the purge removed nothing. Guarding it
		// behind `if removed > 0` would skip the check in exactly the case a broken purge produces.
		if remaining := s.cache.SubjectKeys(tenantID, pseudonym); len(remaining) > 0 {
			return DestructionReceipt{}, fmt.Errorf("%w: %d entries remain: %v", ErrCacheNotEmpty, len(remaining), remaining)
		}
		if err := s.fault(FaultAfterCacheClear); err != nil {
			return DestructionReceipt{}, err
		}

		// ---- Boundary 5: advance. ---------------------------------------------------------------
		if err := s.fault(FaultBeforeCachesClearedTransition); err != nil {
			return DestructionReceipt{}, err
		}
		saga, err = s.store.AdvanceSaga(ctx, opID, StateKeysDestroyed, nil)
		if err != nil {
			return DestructionReceipt{}, fmt.Errorf("subjectkey: advance to %s: %w", StateCachesCleared, err)
		}
		if err := s.fault(FaultAfterCachesClearedTransition); err != nil {
			return DestructionReceipt{}, err
		}
	}

	// ---- Boundary 6: build the receipt from durable state and persist its digest. ---------------
	if saga.State == StateCachesCleared {
		completedAt := s.clock()
		receipt, err := s.buildReceipt(ctx, saga, completedAt)
		if err != nil {
			return DestructionReceipt{}, err
		}
		digest, err := receipt.Digest()
		if err != nil {
			return DestructionReceipt{}, err
		}
		if err := s.fault(FaultBeforeReceiptPersist); err != nil {
			return DestructionReceipt{}, err
		}
		saga, err = s.store.AdvanceSaga(ctx, opID, StateCachesCleared, func(r *SagaRecord) {
			r.ReceiptDigest = digest
			// CompletedAt is persisted HERE, with the digest that covers it, so a resumed saga
			// rebuilds the same receipt. Stamping it at the `completed` transition instead would
			// make the resumed digest differ from the original with nothing reporting why.
			t := completedAt
			r.CompletedAt = &t
		})
		if err != nil {
			return DestructionReceipt{}, fmt.Errorf("subjectkey: advance to %s: %w", StateReceiptRecorded, err)
		}
		if err := s.fault(FaultAfterReceiptPersist); err != nil {
			return DestructionReceipt{}, err
		}
	}

	// ---- Boundary 7: terminal. ------------------------------------------------------------------
	if saga.State == StateReceiptRecorded {
		if err := s.fault(FaultBeforeCompletedTransition); err != nil {
			return DestructionReceipt{}, err
		}
		saga, err = s.store.AdvanceSaga(ctx, opID, StateReceiptRecorded, nil)
		if err != nil {
			return DestructionReceipt{}, fmt.Errorf("subjectkey: advance to %s: %w", StateCompleted, err)
		}
		if err := s.fault(FaultAfterCompletedTransition); err != nil {
			return DestructionReceipt{}, err
		}
	}

	if saga.State != StateCompleted {
		return DestructionReceipt{}, fmt.Errorf("subjectkey: saga %s ended in state %q, not %q", opID, saga.State, StateCompleted)
	}
	if saga.CompletedAt == nil {
		return DestructionReceipt{}, fmt.Errorf("subjectkey: saga %s is complete with no durable completed_at", opID)
	}

	// Rebuild from durable state on EVERY path, including the one that just wrote it. Returning the
	// in-memory receipt on the fresh path and the rebuilt one on the resume path would let the two
	// disagree without any test noticing, because no single run exercises both.
	receipt, err := s.buildReceipt(ctx, saga, *saga.CompletedAt)
	if err != nil {
		return DestructionReceipt{}, err
	}
	digest, err := receipt.Digest()
	if err != nil {
		return DestructionReceipt{}, err
	}
	if saga.ReceiptDigest != "" && digest != saga.ReceiptDigest {
		return DestructionReceipt{}, fmt.Errorf(
			"subjectkey: rebuilt receipt digest %s does not match the digest recorded at %s (%s); "+
				"SLDP-P4-2's tombstone would disagree with this receipt", digest, StateReceiptRecorded, saga.ReceiptDigest)
	}
	return receipt, nil
}

// certifyAllDestroyed re-reads every targeted version and refuses unless all are destroyed.
func (s *Saga) certifyAllDestroyed(ctx context.Context, tenantID, pseudonym string, targets []int) error {
	recs, err := s.store.ListVersions(ctx, tenantID, pseudonym)
	if err != nil {
		return fmt.Errorf("subjectkey: re-read key versions for certification: %w", err)
	}
	for _, v := range targets {
		rec, err := findVersion(recs, v)
		if err != nil {
			return err
		}
		if !rec.Destroyed() {
			return fmt.Errorf("subjectkey: version %d is still live after destruction was requested", v)
		}
		if rec.PriorWrappedDigest == "" {
			return fmt.Errorf("subjectkey: version %d is flagged destroyed with no prior wrapped digest; the receipt could not be reproduced on resume", v)
		}
	}
	return nil
}

// buildReceipt assembles the receipt from durable state alone.
func (s *Saga) buildReceipt(ctx context.Context, saga SagaRecord, completedAt time.Time) (DestructionReceipt, error) {
	recs, err := s.store.ListVersions(ctx, saga.TenantID, saga.SubjectPseudonym)
	if err != nil {
		return DestructionReceipt{}, fmt.Errorf("subjectkey: read key versions for receipt: %w", err)
	}
	versions := make([]DestroyedKeyVersion, 0, len(saga.TargetVersions))
	for _, v := range saga.TargetVersions {
		rec, err := findVersion(recs, v)
		if err != nil {
			return DestructionReceipt{}, err
		}
		if rec.DestroyedAt == nil {
			return DestructionReceipt{}, fmt.Errorf("subjectkey: version %d appears in a receipt without a destroyed_at", v)
		}
		versions = append(versions, DestroyedKeyVersion{
			KeyVersion:         rec.KeyVersion,
			KeyEpoch:           rec.KeyEpoch,
			PriorWrappedDigest: rec.PriorWrappedDigest,
			DestroyedAt:        *rec.DestroyedAt,
		})
	}
	return DestructionReceipt{
		Schema:            ReceiptSchema,
		OperationID:       saga.OperationID,
		TenantID:          saga.TenantID,
		SubjectPseudonym:  saga.SubjectPseudonym,
		Nonce:             saga.Nonce,
		Versions:          versions,
		CachesPurged:      ClearedCacheNames(),
		ResidualPseudonym: ResidualUnresolvableToken,
		StorageResidual:   s.residual,
		ComplianceNote:    ComplianceNote,
		CompletedAt:       completedAt,
	}, nil
}

// versionNumbers projects a record slice onto sorted version numbers.
func versionNumbers(recs []KeyRecord) []int {
	out := make([]int, 0, len(recs))
	for _, r := range recs {
		out = append(out, r.KeyVersion)
	}
	sort.Ints(out)
	return out
}

// newVersions returns members of current absent from snapshot.
func newVersions(snapshot, current []int) []int {
	have := make(map[int]struct{}, len(snapshot))
	for _, v := range snapshot {
		have[v] = struct{}{}
	}
	var out []int
	for _, v := range current {
		if _, ok := have[v]; !ok {
			out = append(out, v)
		}
	}
	return out
}

// findVersion locates one version in a record slice.
func findVersion(recs []KeyRecord, version int) (KeyRecord, error) {
	for _, r := range recs {
		if r.KeyVersion == version {
			return r, nil
		}
	}
	return KeyRecord{}, fmt.Errorf("%w: version %d", ErrKeyNotFound, version)
}
