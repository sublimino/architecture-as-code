package store

import (
	"context"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// MemoryStore is a simple in-memory SignalStore for tests and development.
type MemoryStore struct {
	mu   sync.RWMutex
	data []model.Observation
}

// NewMemoryStore returns an empty in-memory store.
func NewMemoryStore() *MemoryStore {
	return &MemoryStore{}
}

// Append adds observations to the in-memory store.
func (m *MemoryStore) Append(_ context.Context, observations []model.Observation) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.data = append(m.data, observations...)
	return nil
}

// matchesFilters reports whether o satisfies q's row predicates. Offset and Limit are
// positional and are applied by the caller, not here.
//
// Shared by QueryRange and ScanIDs so the two cannot drift: a row that one returns and the
// other skips would make a warmed ID set disagree with the rows it was warmed from.
func matchesFilters(o *model.Observation, q Query, layerSet map[model.Layer]struct{}) bool {
	// Kept here, not in QueryRange: ScanIDs shares this predicate, and the by-ID
	// bound must apply to both reads or they drift apart.
	if !q.matchesIDs(o.ID) {
		return false
	}
	if !q.After.IsZero() && o.Timestamp.Before(q.After) {
		return false
	}
	if !q.Before.IsZero() && !o.Timestamp.Before(q.Before) {
		return false
	}
	if len(layerSet) > 0 {
		if _, ok := layerSet[o.Layer]; !ok {
			return false
		}
	}
	if q.ActorID != "" && o.ActorHint != q.ActorID {
		return false
	}
	if q.SubjectID != "" {
		matchSubject := (o.ActorHint == q.SubjectID) ||
			(o.Labels != nil && (o.Labels["actor_id"] == q.SubjectID ||
				o.Labels["principal_id"] == q.SubjectID ||
				o.Labels["impersonated_user"] == q.SubjectID ||
				o.Labels["user"] == q.SubjectID))
		if !matchSubject {
			return false
		}
	}
	return true
}

// layerSetOf indexes q.Layers for membership tests.
func layerSetOf(q Query) map[model.Layer]struct{} {
	set := make(map[model.Layer]struct{}, len(q.Layers))
	for _, l := range q.Layers {
		set[l] = struct{}{}
	}
	return set
}

// QueryRange returns observations matching the query filters.
func (m *MemoryStore) QueryRange(_ context.Context, q Query) ([]model.Observation, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	layerSet := layerSetOf(q)

	var matched []model.Observation
	for i := range m.data {
		if !matchesFilters(&m.data[i], q, layerSet) {
			continue
		}
		matched = append(matched, m.data[i])
	}

	if q.Offset > 0 {
		if q.Offset >= len(matched) {
			return nil, nil
		}
		matched = matched[q.Offset:]
	}

	if q.Limit > 0 && len(matched) > q.Limit {
		matched = matched[:q.Limit]
	}

	return matched, nil
}

// ScanIDs streams matching observation IDs without copying rows.
//
// The strings are already independently allocated Go strings owned by m.data, not views into
// a decode buffer, so they satisfy the interface's ownership requirement as they stand.
func (m *MemoryStore) ScanIDs(_ context.Context, q Query, fn func(id string) error) error {
	m.mu.RLock()
	defer m.mu.RUnlock()

	layerSet := layerSetOf(q)

	emitted, skipped := 0, 0
	for i := range m.data {
		if !matchesFilters(&m.data[i], q, layerSet) {
			continue
		}
		if skipped < q.Offset {
			skipped++
			continue
		}
		if err := fn(m.data[i].ID); err != nil {
			return err
		}
		emitted++
		if q.Limit > 0 && emitted >= q.Limit {
			return nil
		}
	}
	return nil
}

// DropPartition removes all observations before the given time.
func (m *MemoryStore) DropPartition(_ context.Context, before time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	kept := m.data[:0]
	for _, o := range m.data {
		if !o.Timestamp.Before(before) {
			kept = append(kept, o)
		}
	}
	m.data = kept
	return nil
}

// Close is a no-op for the in-memory store.
func (m *MemoryStore) Close() error {
	return nil
}
