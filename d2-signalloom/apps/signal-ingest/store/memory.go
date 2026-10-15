package store

import (
	"context"
	"sort"
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
	toAppend := make([]model.Observation, len(observations))
	copy(toAppend, observations)
	if p, err := NewSegmentPseudonymiserFromEnv(); err == nil && p != nil {
		for i := range toAppend {
			if toAppend[i].ActorHint != "" {
				if pseudo, err := p.Pseudonym(toAppend[i].ActorHint); err == nil && pseudo != "" {
					toAppend[i].ActorHint = pseudo
				}
			}
			if toAppend[i].ActorID != "" {
				if pseudo, err := p.Pseudonym(toAppend[i].ActorID); err == nil && pseudo != "" {
					toAppend[i].ActorID = pseudo
				}
			}
			if toAppend[i].PrincipalID != "" {
				if pseudo, err := p.Pseudonym(toAppend[i].PrincipalID); err == nil && pseudo != "" {
					toAppend[i].PrincipalID = pseudo
				}
			}
			if toAppend[i].SessionID != "" {
				if pseudo, err := p.Pseudonym(toAppend[i].SessionID); err == nil && pseudo != "" {
					toAppend[i].SessionID = pseudo
				}
			}
			if toAppend[i].ImpersonatedUser != "" {
				if pseudo, err := p.Pseudonym(toAppend[i].ImpersonatedUser); err == nil && pseudo != "" {
					toAppend[i].ImpersonatedUser = pseudo
				}
			}
		}
	}
	m.data = append(m.data, toAppend...)
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
	// Tenancy is a row predicate like any other, so it belongs here rather than at a call
	// site. Applying it in the store is what lets a paging read stop early: filtering after
	// the read means the reader cannot know how many rows it needs until it has them all.
	if q.TenantID != "" && o.Labels[TenantLabelKey] != q.TenantID {
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

// ScanObservations streams matching observations without copying the result set.
//
// fn receives a pointer into the store's own slice, valid only for the duration of the call.
func (m *MemoryStore) ScanObservations(_ context.Context, q Query, fn func(o *model.Observation) error) error {
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
		if err := fn(&m.data[i]); err != nil {
			return err
		}
		emitted++
		if q.Limit > 0 && emitted >= q.Limit {
			return nil
		}
	}
	return nil
}

// ObservationStats tallies in place. The in-memory store holds the rows already, so there is
// nothing to materialise and the only thing to avoid is building a second copy of them.
func (m *MemoryStore) ObservationStats(_ context.Context, q Query) (ObservationStats, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	layerSet := layerSetOf(q)
	out := ObservationStats{ByLayer: map[string]int{}, ByFidelity: map[string]int{}}
	for i := range m.data {
		if !matchesFilters(&m.data[i], q, layerSet) {
			continue
		}
		out.Total++
		out.ByLayer[string(m.data[i].Layer)]++
		out.ByFidelity[string(m.data[i].Fidelity)]++
		if ts := m.data[i].Timestamp; out.LastIngestion == nil || ts.After(*out.LastIngestion) {
			t := ts
			out.LastIngestion = &t
		}
	}
	return out, nil
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

// QueryPage returns observations matching the page query filters in (timestamp DESC, id DESC) order.
func (m *MemoryStore) QueryPage(_ context.Context, q PageQuery) ([]model.Observation, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	layerSet := make(map[model.Layer]struct{}, len(q.Layers))
	for _, l := range q.Layers {
		layerSet[l] = struct{}{}
	}

	hasCursor := !q.CursorTimestamp.IsZero() || q.CursorID != ""

	if q.Limit > 0 {
		h := newObservationMinHeap(q.Limit)
		seen := make(map[string]struct{})

		for i := range m.data {
			o := &m.data[i]
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
			if q.SubjectID != "" {
				matchSubject := (o.ActorHint == q.SubjectID) ||
					(o.Labels != nil && (o.Labels["actor_id"] == q.SubjectID ||
						o.Labels["principal_id"] == q.SubjectID ||
						o.Labels["impersonated_user"] == q.SubjectID ||
						o.Labels["user"] == q.SubjectID))
				if !matchSubject {
					continue
				}
			}
			if !q.AllTenants {
				if q.Tenant == "" || o.Labels == nil || o.Labels["tenant_id"] != q.Tenant {
					continue
				}
			}
			if hasCursor {
				if !(o.Timestamp.Before(q.CursorTimestamp) || (o.Timestamp.Equal(q.CursorTimestamp) && o.ID < q.CursorID)) {
					continue
				}
			}
			if o.ID != "" {
				if _, dup := seen[o.ID]; dup {
					continue
				}
				seen[o.ID] = struct{}{}
			}
			h.push(*o)
		}

		return h.sorted(), nil
	}

	var matched []model.Observation
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
		if q.SubjectID != "" {
			matchSubject := (o.ActorHint == q.SubjectID) ||
				(o.Labels != nil && (o.Labels["actor_id"] == q.SubjectID ||
					o.Labels["principal_id"] == q.SubjectID ||
					o.Labels["impersonated_user"] == q.SubjectID ||
					o.Labels["user"] == q.SubjectID))
			if !matchSubject {
				continue
			}
		}
		if !q.AllTenants {
			if q.Tenant == "" || o.Labels == nil || o.Labels["tenant_id"] != q.Tenant {
				continue
			}
		}
		matched = append(matched, o)
	}

	matched = DedupeByID(matched)

	// Sort in (timestamp DESC, id DESC) order.
	sortObservations(matched)

	// Apply cursor filter: keep only rows strictly after (CursorTimestamp, CursorID) in tuple order.
	if hasCursor {
		filtered := make([]model.Observation, 0, len(matched))
		for _, o := range matched {
			if o.Timestamp.Before(q.CursorTimestamp) || (o.Timestamp.Equal(q.CursorTimestamp) && o.ID < q.CursorID) {
				filtered = append(filtered, o)
			}
		}
		matched = filtered
	}

	return matched, nil
}

// Stats computes observation statistics without materializing or decoding observations.
func (m *MemoryStore) Stats(_ context.Context, q StatsQuery) (StoreStats, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	byLayer := make(map[string]int)
	byFidelity := make(map[string]int)
	// Tracked as a VALUE plus a flag, and the address taken once at the end.
	//
	// The loop previously held a *time.Time and did `t := o.Timestamp; lastIngestion = &t` on
	// every row with a later timestamp. Because t escapes through the pointer, that is a heap
	// allocation per improvement, and in an append-ordered store the timestamp improves on
	// almost every row: measured at 800,528 B of churn over a 100,000-row store, growing 9.94x
	// for a 10x store. An aggregate that allocates per row is the shape EAPCI-P1-6 exists to
	// remove, so it is removed here too even though residency was never the symptom.
	//
	// TestObservationsAndStatsAllocationIsFlatInStoreSize in the api package fails if this
	// regresses.
	var lastIngestion time.Time
	haveIngestion := false
	total := 0

	for _, o := range m.data {
		if !q.AllTenants {
			if q.Tenant == "" || o.Labels == nil || o.Labels["tenant_id"] != q.Tenant {
				continue
			}
		}
		total++
		if o.Layer != "" {
			byLayer[string(o.Layer)]++
		}
		if o.Fidelity != "" {
			byFidelity[string(o.Fidelity)]++
		}
		if !haveIngestion || o.Timestamp.After(lastIngestion) {
			lastIngestion = o.Timestamp
			haveIngestion = true
		}
	}

	stats := StoreStats{
		TotalObservations:      total,
		ObservationsByLayer:    byLayer,
		ObservationsByFidelity: byFidelity,
	}
	// Still nil when nothing matched, which is the distinction the API relies on to report "no
	// ingestion yet" rather than the zero time.
	if haveIngestion {
		stats.LastIngestion = &lastIngestion
	}
	return stats, nil
}

// sortObservations sorts observations by (timestamp DESC, id DESC).
func sortObservations(obs []model.Observation) {
	sort.SliceStable(obs, func(i, j int) bool {
		if obs[i].Timestamp.Equal(obs[j].Timestamp) {
			return obs[i].ID > obs[j].ID
		}
		return obs[i].Timestamp.After(obs[j].Timestamp)
	})
}

type observationMinHeap struct {
	items []model.Observation
	cap   int
}

func newObservationMinHeap(capacity int) *observationMinHeap {
	return &observationMinHeap{
		items: make([]model.Observation, 0, capacity),
		cap:   capacity,
	}
}

// obsIsLess returns true if a is "smaller" than b in (Timestamp DESC, ID DESC) order.
func obsIsLess(a, b *model.Observation) bool {
	if a.Timestamp.Equal(b.Timestamp) {
		return a.ID < b.ID
	}
	return a.Timestamp.Before(b.Timestamp)
}

func (h *observationMinHeap) push(o model.Observation) {
	if len(h.items) < h.cap {
		h.items = append(h.items, o)
		h.siftUp(len(h.items) - 1)
		return
	}
	if len(h.items) == 0 {
		return
	}
	// If o is smaller than or equal to the minimum in heap, discard it.
	if obsIsLess(&o, &h.items[0]) || (!obsIsLess(&h.items[0], &o) && o.ID == h.items[0].ID && o.Timestamp.Equal(h.items[0].Timestamp)) {
		return
	}
	// o is larger than root: replace root and sift down.
	h.items[0] = o
	h.siftDown(0)
}

func (h *observationMinHeap) siftUp(i int) {
	for i > 0 {
		parent := (i - 1) / 2
		if !obsIsLess(&h.items[i], &h.items[parent]) {
			break
		}
		h.items[i], h.items[parent] = h.items[parent], h.items[i]
		i = parent
	}
}

func (h *observationMinHeap) siftDown(i int) {
	n := len(h.items)
	for {
		left := 2*i + 1
		if left >= n {
			break
		}
		smallest := left
		right := left + 1
		if right < n && obsIsLess(&h.items[right], &h.items[left]) {
			smallest = right
		}
		if !obsIsLess(&h.items[smallest], &h.items[i]) {
			break
		}
		h.items[i], h.items[smallest] = h.items[smallest], h.items[i]
		i = smallest
	}
}

func (h *observationMinHeap) sorted() []model.Observation {
	sortObservations(h.items)
	return h.items
}

