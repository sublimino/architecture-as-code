package store

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// memoryPseudonymTestKey is synthetic key material for the keyed-MemoryStore contract tests.
const memoryPseudonymTestKey = "a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0"

// TestMemoryStore_KeyedStoresPseudonymsAndFindsByCleartext pins the SLCO-P2-3 contract on a keyed
// MemoryStore, which is the contract FrostDB already holds: identifiers are pseudonyms at rest, in
// the v2 read shape (cleartext fields empty, HMAC* fields populated), and every read path that takes
// an actor or subject filter finds the row by its CLEARTEXT identifier, because the filter is
// pseudonymised with the same key rather than compared raw.
func TestMemoryStore_KeyedStoresPseudonymsAndFindsByCleartext(t *testing.T) {
	t.Setenv(SegmentPseudonymKeyEnv, memoryPseudonymTestKey)
	p, err := NewSegmentPseudonymiserFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	pseudo := func(v string) string {
		t.Helper()
		out, err := p.Pseudonym(v)
		if err != nil {
			t.Fatal(err)
		}
		return out
	}

	ctx := context.Background()
	s := NewMemoryStore()
	now := time.Date(2026, 10, 15, 9, 0, 0, 0, time.UTC)
	tenant := map[string]string{TenantLabelKey: "tenant-a"}
	in := []model.Observation{
		{ID: "a", Timestamp: now, Layer: model.LayerIdentityAuth, Source: "t", Labels: tenant,
			ActorHint: "alice@example.invalid", PrincipalID: "princ-alice", ActorID: "act-alice",
			SessionID: "sess-alice", ImpersonatedUser: "imp-alice"},
		{ID: "b", Timestamp: now.Add(time.Second), Layer: model.LayerIdentityAuth, Source: "t", Labels: tenant,
			ActorHint: "bob@example.invalid", PrincipalID: "princ-bob"},
		{ID: "c", Timestamp: now.Add(2 * time.Second), Layer: model.LayerNetworkEgress, Source: "t", Labels: tenant},
	}
	if err := s.Append(ctx, in); err != nil {
		t.Fatal(err)
	}
	if in[0].ActorHint != "alice@example.invalid" {
		t.Fatal("Append mutated the caller's batch")
	}

	// At rest: no cleartext anywhere in a stored row, and the pseudonyms are where FrostDB puts them.
	all, err := s.QueryRange(ctx, Query{})
	if err != nil || len(all) != 3 {
		t.Fatalf("QueryRange(all) = %d rows, %v", len(all), err)
	}
	raw, _ := json.Marshal(all)
	for _, o := range in {
		for _, v := range []string{o.ActorHint, o.PrincipalID, o.ActorID, o.SessionID, o.ImpersonatedUser} {
			if v != "" && strings.Contains(string(raw), v) {
				t.Errorf("stored rows retain cleartext %q", v)
			}
		}
	}
	got := all[0]
	if got.ActorHint != "" || got.HMACActorHint != pseudo("alice@example.invalid") ||
		got.HMACPrincipalID != pseudo("princ-alice") || got.HMACActorID != pseudo("act-alice") ||
		got.HMACSessionID != pseudo("sess-alice") || got.HMACImpersonatedUser != pseudo("imp-alice") {
		t.Errorf("row a is not in the v2 pseudonym shape: %+v", got)
	}
	if all[2].HMACActorHint != "" {
		t.Errorf("an identity-free row gained a pseudonym %q; hashing \"\" is a join key", all[2].HMACActorHint)
	}

	ids := func(obs []model.Observation) string {
		out := make([]string, len(obs))
		for i := range obs {
			out[i] = obs[i].ID
		}
		return strings.Join(out, ",")
	}

	// Every filtered read path, by cleartext. The expected IDs are the rows that hold the identity.
	for _, tc := range []struct {
		name, actor, subject, want string
	}{
		{"actor", "alice@example.invalid", "", "a"},
		{"subject via actor_hint", "", "bob@example.invalid", "b"},
		{"subject via principal_id", "", "princ-alice", "a"},
		{"subject via impersonated_user", "", "imp-alice", "a"},
		{"querying by the pseudonym itself finds nothing", pseudo("alice@example.invalid"), "", ""},
		{"unknown actor", "mallory@example.invalid", "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			q := Query{ActorID: tc.actor, SubjectID: tc.subject}
			rows, err := s.QueryRange(ctx, q)
			if err != nil || ids(rows) != tc.want {
				t.Errorf("QueryRange = %q, %v; want %q", ids(rows), err, tc.want)
			}

			var scanned []string
			if err := s.ScanIDs(ctx, q, func(id string) error { scanned = append(scanned, id); return nil }); err != nil {
				t.Fatal(err)
			}
			if strings.Join(scanned, ",") != tc.want {
				t.Errorf("ScanIDs = %q, want %q", strings.Join(scanned, ","), tc.want)
			}

			var observed []string
			if err := s.ScanObservations(ctx, q, func(o *model.Observation) error { observed = append(observed, o.ID); return nil }); err != nil {
				t.Fatal(err)
			}
			if strings.Join(observed, ",") != tc.want {
				t.Errorf("ScanObservations = %q, want %q", strings.Join(observed, ","), tc.want)
			}

			st, err := s.ObservationStats(ctx, q)
			if err != nil || st.Total != len(scanned) {
				t.Errorf("ObservationStats.Total = %d, %v; want %d", st.Total, err, len(scanned))
			}

			for _, limit := range []int{0, 10} {
				page, err := s.QueryPage(ctx, PageQuery{Tenant: "tenant-a", ActorID: tc.actor, SubjectID: tc.subject, Limit: limit})
				if err != nil || ids(page) != tc.want {
					t.Errorf("QueryPage(limit=%d) = %q, %v; want %q", limit, ids(page), err, tc.want)
				}
			}
		})
	}

	if sp := s.Pseudonymiser(); sp == nil {
		t.Error("a keyed MemoryStore exposes no pseudonymiser; policy replay would evaluate cleartext allowlists against pseudonymised rows")
	} else if out, _ := sp.Pseudonym("alice@example.invalid"); out != got.HMACActorHint {
		t.Error("the exposed pseudonymiser is not the one the rows were written with")
	}
}

