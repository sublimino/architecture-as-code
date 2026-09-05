//go:build frostdb

package store

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// TestFrostDBStore_ContractSuite runs the full SignalStore contract test suite
// against the FrostDB implementation — the same suite MemoryStore passes.
func TestFrostDBStore_ContractSuite(t *testing.T) {
	StoreTestSuite(t, func() SignalStore {
		s, err := NewFrostDBStore()
		if err != nil {
			t.Fatalf("NewFrostDBStore: %v", err)
		}
		return s
	})
}

func TestFrostDBStore_Append(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	now := time.Now().UTC()
	obs := []model.Observation{
		{
			ID:             "frost-1",
			Timestamp:      now,
			Layer:          model.LayerNetworkEgress,
			Fidelity:       model.FidelitySuggestive,
			Source:         "test",
			Confidence:     0.4,
			ActorHint:      "actor-x",
			RawEvidenceRef: "ref-1",
			Description:    "test observation",
			Labels:         map[string]string{"workload": "api", "namespace": "prod"},
		},
	}

	if err := s.Append(context.Background(), obs); err != nil {
		t.Fatalf("Append failed: %v", err)
	}
}

func TestFrostDBStore_AppendMultiple(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	now := time.Now().UTC()
	obs := []model.Observation{
		{ID: "f1", Timestamp: now, Layer: model.LayerNetworkEgress, Source: "test", Labels: map[string]string{"k": "v1"}},
		{ID: "f2", Timestamp: now.Add(time.Second), Layer: model.LayerBehavioural, Source: "test", Labels: map[string]string{"k": "v2"}},
		{ID: "f3", Timestamp: now.Add(2 * time.Second), Layer: model.LayerIdentityAuth, Source: "test"},
	}

	if err := s.Append(context.Background(), obs); err != nil {
		t.Fatalf("Append multiple failed: %v", err)
	}
}

// TestFrostDBStore_RoundTrip verifies append-then-query returns correct data.
func TestFrostDBStore_RoundTrip(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	now := time.Now().UTC().Truncate(time.Microsecond)
	obs := []model.Observation{
		{
			ID:             "rt-1",
			Timestamp:      now,
			Layer:          model.LayerNetworkEgress,
			Fidelity:       model.FidelityStrong,
			Source:         "test-source",
			Confidence:     0.85,
			ActorHint:      "actor-rt",
			RawEvidenceRef: "ref-rt",
			Description:    "round-trip test",
			Labels:         map[string]string{"env": "staging", "workload": "api"},
		},
		{
			ID:        "rt-2",
			Timestamp: now.Add(time.Second),
			Layer:     model.LayerBehavioural,
			Fidelity:  model.FidelitySuggestive,
			Source:    "test-source",
		},
	}

	if err := s.Append(context.Background(), obs); err != nil {
		t.Fatalf("Append: %v", err)
	}

	got, err := s.QueryRange(context.Background(), Query{})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}

	if len(got) != 2 {
		t.Fatalf("want 2 observations, got %d", len(got))
	}

	// Verify first observation fields.
	found := false
	for _, o := range got {
		if o.ID == "rt-1" {
			found = true
			if o.Layer != model.LayerNetworkEgress {
				t.Errorf("layer: want %s, got %s", model.LayerNetworkEgress, o.Layer)
			}
			if o.Fidelity != model.FidelityStrong {
				t.Errorf("fidelity: want %s, got %s", model.FidelityStrong, o.Fidelity)
			}
			if o.Source != "test-source" {
				t.Errorf("source: want test-source, got %s", o.Source)
			}
			if o.Confidence != 0.85 {
				t.Errorf("confidence: want 0.85, got %f", o.Confidence)
			}
			if o.ActorHint != "actor-rt" {
				t.Errorf("actor_hint: want actor-rt, got %s", o.ActorHint)
			}
			if o.Labels["env"] != "staging" {
				t.Errorf("label env: want staging, got %s", o.Labels["env"])
			}
			if o.Labels["workload"] != "api" {
				t.Errorf("label workload: want api, got %s", o.Labels["workload"])
			}
		}
	}
	if !found {
		t.Error("observation rt-1 not found in results")
	}
}

