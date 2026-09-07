package correlation

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// ResolverStore is the persistence seam owned by correlation. P3-2 may provide
// a durable implementation without changing the resolver algorithm.
type ResolverStore interface {
	ReplaceObservations(context.Context, []model.Observation) error
	UpsertObservation(context.Context, model.Observation) error
	RetractObservation(context.Context, string) error
	Observations(context.Context) ([]model.Observation, error)
	Candidates(context.Context, model.Observation, time.Duration, int) ([]model.Observation, error)
	RetractEdge(context.Context, string) error
	EdgeRetracted(context.Context, string) (bool, error)
	Publish(context.Context, model.ResolverSnapshot) error
	Snapshot(context.Context) (model.ResolverSnapshot, error)
}

// MemoryResolverStore is a race-safe in-memory ResolverStore.
type MemoryResolverStore struct {
	mu           sync.RWMutex
	observations map[string]model.Observation
	snapshot     model.ResolverSnapshot
	retracted    map[string]struct{}
	tombstones   map[string]struct{}
}

func NewMemoryResolverStore() *MemoryResolverStore {
	return &MemoryResolverStore{observations: make(map[string]model.Observation), retracted: make(map[string]struct{}), tombstones: make(map[string]struct{})}
}

func cloneObservation(o model.Observation) model.Observation {
	c := o
	if o.Labels != nil {
		c.Labels = make(map[string]string, len(o.Labels))
		for k, v := range o.Labels {
			c.Labels[k] = v
		}
	}
	if o.DelegationEdge != nil {
		d := *o.DelegationEdge
		c.DelegationEdge = &d
	}
	return c
}

func (s *MemoryResolverStore) ReplaceObservations(_ context.Context, observations []model.Observation) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := make(map[string]model.Observation, len(observations))
	for _, o := range observations {
		if _, retracted := s.tombstones[o.ID]; retracted {
			continue
		}
		next[o.ID] = cloneObservation(o)
	}
	s.observations = next
	return nil
}

func (s *MemoryResolverStore) UpsertObservation(_ context.Context, o model.Observation) error {
	s.mu.Lock()
	if _, retracted := s.tombstones[o.ID]; retracted {
		s.mu.Unlock()
		return nil
	}
	s.observations[o.ID] = cloneObservation(o)
	s.mu.Unlock()
	return nil
}

func (s *MemoryResolverStore) RetractObservation(_ context.Context, id string) error {
	s.mu.Lock()
	delete(s.observations, id)
	s.tombstones[id] = struct{}{}
	s.mu.Unlock()
	return nil
}

func (s *MemoryResolverStore) Observations(_ context.Context) ([]model.Observation, error) {
	s.mu.RLock()
	out := make([]model.Observation, 0, len(s.observations))
	for _, o := range s.observations {
		out = append(out, cloneObservation(o))
	}
	s.mu.RUnlock()
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

func withinWindow(a, b time.Time, window time.Duration) bool {
	if a.IsZero() || b.IsZero() {
		return false
	}
	d := a.Sub(b)
	if d < 0 {
		d = -d
	}
	return d <= window
}

// Candidates returns only bounded weak hint/time candidates. Authenticated
// identity closure is computed from the complete resolver snapshot and cannot
// be truncated by this optimization seam.
func (s *MemoryResolverStore) Candidates(_ context.Context, target model.Observation, window time.Duration, limit int) ([]model.Observation, error) {
	s.mu.RLock()
	out := make([]model.Observation, 0)
	for id, candidate := range s.observations {
		if id == target.ID {
			continue
		}
		weakHint := target.ActorHint != "" && target.ActorHint == candidate.ActorHint
		sameIP := target.Labels["src_ip"] != "" && target.Labels["src_ip"] == candidate.Labels["src_ip"]
		temporal := withinWindow(target.Timestamp, candidate.Timestamp, window) && (target.Source == candidate.Source || sameIP || weakHint)
		if weakHint || temporal {
			out = append(out, cloneObservation(candidate))
		}
	}
	s.mu.RUnlock()
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (s *MemoryResolverStore) RetractEdge(_ context.Context, id string) error {
	s.mu.Lock()
	s.retracted[id] = struct{}{}
	s.mu.Unlock()
	return nil
}

func (s *MemoryResolverStore) EdgeRetracted(_ context.Context, id string) (bool, error) {
	s.mu.RLock()
	_, ok := s.retracted[id]
	s.mu.RUnlock()
	return ok, nil
}

func (s *MemoryResolverStore) Publish(_ context.Context, snapshot model.ResolverSnapshot) error {
	copy := cloneSnapshot(snapshot)
	s.mu.Lock()
	s.snapshot = copy
	s.mu.Unlock()
	return nil
}

func (s *MemoryResolverStore) Snapshot(_ context.Context) (model.ResolverSnapshot, error) {
	s.mu.RLock()
	copy := cloneSnapshot(s.snapshot)
	s.mu.RUnlock()
	return copy, nil
}
