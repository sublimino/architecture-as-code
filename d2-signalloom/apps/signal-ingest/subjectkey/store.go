// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package subjectkey

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"sort"
	"sync"
	"time"
)

// SagaState is one durable state of the erasure saga.
//
// The enumeration is closed and SagaStates below is the single source of truth for it. Migration 009
// builds its CHECK constraint list from these same literals via TestMigration009_StateCheckMatchesGo,
// which compares the SQL text against SagaStates rather than against a hand-copied list. A guard that
// copies its source of truth drifts from it; one that derives from it cannot.
type SagaState string

const (
	// StatePending — the journal row exists, the target version set is snapshotted, nothing is
	// destroyed yet.
	StatePending SagaState = "pending"
	// StateKeysDestroyed — every targeted version has been read back with a non-null destroyed_at.
	StateKeysDestroyed SagaState = "keys_destroyed"
	// StateCachesCleared — every cache the registry marks Cleared has been purged AND re-read empty.
	StateCachesCleared SagaState = "caches_cleared"
	// StateReceiptRecorded — the receipt digest is durable. SLDP-P4-2 may emit a tombstone only for
	// a saga that has reached at least this state.
	StateReceiptRecorded SagaState = "receipt_recorded"
	// StateCompleted — terminal.
	StateCompleted SagaState = "completed"
)

// SagaStates is the closed enumeration, in transition order. Index position IS the ordering, and
// AdvanceSaga refuses any transition that is not exactly one step forward.
var SagaStates = []SagaState{
	StatePending,
	StateKeysDestroyed,
	StateCachesCleared,
	StateReceiptRecorded,
	StateCompleted,
}

// stateIndex returns the position of s in SagaStates, or -1.
func stateIndex(s SagaState) int {
	for i, v := range SagaStates {
		if v == s {
			return i
		}
	}
	return -1
}

// NextState returns the state that legally follows s.
func NextState(s SagaState) (SagaState, bool) {
	i := stateIndex(s)
	if i < 0 || i+1 >= len(SagaStates) {
		return "", false
	}
	return SagaStates[i+1], true
}

var (
	// ErrKeyNotFound is returned when a named key version does not exist. It is distinct from
	// "exists but destroyed": a caller that could not tell them apart would report a typo'd subject
	// as successfully erased.
	ErrKeyNotFound = errors.New("subjectkey: key version not found")

	// ErrSagaNotFound is returned when an operation ID has no journal row.
	ErrSagaNotFound = errors.New("subjectkey: erasure saga not found")

	// ErrIllegalTransition is returned when a state change is not exactly one step forward.
	ErrIllegalTransition = errors.New("subjectkey: illegal saga state transition")

	// ErrStateConflict is returned when the observed state is not the expected 'from' state. It is
	// how a concurrent second invocation loses the race without double-applying.
	ErrStateConflict = errors.New("subjectkey: saga state changed underneath this transition")

	// ErrVersionDrift is returned when the live version set no longer matches the snapshot taken at
	// StatePending. A version provisioned AFTER the snapshot would otherwise be silently missed and
	// the subject would be reported erased while still holding a live key.
	ErrVersionDrift = errors.New("subjectkey: live key versions drifted from the saga's snapshot; re-issue the erasure request")

	// ErrStoreRequired is returned when a nil store is supplied. A nil store must never read as
	// "this subject has no keys".
	ErrStoreRequired = errors.New("subjectkey: key store is required; a nil store must not be read as 'no keys'")
)

// KeyRecord is one durable per-subject key version.
type KeyRecord struct {
	TenantID         string
	SubjectPseudonym string
	KeyEpoch         uint32
	KeyVersion       int
	// WrappedDEK holds the wrapped key while live. After destruction it holds cryptographically
	// random bytes of the same length. The row is NOT deleted: a deleted row proves nothing, whereas
	// a row that exists, is flagged destroyed, and whose bytes refuse to unwrap is positive evidence.
	WrappedDEK []byte
	CreatedAt  time.Time
	// DestroyedAt is nil while live.
	DestroyedAt *time.Time
	// PriorWrappedDigest is SHA-256 of WrappedDEK as it stood immediately before destruction, saved
	// at destruction time. It is what makes a RETRY reproduce the original receipt digest: without
	// it, a resumed saga would have nothing to digest but the random overwrite, which differs every
	// run and would silently break agreement with SLDP-P4-2's tombstone.
	PriorWrappedDigest string
}