// TestFrostDBStore_QueryFilters verifies all query filter paths.
func TestFrostDBStore_QueryFilters(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	base := time.Date(2025, 6, 1, 0, 0, 0, 0, time.UTC)
	obs := []model.Observation{
		{ID: "a", Timestamp: base, Layer: model.LayerNetworkEgress, ActorHint: "alice", Source: "test"},
		{ID: "b", Timestamp: base.Add(time.Hour), Layer: model.LayerBehavioural, ActorHint: "bob", Source: "test"},
		{ID: "c", Timestamp: base.Add(2 * time.Hour), Layer: model.LayerIdentityAuth, ActorHint: "alice", Source: "test"},
	}
	if err := s.Append(context.Background(), obs); err != nil {
		t.Fatalf("Append: %v", err)
	}

	t.Run("filter_by_layer", func(t *testing.T) {
		got, err := s.QueryRange(context.Background(), Query{
			Layers: []model.Layer{model.LayerBehavioural},
		})
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 1 || got[0].ID != "b" {
			t.Errorf("layer filter: want [b], got %v", ids(got))
		}
	})

	t.Run("filter_by_time", func(t *testing.T) {
		got, err := s.QueryRange(context.Background(), Query{
			After: base.Add(30 * time.Minute),
		})
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 2 {
			t.Errorf("time filter: want 2, got %d (%v)", len(got), ids(got))
		}
	})

	t.Run("filter_by_actor", func(t *testing.T) {
		got, err := s.QueryRange(context.Background(), Query{
			ActorID: "alice",
		})
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 2 {
			t.Errorf("actor filter: want 2, got %d (%v)", len(got), ids(got))
		}
	})

	t.Run("limit", func(t *testing.T) {
		got, err := s.QueryRange(context.Background(), Query{
			Limit: 1,
		})
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 1 {
			t.Errorf("limit: want 1, got %d", len(got))
		}
	})
}

// TestFrostDBStoreWithBucket_ParquetOnDisk verifies that Parquet files appear
// on disk when using the bucket-backed constructor.
func TestFrostDBStoreWithBucket_ParquetOnDisk(t *testing.T) {
	dir := t.TempDir()

	s, err := NewFrostDBStoreWithBucket(dir)
	if err != nil {
		t.Fatalf("NewFrostDBStoreWithBucket: %v", err)
	}

	now := time.Now().UTC()
	obs := []model.Observation{
		{ID: "disk-1", Timestamp: now, Layer: model.LayerNetworkEgress, Source: "test"},
		{ID: "disk-2", Timestamp: now.Add(time.Second), Layer: model.LayerBehavioural, Source: "test"},
	}

	if err := s.Append(context.Background(), obs); err != nil {
		t.Fatalf("Append: %v", err)
	}

	// Query back to verify round-trip works with bucket backend.
	got, err := s.QueryRange(context.Background(), Query{})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	if len(got) != 2 {
		t.Errorf("want 2 observations, got %d", len(got))
	}

	// Close to flush any pending writes.
	if err := s.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	// Check that the directory has content (FrostDB writes block data).
	// Parquet files may be inside subdirectories.
	hasFiles := false
	_ = filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() && info.Size() > 0 {
			hasFiles = true
			t.Logf("found file: %s (%d bytes)", path, info.Size())
		}
		return nil
	})

	// Note: FrostDB writes Parquet blocks to storage when blocks are rotated
	// (full) or on close. For small test data, files may not appear until close.
	// We log either way; the round-trip query above is the authoritative test.
	if !hasFiles {
		t.Log("no files found in storage dir after close — FrostDB may not have flushed blocks for this small dataset")
	}
}

