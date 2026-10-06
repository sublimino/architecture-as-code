//go:build frostdb

package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// wrappedStore stands in for policy.Store, which is what main.go hands the handlers on a live
// pod: the FrostDB store is one Unwrap() below h.Store, never h.Store itself.
type wrappedStore struct{ store.SignalStore }

func (w wrappedStore) Unwrap() store.SignalStore { return w.SignalStore }

// kind-osramp, 2026-10-06: the /feeds "Seed Fixtures" button returned 500 "failed to seed
// fixtures" because collectors.SeedAll carries label keys from the in-memory era (destination,
// src_ip, principal_email, ...) and the FrostDB segment label allow-list refuses the whole batch
// on the first one. TestSeedFixtures runs on the memory store, which has no allow-list, so it
// stayed green throughout. This drives the same route against the durable store the pod runs.
func TestSeedFixturesAppendsToFrostDB(t *testing.T) {
	t.Setenv(store.SegmentPseudonymKeyEnv, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
	for name, wrap := range map[string]func(store.SignalStore) store.SignalStore{
		"frostdb":                 func(s store.SignalStore) store.SignalStore { return s },
		"frostdb behind a policy": func(s store.SignalStore) store.SignalStore { return wrappedStore{s} },
	} {
		t.Run(name, func(t *testing.T) {
			fs, err := store.NewFrostDBStore()
			if err != nil {
				t.Fatalf("NewFrostDBStore: %v", err)
			}
			defer fs.Close()
			s := wrap(fs)
			e, err := correlation.NewEngine(s)
			if err != nil {
				t.Fatal(err)
			}
			h := &Handlers{Store: s, Engine: e, Audit: audit.NewFakeWriter()}
			mux := http.NewServeMux()
			h.RegisterRoutes(mux)

			w := httptest.NewRecorder()
			mux.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/api/v1/collectors/seed", nil))
			if w.Code != http.StatusCreated {
				t.Fatalf("seed on FrostDB: want 201, got %d, body: %s", w.Code, w.Body.String())
			}
			var body struct {
				Seeded int `json:"seeded"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			want := len(collectors.SeedAll(time.Now().UTC()))
			if body.Seeded != want {
				t.Errorf("seeded = %d, want %d (every fixture)", body.Seeded, want)
			}
			got, err := fs.QueryRange(context.Background(), store.Query{})
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != want {
				t.Errorf("store holds %d observations after seed, want %d", len(got), want)
			}
			for _, o := range got {
				for k := range o.Labels {
					if !store.IsAllowedLabelKey(k) {
						t.Errorf("observation %s carries label %q outside the segment allow-list", o.ID, k)
					}
				}
			}
		})
	}
}
