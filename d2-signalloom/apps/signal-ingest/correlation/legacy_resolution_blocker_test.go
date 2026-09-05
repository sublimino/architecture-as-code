package correlation

import (
	"context"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// TestLegacyResolutionBlocker characterizes a known defect, NOT the requested
// Resolve acceptance gate. A PASS proves the SFDP-P1-2 hard blocker exists:
// preserving legacy grouping also preserves a false merge. Once a revised
// contract authorizes changing grouping, replace this characterization with
// the zero-false-merge regression gate; do not preserve the defect as policy.
func TestLegacyResolutionBlocker(t *testing.T) {
	tests := []struct {
		name      string
		hintB     string
		sourceB   string
		wantID    string
		wantFalse int
	}{
		{"same_principal_control", "spiffe://test/alice", "shared-egress", "actor-spiffe://test/alice", 0},
		{"distinct_principals_shared_source_and_time", "spiffe://test/bob", "shared-egress", "actor-src-shared-egress", 1},
		{"distinct_principals_separate_source_control", "spiffe://test/bob", "other-egress", "", 0},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
			observations := []model.Observation{
				{ID: "alice-identity", Timestamp: now, Layer: model.LayerIdentityAuth, Fidelity: model.FidelitySuggestive, Source: "shared-egress", ActorHint: "spiffe://test/alice"},
				{ID: "peer-network", Timestamp: now, Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive, Source: tc.sourceB, ActorHint: tc.hintB},
			}
			// Ground truth labels are separate from the engine's grouping output.
			principal := map[string]string{"alice-identity": "alice", "peer-network": "alice"}
			if tc.hintB != observations[0].ActorHint {
				principal["peer-network"] = "bob"
			}
			e, err := NewEngine(seedStore(t, observations))
			if err != nil {
				t.Fatal(err)
			}
			actors, err := e.Correlate(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			wantActors := 1
			if tc.wantID == "" {
				wantActors = 0
			}
			if len(actors) != wantActors {
				t.Fatalf("legacy actor count = %d, want %d", len(actors), wantActors)
			}
			falseMerges := 0
			for _, actor := range actors {
				if actor.ID != tc.wantID {
					t.Fatalf("legacy actor ID = %q, want %q", actor.ID, tc.wantID)
				}
				if len(actor.EvidenceChain) != 2 {
					t.Fatalf("evidence links = %d, want 2", len(actor.EvidenceChain))
				}
				labels := make(map[string]bool)
				ids := make(map[string]bool)
				for _, link := range actor.EvidenceChain {
					label, ok := principal[link.ObservationID]
					if !ok || ids[link.ObservationID] {
						t.Fatalf("unexpected or duplicate evidence: %q", link.ObservationID)
					}
					ids[link.ObservationID] = true
					labels[label] = true
				}
				if len(labels) > 1 {
					falseMerges++
				}
			}
			t.Logf("legacy actor_id=%q actors=%d false-merge=%d; required acceptance false-merge=0", tc.wantID, len(actors), falseMerges)
			if falseMerges != tc.wantFalse {
				t.Fatalf("blocker characterization changed: false-merge=%d, expected %d", falseMerges, tc.wantFalse)
			}
		})
	}
}