// TestMemoryStore_UnkeyedKeepsCleartext pins development mode: with no key the store keeps the
// pre-SLCO behaviour and exposes no pseudonymiser.
func TestMemoryStore_UnkeyedKeepsCleartext(t *testing.T) {
	t.Setenv(SegmentPseudonymKeyEnv, "")
	s := NewMemoryStore()
	ctx := context.Background()
	if err := s.Append(ctx, []model.Observation{{ID: "a", Timestamp: time.Now(), ActorHint: "alice"}}); err != nil {
		t.Fatal(err)
	}
	rows, err := s.QueryRange(ctx, Query{ActorID: "alice"})
	if err != nil || len(rows) != 1 || rows[0].ActorHint != "alice" || rows[0].HMACActorHint != "" {
		t.Fatalf("unkeyed store: %+v, %v", rows, err)
	}
	if s.Pseudonymiser() != nil {
		t.Error("an unkeyed store exposed a pseudonymiser")
	}
}

// TestMemoryStore_InvalidKeyFailsClosed: a key that is set but unusable must refuse the write, not
// store cleartext, matching FrostDB's refusal to start on the same input.
func TestMemoryStore_InvalidKeyFailsClosed(t *testing.T) {
	t.Setenv(SegmentPseudonymKeyEnv, "not-hex")
	s := NewMemoryStore()
	ctx := context.Background()
	if err := s.Append(ctx, []model.Observation{{ID: "a", Timestamp: time.Now(), ActorHint: "alice"}}); err == nil {
		t.Fatal("Append with an invalid key succeeded")
	}
	rows, _ := s.QueryRange(ctx, Query{})
	if len(rows) != 0 {
		t.Fatalf("a refused batch was stored: %+v", rows)
	}
	if _, err := s.QueryRange(ctx, Query{ActorID: "alice"}); err == nil {
		t.Error("an actor query with an invalid key succeeded")
	}
}
