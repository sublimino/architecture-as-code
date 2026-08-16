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

// QueryRange returns observations matching the query filters.
func (m *MemoryStore) QueryRange(_ context.Context, q Query) ([]model.Observation, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	layerSet := make(map[model.Layer]struct{}, len(q.Layers))
	for _, l := range q.Layers {
		layerSet[l] = struct{}{}
	}

	var results []model.Observation
	for _, o := range m.data {
		if !q.After.IsZero() && o.Timestamp.Before(q.After) {
			continue
		}
		if !q.Before.IsZero() && !o.Timestamp.Before(q.Before) {
			continue
		}
		if len(layerSet) > 0 {
			if _, ok := layerSet[o.Layer]; !ok {
				continue
			}
		}
		if q.ActorID != "" && o.ActorHint != q.ActorID {
			continue
		}
		results = append(results, o)
		if q.Limit > 0 && len(results) >= q.Limit {
			break
		}
	}
	return results, nil
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