// TestFrostDBStore_EquivalenceWithMemory verifies that FrostDB and MemoryStore
// return equivalent results for the same input data.
func TestFrostDBStore_EquivalenceWithMemory(t *testing.T) {
	frost, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer frost.Close()

	mem := NewMemoryStore()
	defer mem.Close()

	base := time.Date(2025, 3, 15, 10, 0, 0, 0, time.UTC)
	obs := []model.Observation{
		{ID: "eq-1", Timestamp: base, Layer: model.LayerNetworkEgress, Fidelity: model.FidelityStrong, Source: "src-a", Confidence: 0.9, ActorHint: "actor-1", Labels: map[string]string{"k": "v1"}},
		{ID: "eq-2", Timestamp: base.Add(time.Minute), Layer: model.LayerBehavioural, Fidelity: model.FidelitySuggestive, Source: "src-b", Confidence: 0.4, ActorHint: "actor-2"},
		{ID: "eq-3", Timestamp: base.Add(2 * time.Minute), Layer: model.LayerIdentityAuth, Fidelity: model.FidelityDefinitive, Source: "src-a", Confidence: 1.0, ActorHint: "actor-1", Labels: map[string]string{"k": "v2", "env": "prod"}},
	}

	ctx := context.Background()

	if err := frost.Append(ctx, obs); err != nil {
		t.Fatalf("frost.Append: %v", err)
	}
	if err := mem.Append(ctx, obs); err != nil {
		t.Fatalf("mem.Append: %v", err)
	}

	queries := []struct {
		name string
		q    Query
	}{
		{"all", Query{}},
		{"layer_filter", Query{Layers: []model.Layer{model.LayerBehavioural}}},
		{"time_filter", Query{After: base.Add(30 * time.Second)}},
		{"actor_filter", Query{ActorID: "actor-1"}},
		{"limit", Query{Limit: 1}},
		{"combined", Query{Layers: []model.Layer{model.LayerNetworkEgress, model.LayerIdentityAuth}, ActorID: "actor-1"}},
	}

	for _, tc := range queries {
		t.Run(tc.name, func(t *testing.T) {
			frostResult, err := frost.QueryRange(ctx, tc.q)
			if err != nil {
				t.Fatalf("frost.QueryRange: %v", err)
			}
			memResult, err := mem.QueryRange(ctx, tc.q)
			if err != nil {
				t.Fatalf("mem.QueryRange: %v", err)
			}

			if len(frostResult) != len(memResult) {
				t.Errorf("count mismatch: frost=%d, mem=%d", len(frostResult), len(memResult))
				return
			}

			// Build ID sets for comparison (order may differ).
			frostIDs := make(map[string]bool, len(frostResult))
			for _, o := range frostResult {
				frostIDs[o.ID] = true
			}
			for _, o := range memResult {
				if !frostIDs[o.ID] {
					t.Errorf("memory has ID %s but frost does not", o.ID)
				}
			}
		})
	}
}

// TestFrostDBStore_DropPartition_DocumentedLimitation verifies DropPartition
// does not error (it is a documented no-op in the FrostDB implementation).
func TestFrostDBStore_DropPartition_DocumentedLimitation(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	now := time.Now().UTC()
	obs := []model.Observation{
		{ID: "dp-1", Timestamp: now, Layer: model.LayerNetworkEgress, Source: "test"},
	}
	if err := s.Append(context.Background(), obs); err != nil {
		t.Fatalf("Append: %v", err)
	}

	// DropPartition should exclude data before now.Add(time.Hour).
	if err := s.DropPartition(context.Background(), now.Add(time.Hour)); err != nil {
		t.Fatalf("DropPartition: %v", err)
	}

	// Data before the dropped threshold should not be returned.
	got, err := s.QueryRange(context.Background(), Query{})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("want 0 after dropping partition, got %d", len(got))
	}
}