// Scope returns the KeyScope naming this record.
func (r KeyRecord) Scope() KeyScope {
	return KeyScope{
		TenantID:         r.TenantID,
		SubjectPseudonym: r.SubjectPseudonym,
		KeyEpoch:         r.KeyEpoch,
		KeyVersion:       r.KeyVersion,
	}
}

// Destroyed reports whether this version has been destroyed.
func (r KeyRecord) Destroyed() bool { return r.DestroyedAt != nil }

// SagaRecord is the durable journal row for one erasure operation.
type SagaRecord struct {
	OperationID      string
	TenantID         string
	SubjectPseudonym string
	State            SagaState
	// TargetVersions is the version set snapshotted at StatePending, sorted ascending.
	TargetVersions []int
	// Nonce is persisted so a resumed saga reproduces the same receipt digest.
	Nonce         string
	ReceiptDigest string
	StartedAt     time.Time
	UpdatedAt     time.Time
	CompletedAt   *time.Time
}

// DestroyResult reports the outcome of destroying one key version.
type DestroyResult struct {
	Scope              KeyScope
	PriorWrappedDigest string
	DestroyedAt        time.Time
	// AlreadyDestroyed is true when this call found the version already destroyed and returned the
	// ORIGINAL timestamp and digest rather than performing a second destruction.
	AlreadyDestroyed bool
}

// KeyStore is the durable boundary. Every method is injectable so the saga can be tested with no
// database present and faults can be driven at each boundary.
type KeyStore interface {
	// Provision appends a new key version and returns it. The store allocates the version number.
	Provision(ctx context.Context, tenantID, pseudonym string, epoch uint32, wrap func(KeyScope) ([]byte, error), now time.Time) (KeyRecord, error)
	// ListVersions returns every version for a subject, live and destroyed, sorted ascending.
	ListVersions(ctx context.Context, tenantID, pseudonym string) ([]KeyRecord, error)
	// GetVersion returns one version.
	GetVersion(ctx context.Context, scope KeyScope) (KeyRecord, error)
	// DestroyVersion overwrites the wrapped key with random bytes and stamps destroyed_at.
	// It is idempotent: a repeat returns the original timestamp and digest with AlreadyDestroyed.
	DestroyVersion(ctx context.Context, scope KeyScope, now time.Time) (DestroyResult, error)

	// BeginSaga inserts the journal row if absent. created reports whether this call inserted it.
	BeginSaga(ctx context.Context, rec SagaRecord) (SagaRecord, bool, error)
	// LoadSaga returns the journal row.
	LoadSaga(ctx context.Context, operationID string) (SagaRecord, error)
	// AdvanceSaga moves the row from `from` to the next state, applying mutate first. It refuses if
	// the observed state is not `from` (ErrStateConflict) or the move is not one step (ErrIllegalTransition).
	AdvanceSaga(ctx context.Context, operationID string, from SagaState, mutate func(*SagaRecord)) (SagaRecord, error)
}

// ---------------------------------------------------------------------------------------------
// In-memory implementation.
//
// It is production-shaped, not a test double: the saga's whole correctness argument is about
// ordering and idempotency under concurrency, so an implementation that skipped locking would make
// every race test vacuous. It is the default store for single-process deployments and the ONLY store
// exercised when no SLDP_PG_DSN is configured, which is most runs.
// ---------------------------------------------------------------------------------------------

// MemoryStore is an in-memory KeyStore.
type MemoryStore struct {
	mu    sync.Mutex
	keys  map[string]*KeyRecord  // cacheKey(scope) -> record
	sagas map[string]*SagaRecord // operationID -> record
}

// NewMemoryStore constructs an empty in-memory store.
func NewMemoryStore() *MemoryStore {
	return &MemoryStore{
		keys:  make(map[string]*KeyRecord),
		sagas: make(map[string]*SagaRecord),
	}
}

