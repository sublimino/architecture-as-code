package identity

import (
	"context"
	"fmt"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// MemoryRepository provides a thread-safe, purely in-memory implementation of the Repository interface.
// It enforces the identical half-open interval semantics and structural never-merge invariants as PostgresRepository.
type MemoryRepository struct {
	mu          sync.RWMutex
	actors      map[string]ActorRecord
	aliases     []AliasRecord
	delegations []DelegationRecord
	encryptor   Encryptor
	aliasSeq    int64
	delegSeq    int64
}

// NewMemoryRepository constructs a MemoryRepository.
func NewMemoryRepository(encryptor ...Encryptor) *MemoryRepository {
	var enc Encryptor
	if len(encryptor) > 0 && encryptor[0] != nil {
		enc = encryptor[0]
	} else {
		enc = NewNoopEncryptor()
	}
	return &MemoryRepository{
		actors:      make(map[string]ActorRecord),
		aliases:     make([]AliasRecord, 0),
		delegations: make([]DelegationRecord, 0),
		encryptor:   enc,
	}
}

// CreateActor inserts or updates an actor record.
func (m *MemoryRepository) CreateActor(ctx context.Context, actor ActorRecord) error {
	if actor.ActorID == "" {
		return fmt.Errorf("actor_id cannot be empty")
	}
	if actor.Status == "" {
		actor.Status = model.ActorProvisional
	}
	now := time.Now().UTC()
	if actor.CreatedAt.IsZero() {
		actor.CreatedAt = now
	}
	if actor.UpdatedAt.IsZero() {
		actor.UpdatedAt = now
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	m.actors[actor.ActorID] = actor
	return nil
}

// GetActor retrieves an actor by ID.
func (m *MemoryRepository) GetActor(ctx context.Context, actorID string) (*ActorRecord, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	act, ok := m.actors[actorID]
	if !ok {
		return nil, ErrActorNotFound
	}
	return &act, nil
}

// GetActorAsOf retrieves an actor valid as of the given timestamp.
func (m *MemoryRepository) GetActorAsOf(ctx context.Context, actorID string, asOf time.Time) (*ActorRecord, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	act, ok := m.actors[actorID]
	if !ok || asOf.Before(act.CreatedAt) {
		return nil, ErrActorNotFound
	}
	return &act, nil
}

// AddAlias records a typed time-valid alias, enforcing structural never-merge invariants against existing delegations.
func (m *MemoryRepository) AddAlias(ctx context.Context, alias AliasRecord) error {
	if alias.ActorID == "" || alias.AliasValue == "" || alias.AliasType == "" {
		return fmt.Errorf("actor_id, alias_type, and alias_value are required")
	}
	if alias.EdgeFidelity == "" {
		alias.EdgeFidelity = model.FidelitySuggestive
	}
	if alias.ValidFrom.IsZero() {
		alias.ValidFrom = time.Now().UTC()
	}
	if alias.CreatedAt.IsZero() {
		alias.CreatedAt = time.Now().UTC()
	}
	if alias.ValidTo != nil && !alias.ValidFrom.Before(*alias.ValidTo) {
		return fmt.Errorf("valid_from must be strictly before valid_to")
	}
	alias.AliasValueHash = m.encryptor.Hash(alias.AliasValue)
	alias.ID = atomic.AddInt64(&m.aliasSeq, 1)

	m.mu.Lock()
	defer m.mu.Unlock()

	// Idempotent check: if identical alias exists at valid_from, do not duplicate
	for _, a := range m.aliases {
		if a.ActorID == alias.ActorID && a.AliasType == alias.AliasType && a.AliasValue == alias.AliasValue && a.ValidFrom.Equal(alias.ValidFrom) {
			return nil
		}
	}

	// Structural Never-Merge Check: Reject if alias equates actor with any of its delegation partners
	for _, d := range m.delegations {
		if d.DelegateActorID == alias.ActorID && d.PrincipalActorID == alias.AliasValue {
			return fmt.Errorf("%w: cannot alias delegate %s to delegation principal %s",
				ErrNeverMergeViolation, alias.ActorID, alias.AliasValue)
		}
		if d.PrincipalActorID == alias.ActorID && d.DelegateActorID == alias.AliasValue {
			return fmt.Errorf("%w: cannot alias principal %s to delegate %s",
				ErrNeverMergeViolation, alias.ActorID, alias.AliasValue)
		}
	}

	m.aliases = append(m.aliases, alias)
	return nil
}

// FindAliasesAsOf returns aliases matching aliasValue active at asOf.
func (m *MemoryRepository) FindAliasesAsOf(ctx context.Context, aliasValue string, asOf time.Time) ([]AliasRecord, error) {
	hash := m.encryptor.Hash(aliasValue)

	m.mu.RLock()
	defer m.mu.RUnlock()

	var result []AliasRecord
	for _, a := range m.aliases {
		if (a.AliasValue == aliasValue || a.AliasValueHash == hash) && a.IsActiveAt(asOf) {
			result = append(result, a)
		}
	}

	// Sort by valid_from descending
	sort.Slice(result, func(i, j int) bool {
		return result[i].ValidFrom.After(result[j].ValidFrom)
	})
	return result, nil
}

// GetAliasesForActorAsOf returns all aliases active for an actor at asOf.
func (m *MemoryRepository) GetAliasesForActorAsOf(ctx context.Context, actorID string, asOf time.Time) ([]AliasRecord, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var result []AliasRecord
	for _, a := range m.aliases {
		if a.ActorID == actorID && a.IsActiveAt(asOf) {
			result = append(result, a)
		}
	}

	sort.Slice(result, func(i, j int) bool {
		return result[i].ValidFrom.Before(result[j].ValidFrom)
	})
	return result, nil
}

// AddDelegation persists an acts-on-behalf-of delegation, enforcing structural never-merge invariants.
func (m *MemoryRepository) AddDelegation(ctx context.Context, delegation DelegationRecord) error {
	if delegation.DelegateActorID == "" || delegation.PrincipalActorID == "" {
		return fmt.Errorf("delegate_actor_id and principal_actor_id are required")
	}
	if delegation.DelegateActorID == delegation.PrincipalActorID {
		return fmt.Errorf("%w: self-delegation %s is forbidden", ErrNeverMergeViolation, delegation.DelegateActorID)
	}
	if delegation.ValidFrom.IsZero() {
		delegation.ValidFrom = time.Now().UTC()
	}
	if delegation.CreatedAt.IsZero() {
		delegation.CreatedAt = time.Now().UTC()
	}
	if delegation.ValidTo != nil && !delegation.ValidFrom.Before(*delegation.ValidTo) {
		return fmt.Errorf("valid_from must be strictly before valid_to")
	}
	delegation.ID = atomic.AddInt64(&m.delegSeq, 1)

	m.mu.Lock()
	defer m.mu.Unlock()

	// Idempotent check: if identical delegation exists at valid_from, do not duplicate
	for _, d := range m.delegations {
		if d.DelegateActorID == delegation.DelegateActorID && d.PrincipalActorID == delegation.PrincipalActorID && d.ValidFrom.Equal(delegation.ValidFrom) {
			return nil
		}
	}

	// Structural Never-Merge Check: Reject if there is already an alias equating delegate and principal
	for _, a := range m.aliases {
		if (a.ActorID == delegation.DelegateActorID && a.AliasValue == delegation.PrincipalActorID) ||
			(a.ActorID == delegation.PrincipalActorID && a.AliasValue == delegation.DelegateActorID) {
			return fmt.Errorf("%w: cannot delegate between aliased identities %s and %s",
				ErrNeverMergeViolation, delegation.DelegateActorID, delegation.PrincipalActorID)
		}
	}

	m.delegations = append(m.delegations, delegation)
	return nil
}

// ClampDelegation terminates any active delegation matching delegateOrAuthzRef by clamping valid_to = clampTime.
func (m *MemoryRepository) ClampDelegation(ctx context.Context, delegateOrAuthzRef string, clampTime time.Time) error {
	if clampTime.IsZero() {
		clampTime = time.Now().UTC()
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	for i := range m.delegations {
		d := &m.delegations[i]
		if d.AuthzRef == delegateOrAuthzRef || d.DelegateActorID == delegateOrAuthzRef {
			if d.ValidTo == nil || d.ValidTo.After(clampTime) {
				t := clampTime
				d.ValidTo = &t
			}
		}
	}
	return nil
}

// RevokeActiveDelegations terminates all active delegation edges originating from or terminating at
// actorID as well as transitive descendant delegations, setting valid_to to clampTime.
// It also updates the actor status to 'revoked' in memory.
func (m *MemoryRepository) RevokeActiveDelegations(ctx context.Context, actorID string, timestamp time.Time) error {
	if timestamp.IsZero() {
		timestamp = time.Now().UTC()
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	affectedDelegates := make(map[string]bool)
	affectedDelegates[actorID] = true

	changed := true
	for changed {
		changed = false
		for _, d := range m.delegations {
			if affectedDelegates[d.PrincipalActorID] && !affectedDelegates[d.DelegateActorID] {
				affectedDelegates[d.DelegateActorID] = true
				changed = true
			}
		}
	}

	for i := range m.delegations {
		d := &m.delegations[i]
		if (affectedDelegates[d.DelegateActorID] || affectedDelegates[d.PrincipalActorID]) && d.IsActiveAt(timestamp) {
			clamp := timestamp
			if !clamp.After(d.ValidFrom) {
				clamp = d.ValidFrom.Add(time.Microsecond)
			}
			d.ValidTo = &clamp
			d.Status = "revoked"
			if d.Metadata == nil {
				d.Metadata = make(map[string]any)
			}
			d.Metadata["status"] = "revoked"
		}
	}

	if act, ok := m.actors[actorID]; ok {
		act.Status = "revoked"
		act.UpdatedAt = timestamp
		m.actors[actorID] = act
	}

	return nil
}

// SweepExpiredDelegations marks past time-bounded delegations as expired.
func (m *MemoryRepository) SweepExpiredDelegations(ctx context.Context, now time.Time) (int64, error) {
	if now.IsZero() {
		now = time.Now().UTC()
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	var count int64
	for i := range m.delegations {
		d := &m.delegations[i]
		if d.ValidTo != nil && (d.ValidTo.Before(now) || d.ValidTo.Equal(now)) && (d.Status == "" || d.Status == "active") {
			d.Status = "expired"
			if d.Metadata == nil {
				d.Metadata = make(map[string]any)
			}
			d.Metadata["status"] = "expired"
			count++
		}
	}
	return count, nil
}

// GetDelegationsForDelegateAsOf returns active delegations where actor is the delegate at asOf.
func (m *MemoryRepository) GetDelegationsForDelegateAsOf(ctx context.Context, delegateID string, asOf time.Time) ([]DelegationRecord, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var result []DelegationRecord
	for _, d := range m.delegations {
		if d.DelegateActorID == delegateID && d.IsActiveAt(asOf) {
			result = append(result, d)
		}
	}

	sort.Slice(result, func(i, j int) bool {
		return result[i].ValidFrom.Before(result[j].ValidFrom)
	})
	return result, nil
}

// GetDelegationsForPrincipalAsOf returns active delegations where actor is the principal at asOf.
func (m *MemoryRepository) GetDelegationsForPrincipalAsOf(ctx context.Context, principalID string, asOf time.Time) ([]DelegationRecord, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var result []DelegationRecord
	for _, d := range m.delegations {
		if d.PrincipalActorID == principalID && d.IsActiveAt(asOf) {
			result = append(result, d)
		}
	}

	sort.Slice(result, func(i, j int) bool {
		return result[i].ValidFrom.Before(result[j].ValidFrom)
	})
	return result, nil
}

// GetActiveGraphForActorAsOf returns a full graph snapshot of the actor at asOf.
func (m *MemoryRepository) GetActiveGraphForActorAsOf(ctx context.Context, actorID string, asOf time.Time) (*ActorGraphSnapshot, error) {
	actor, err := m.GetActorAsOf(ctx, actorID, asOf)
	if err != nil {
		return nil, err
	}

	aliases, err := m.GetAliasesForActorAsOf(ctx, actorID, asOf)
	if err != nil {
		return nil, err
	}

	delegationsAsDelegate, err := m.GetDelegationsForDelegateAsOf(ctx, actorID, asOf)
	if err != nil {
		return nil, err
	}

	delegationsAsPrincipal, err := m.GetDelegationsForPrincipalAsOf(ctx, actorID, asOf)
	if err != nil {
		return nil, err
	}

	return &ActorGraphSnapshot{
		Actor:                  *actor,
		Aliases:                aliases,
		DelegationsAsDelegate:  delegationsAsDelegate,
		DelegationsAsPrincipal: delegationsAsPrincipal,
		AsOf:                   asOf,
	}, nil
}

// FindTransitiveDelegations resolves arbitrary-depth delegation chains in memory,
// enforcing strict cycle detection and max-depth clamping.
func (m *MemoryRepository) FindTransitiveDelegations(ctx context.Context, delegateID string, asOf time.Time, maxDepth int) ([]DelegationRecord, bool, error) {
	if maxDepth <= 0 || maxDepth > 8 {
		maxDepth = 8
	}

	m.mu.RLock()
	defer m.mu.RUnlock()

	var (
		path          []DelegationRecord
		visited       = make(map[string]bool)
		currentID     = delegateID
		cycleDetected = false
	)
	visited[currentID] = true

	for depth := 1; depth <= maxDepth; depth++ {
		var nextDel *DelegationRecord
		for _, d := range m.delegations {
			if d.DelegateActorID == currentID && d.IsActiveAt(asOf) {
				cp := d
				nextDel = &cp
				break
			}
		}
		if nextDel == nil {
			break
		}

		if visited[nextDel.PrincipalActorID] {
			cycleDetected = true
			path = append(path, *nextDel)
			break
		}

		path = append(path, *nextDel)
		visited[nextDel.PrincipalActorID] = true
		currentID = nextDel.PrincipalActorID
	}

	return path, cycleDetected, nil
}

