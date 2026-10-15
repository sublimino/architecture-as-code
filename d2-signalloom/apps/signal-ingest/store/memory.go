package store

import (
	"context"
	"os"
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

// memoryPseudonymiser resolves the segment pseudonymiser from the environment.
//
// An UNSET key is development mode and yields (nil, nil): the store keeps cleartext, exactly as
// it did before SLCO-P2-3. A key that is SET but unusable is an error, never a silent fall back to
// cleartext — the FrostDB store refuses to start on the same input.
func memoryPseudonymiser() (*SegmentPseudonymiser, error) {
	if os.Getenv(SegmentPseudonymKeyEnv) == "" {
		return nil, nil
	}
	return NewSegmentPseudonymiserFromEnv()
}

// Pseudonymiser exposes the key this store pseudonymises with, or nil in development mode.
//
// policy.StorePseudonymiser takes it so the live path and replay evaluate obs.actor and the
// bundles' actor allowlists in the same pseudonym space the rows are stored in. Without it a
// keyed MemoryStore stores pseudonyms while the policy sink evaluates cleartext, and replay
// diverges from live.
func (m *MemoryStore) Pseudonymiser() *SegmentPseudonymiser {
	p, err := memoryPseudonymiser()
	if err != nil {
		return nil
	}
	return p
}

// pseudonymiseObservation moves each direct identifier into its keyed HMAC* field and clears the
// cleartext one, which is the shape a segment-schema-v2 FrostDB row is read back in
// (model.Observation, "Pseudonymous projection"). Putting the pseudonym into the cleartext field
// instead would make every consumer that treats ActorHint as cleartext (policy.ActorIdentity)
// pseudonymise it a second time.
//
// An empty identifier is left alone, so an HMAC* field the caller already populated survives.
func pseudonymiseObservation(o *model.Observation, p *SegmentPseudonymiser) error {
	for _, f := range []struct{ clear, hmac *string }{
		{&o.ActorHint, &o.HMACActorHint},
		{&o.ActorID, &o.HMACActorID},
		{&o.PrincipalID, &o.HMACPrincipalID},
		{&o.SessionID, &o.HMACSessionID},
		{&o.ImpersonatedUser, &o.HMACImpersonatedUser},
	} {
		if *f.clear == "" {
			continue
		}
		pseudo, err := p.Pseudonym(*f.clear)
		if err != nil {
			return err
		}
		*f.hmac = pseudo
		*f.clear = ""
	}
	return nil
}

// Append adds observations to the in-memory store.
//
// With SIGNAL_SEGMENT_PSEUDONYM_KEY set (SLCO-P2-3), identifiers are pseudonymised at rest. The
// whole batch is pseudonymised before any of it is stored, so a failure stores nothing rather
// than a cleartext row.
func (m *MemoryStore) Append(_ context.Context, observations []model.Observation) error {
	p, err := memoryPseudonymiser()
	if err != nil {
		return err
	}
	toAppend := make([]model.Observation, len(observations))
	copy(toAppend, observations)
	if p != nil {
		for i := range toAppend {
			if err := pseudonymiseObservation(&toAppend[i], p); err != nil {
				return err
			}
		}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.data = append(m.data, toAppend...)
	return nil
}

// identityMatch is a query's actor and subject filters in both representations a row can hold:
// cleartext (no key, or a row stored before one was set) and the keyed pseudonym (HMAC* fields).
// The pseudonyms are computed once per query, never per row.
type identityMatch struct {
	actor, actorPseudo     string
	subject, subjectPseudo string
}

func newIdentityMatch(actor, subject string) (identityMatch, error) {
	im := identityMatch{actor: actor, subject: subject}
	if actor == "" && subject == "" {
		return im, nil
	}
	p, err := memoryPseudonymiser()
	if err != nil || p == nil {
		return im, err
	}
	if im.actorPseudo, err = p.Pseudonym(actor); err != nil {
		return im, err
	}
	if im.subjectPseudo, err = p.Pseudonym(subject); err != nil {
		return im, err
	}
	return im, nil
}

// sameIdentity reports whether a row field pair holds want. A row carries one representation per
// field, so the cleartext is compared with the raw query value and the HMAC field only with the
// query's pseudonym — never the raw value, which would let a caller query by pseudonym directly.
func sameIdentity(clear, hmac, want, wantPseudo string) bool {
	return (clear != "" && clear == want) || (wantPseudo != "" && hmac == wantPseudo)
}

// matches applies the actor and subject filters, mirroring FrostDB's matchesQuery: actor is
// ActorHint; subject is any of ActorHint, ActorID, PrincipalID or ImpersonatedUser, plus the
// cleartext identity labels this store has always matched.
func (im identityMatch) matches(o *model.Observation) bool {
	if im.actor != "" && !sameIdentity(o.ActorHint, o.HMACActorHint, im.actor, im.actorPseudo) {
		return false
	}
	if im.subject != "" {
		s, sp := im.subject, im.subjectPseudo
		matchSubject := sameIdentity(o.ActorHint, o.HMACActorHint, s, sp) ||
			sameIdentity(o.ActorID, o.HMACActorID, s, sp) ||
			sameIdentity(o.PrincipalID, o.HMACPrincipalID, s, sp) ||
			sameIdentity(o.ImpersonatedUser, o.HMACImpersonatedUser, s, sp) ||
			(o.Labels != nil && (o.Labels["actor_id"] == s ||
				o.Labels["principal_id"] == s ||
				o.Labels["impersonated_user"] == s ||
				o.Labels["user"] == s))
		if !matchSubject {
			return false
		}
	}
	return true
}

// matchesFilters reports whether o satisfies q's row predicates. Offset and Limit are
// positional and are applied by the caller, not here.
//
// Shared by QueryRange and ScanIDs so the two cannot drift: a row that one returns and the
// other skips would make a warmed ID set disagree with the rows it was warmed from.
func matchesFilters(o *model.Observation, q Query, layerSet map[model.Layer]struct{}, im identityMatch) bool {
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
	return im.matches(o)
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
	im, err := newIdentityMatch(q.ActorID, q.SubjectID)
	if err != nil {
		return nil, err
	}

	var matched []model.Observation
	for i := range m.data {
		if !matchesFilters(&m.data[i], q, layerSet, im) {
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
	im, err := newIdentityMatch(q.ActorID, q.SubjectID)
	if err != nil {
		return err
	}

	emitted, skipped := 0, 0
	for i := range m.data {
		if !matchesFilters(&m.data[i], q, layerSet, im) {
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
	im, err := newIdentityMatch(q.ActorID, q.SubjectID)
	if err != nil {
		return err
	}

	emitted, skipped := 0, 0
	for i := range m.data {
		if !matchesFilters(&m.data[i], q, layerSet, im) {
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
	im, err := newIdentityMatch(q.ActorID, q.SubjectID)
	if err != nil {
		return ObservationStats{}, err
	}
	out := ObservationStats{ByLayer: map[string]int{}, ByFidelity: map[string]int{}}
	for i := range m.data {
		if !matchesFilters(&m.data[i], q, layerSet, im) {
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

	im, err := newIdentityMatch(q.ActorID, q.SubjectID)
	if err != nil {
		return nil, err
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
			if !im.matches(o) {
				continue
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
		if !im.matches(&o) {
			continue
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