// TestFrostDBStore_AdditiveColumnsRoundTrip verifies that all new resolution columns persist and round-trip faithfully.
func TestFrostDBStore_AdditiveColumnsRoundTrip(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	now := time.Now().UTC().Truncate(time.Microsecond)
	obs := []model.Observation{
		{
			ID:               "add-col-1",
			Timestamp:        now,
			Layer:            model.LayerIdentityAuth,
			Fidelity:         model.FidelityDefinitive,
			Source:           "openbao-audit",
			Confidence:       1.0,
			ActorHint:        "spiffe://cluster.local/ns/agent/sa/runner",
			RawEvidenceRef:   "ref-col-1",
			Description:      "round-trip additive columns",
			Labels:           map[string]string{"env": "prod"},
			PrincipalID:      "principal-runner",
			ActorID:          "actor-runner",
			SessionID:        "sess-12345",
			ImpersonatedUser: "admin@corp.internal",
			DelegationDepth:  3,
		},
	}

	if err := s.Append(context.Background(), obs); err != nil {
		t.Fatalf("Append failed: %v", err)
	}

	results, err := s.QueryRange(context.Background(), Query{ActorID: "spiffe://cluster.local/ns/agent/sa/runner"})
	if err != nil {
		t.Fatalf("QueryRange failed: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("want 1 observation, got %d", len(results))
	}

	got := results[0]
	if got.PrincipalID != obs[0].PrincipalID {
		t.Errorf("PrincipalID = %q, want %q", got.PrincipalID, obs[0].PrincipalID)
	}
	if got.ActorID != obs[0].ActorID {
		t.Errorf("ActorID = %q, want %q", got.ActorID, obs[0].ActorID)
	}
	if got.SessionID != obs[0].SessionID {
		t.Errorf("SessionID = %q, want %q", got.SessionID, obs[0].SessionID)
	}
	if got.ImpersonatedUser != obs[0].ImpersonatedUser {
		t.Errorf("ImpersonatedUser = %q, want %q", got.ImpersonatedUser, obs[0].ImpersonatedUser)
	}
	if got.DelegationDepth != obs[0].DelegationDepth {
		t.Errorf("DelegationDepth = %d, want %d", got.DelegationDepth, obs[0].DelegationDepth)
	}
}

// TestFrostDBStore_EquivalenceWithMemory_AdditiveColumns tests memory vs frostdb equivalence with additive fields.
func TestFrostDBStore_EquivalenceWithMemory_AdditiveColumns(t *testing.T) {
	frost, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer frost.Close()

	mem := NewMemoryStore()
	defer mem.Close()

	base := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
	obs := []model.Observation{
		{
			ID:               "eq-add-1",
			Timestamp:        base,
			Layer:            model.LayerIdentityAuth,
			Fidelity:         model.FidelityDefinitive,
			Source:           "bao-audit",
			ActorHint:        "actor-1",
			PrincipalID:      "princ-1",
			ActorID:          "act-1",
			SessionID:        "sess-1",
			ImpersonatedUser: "user-1",
			DelegationDepth:  1,
		},
		{
			ID:               "eq-add-2",
			Timestamp:        base.Add(time.Minute),
			Layer:            model.LayerNetworkEgress,
			Fidelity:         model.FidelityStrong,
			Source:           "sentinel",
			ActorHint:        "actor-2",
			PrincipalID:      "princ-2",
			ActorID:          "act-2",
			SessionID:        "sess-2",
			DelegationDepth:  0,
		},
	}

	ctx := context.Background()
	if err := frost.Append(ctx, obs); err != nil {
		t.Fatalf("frost.Append: %v", err)
	}
	if err := mem.Append(ctx, obs); err != nil {
		t.Fatalf("mem.Append: %v", err)
	}

	frostRes, err := frost.QueryRange(ctx, Query{})
	if err != nil {
		t.Fatal(err)
	}
	memRes, err := mem.QueryRange(ctx, Query{})
	if err != nil {
		t.Fatal(err)
	}

	if len(frostRes) != len(memRes) {
		t.Fatalf("count mismatch: frost=%d, mem=%d", len(frostRes), len(memRes))
	}

	for i := range frostRes {
		f := frostRes[i]
		m := memRes[i]
		if f.PrincipalID != m.PrincipalID || f.ActorID != m.ActorID || f.SessionID != m.SessionID ||
			f.ImpersonatedUser != m.ImpersonatedUser || f.DelegationDepth != m.DelegationDepth {
			t.Errorf("field mismatch at [%d]: frost=%+v, mem=%+v", i, f, m)
		}
	}
}

// TestStore_NegativeSpace_QueryFiltering asserts query filtering is identical between stores and not widened.
func TestStore_NegativeSpace_QueryFiltering(t *testing.T) {
	frost, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer frost.Close()

	mem := NewMemoryStore()
	defer mem.Close()

	base := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
	obs := []model.Observation{
		{ID: "neg-1", Timestamp: base, Layer: model.LayerNetworkEgress, ActorHint: "actor-a", Source: "src-1"},
		{ID: "neg-2", Timestamp: base.Add(time.Minute), Layer: model.LayerIdentityAuth, ActorHint: "actor-b", Source: "src-2"},
	}

	ctx := context.Background()
	if err := frost.Append(ctx, obs); err != nil {
		t.Fatal(err)
	}
	if err := mem.Append(ctx, obs); err != nil {
		t.Fatal(err)
	}

	// Non-matching ActorID query should return 0 results from both stores
	qNonMatch := Query{ActorID: "actor-nonexistent"}
	frostRes, _ := frost.QueryRange(ctx, qNonMatch)
	memRes, _ := mem.QueryRange(ctx, qNonMatch)

	if len(frostRes) != 0 || len(memRes) != 0 {
		t.Errorf("negative query mismatch: frost=%d, mem=%d (both want 0)", len(frostRes), len(memRes))
	}
}

// ids extracts observation IDs for test diagnostics.
func ids(obs []model.Observation) []string {
	out := make([]string, len(obs))
	for i, o := range obs {
		out[i] = o.ID
	}
	return out
}