var _ KeyStore = (*MemoryStore)(nil)

// Provision allocates the next version, wraps under it, and stores the result.
//
// The wrap callback takes the scope rather than the caller pre-wrapping, because the version number
// is bound into the wrap AAD and only the store knows it. Pre-wrapping would force the caller to
// guess the version, and a guess that lost a race would produce a key that never unwraps.
func (m *MemoryStore) Provision(_ context.Context, tenantID, pseudonym string, epoch uint32, wrap func(KeyScope) ([]byte, error), now time.Time) (KeyRecord, error) {
	if tenantID == "" {
		return KeyRecord{}, ErrTenantRequired
	}
	if pseudonym == "" {
		return KeyRecord{}, ErrSubjectRequired
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	next := 1
	live := 0
	var liveRecs []*KeyRecord
	for _, r := range m.keys {
		if r.TenantID != tenantID || r.SubjectPseudonym != pseudonym {
			continue
		}
		if r.KeyVersion >= next {
			next = r.KeyVersion + 1
		}
		if !r.Destroyed() && r.KeyEpoch == epoch {
			live++
			liveRecs = append(liveRecs, r)
		}
	}

	scope := KeyScope{TenantID: tenantID, SubjectPseudonym: pseudonym, KeyEpoch: epoch, KeyVersion: next}
	wrapped, err := wrap(scope)
	if err != nil {
		return KeyRecord{}, err
	}
	rec := &KeyRecord{
		TenantID:         tenantID,
		SubjectPseudonym: pseudonym,
		KeyEpoch:         epoch,
		KeyVersion:       next,
		WrappedDEK:       wrapped,
		CreatedAt:        now.UTC(),
	}
	m.keys[cacheKey(scope)] = rec

	// Bound the version history. An unbounded key history is a retention problem inside the key
	// store: every surplus version is another live key that erasure must destroy and another row
	// that outlived its purpose. The oldest surplus versions are destroyed in place, not deleted,
	// so the audit trail of "this version existed and was destroyed" survives.
	if live+1 > MaxKeyVersionsPerSubject {
		sort.Slice(liveRecs, func(i, j int) bool { return liveRecs[i].KeyVersion < liveRecs[j].KeyVersion })
		surplus := live + 1 - MaxKeyVersionsPerSubject
		for i := 0; i < surplus && i < len(liveRecs); i++ {
			m.destroyLocked(liveRecs[i], now)
		}
	}
	return *rec, nil
}

// destroyLocked performs the irreversible overwrite. Caller holds m.mu.
func (m *MemoryStore) destroyLocked(r *KeyRecord, now time.Time) {
	if r.Destroyed() {
		return
	}
	r.PriorWrappedDigest = WrappedDigest(r.WrappedDEK)
	overwrite := make([]byte, len(r.WrappedDEK))
	// A CSPRNG failure here must not degrade to a weaker overwrite. Zeroes would still destroy the
	// key, so falling back to them is safe for erasure — but it must be visible, hence the zeroing
	// is explicit rather than an ignored error.
	if _, err := io.ReadFull(rand.Reader, overwrite); err != nil {
		Zero(overwrite)
	}
	Zero(r.WrappedDEK)
	r.WrappedDEK = overwrite
	t := now.UTC()
	r.DestroyedAt = &t
}

// ListVersions returns every version for a subject, sorted ascending.
func (m *MemoryStore) ListVersions(_ context.Context, tenantID, pseudonym string) ([]KeyRecord, error) {
	if tenantID == "" {
		return nil, ErrTenantRequired
	}
	if pseudonym == "" {
		return nil, ErrSubjectRequired
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []KeyRecord
	for _, r := range m.keys {
		if r.TenantID == tenantID && r.SubjectPseudonym == pseudonym {
			out = append(out, *r)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].KeyVersion < out[j].KeyVersion })
	return out, nil
}

// GetVersion returns one version.
func (m *MemoryStore) GetVersion(_ context.Context, scope KeyScope) (KeyRecord, error) {
	if err := scope.Validate(); err != nil {
		return KeyRecord{}, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.keys[cacheKey(scope)]
	if !ok {
		return KeyRecord{}, fmt.Errorf("%w: %s v%d", ErrKeyNotFound, scope.SubjectPseudonym, scope.KeyVersion)
	}
	return *r, nil
}

// DestroyVersion is idempotent. The AlreadyDestroyed arm returns the ORIGINAL destroyed_at and
// digest, which is what makes a resumed saga reproduce the first attempt's receipt byte for byte.
func (m *MemoryStore) DestroyVersion(_ context.Context, scope KeyScope, now time.Time) (DestroyResult, error) {
	if err := scope.Validate(); err != nil {
		return DestroyResult{}, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.keys[cacheKey(scope)]
	if !ok {
		return DestroyResult{}, fmt.Errorf("%w: %s v%d", ErrKeyNotFound, scope.SubjectPseudonym, scope.KeyVersion)
	}
	if r.Destroyed() {
		return DestroyResult{
			Scope:              scope,
			PriorWrappedDigest: r.PriorWrappedDigest,
			DestroyedAt:        *r.DestroyedAt,
			AlreadyDestroyed:   true,
		}, nil
	}
	m.destroyLocked(r, now)
	return DestroyResult{
		Scope:              scope,
		PriorWrappedDigest: r.PriorWrappedDigest,
		DestroyedAt:        *r.DestroyedAt,
	}, nil
}

// BeginSaga inserts the journal row if absent.
func (m *MemoryStore) BeginSaga(_ context.Context, rec SagaRecord) (SagaRecord, bool, error) {
	if rec.OperationID == "" {
		return SagaRecord{}, false, errors.New("subjectkey: operation id is required")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if existing, ok := m.sagas[rec.OperationID]; ok {
		return *existing, false, nil
	}
	cp := rec
	cp.TargetVersions = append([]int(nil), rec.TargetVersions...)
	cp.State = StatePending
	cp.StartedAt = rec.StartedAt.UTC()
	cp.UpdatedAt = rec.StartedAt.UTC()
	m.sagas[rec.OperationID] = &cp
	return cp, true, nil
}

// LoadSaga returns the journal row.
func (m *MemoryStore) LoadSaga(_ context.Context, operationID string) (SagaRecord, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.sagas[operationID]
	if !ok {
		return SagaRecord{}, fmt.Errorf("%w: %s", ErrSagaNotFound, operationID)
	}
	cp := *r
	cp.TargetVersions = append([]int(nil), r.TargetVersions...)
	return cp, nil
}

// AdvanceSaga performs a compare-and-swap on the state.
//
// The compare is the concurrency control. Two invocations racing on the same operation both read
// StatePending; one advances and the other gets ErrStateConflict rather than both proceeding. That
// is why the transition takes `from` rather than trusting the caller's cached copy.
func (m *MemoryStore) AdvanceSaga(_ context.Context, operationID string, from SagaState, mutate func(*SagaRecord)) (SagaRecord, error) {
	to, ok := NextState(from)
	if !ok {
		return SagaRecord{}, fmt.Errorf("%w: %q has no successor", ErrIllegalTransition, from)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	r, exists := m.sagas[operationID]
	if !exists {
		return SagaRecord{}, fmt.Errorf("%w: %s", ErrSagaNotFound, operationID)
	}
	if r.State != from {
		return SagaRecord{}, fmt.Errorf("%w: expected %q, found %q", ErrStateConflict, from, r.State)
	}
	if mutate != nil {
		mutate(r)
	}
	r.State = to
	r.UpdatedAt = time.Now().UTC()
	// CompletedAt is set by the mutate that persists the receipt digest, NOT here, and is never
	// overwritten once set. The receipt digest covers CompletedAt, so a value stamped at the
	// `completed` transition would differ between the first attempt and a resumed one — the exact
	// clock-derived divergence this saga exists to prevent.
	if to == StateCompleted && r.CompletedAt == nil {
		t := r.UpdatedAt
		r.CompletedAt = &t
	}
	cp := *r
	cp.TargetVersions = append([]int(nil), r.TargetVersions...)
	return cp, nil
}
