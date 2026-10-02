// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package store

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// sentinelGolden is the stun-sentinel correlator's wire contract: the exact bytes its correlator
// test asserts it emits, and the file model.TestSentinelCorrelatorPayloadIsAcceptedByTheObservationContract
// decodes. That model test stops at Validate(); whether an observation LANDS is decided one tier
// further down, by Store.Append (review M4: a frostdb-tagged binary refused every sentinel POST
// with a 500 while the model contract stayed green).
const sentinelGolden = "../../stun-sentinel/pkg/correlator/testdata/ingest-observation.golden.json"

func readSentinelGolden(t *testing.T) []model.Observation {
	t.Helper()
	raw, err := os.ReadFile(sentinelGolden)
	if err != nil {
		t.Fatalf("read the correlator's contract file: %v", err)
	}
	var batch []model.Observation
	if err := json.Unmarshal(raw, &batch); err != nil {
		t.Fatalf("decode the correlator payload as the handler does: %v", err)
	}
	if len(batch) == 0 {
		t.Fatal("contract file holds no observations")
	}
	return batch
}

// TestSentinelGoldenObservationPersistsThroughTheConfiguredStore runs under both build tags.
// NewStoreFromEnv("frostdb", …) is the production selection path: without -tags frostdb it yields
// the memory store, with it the FrostDB segment store and its closed label allow-list. Either way
// the sentinel's observation must be accepted and come back out with every wire label key.
func TestSentinelGoldenObservationPersistsThroughTheConfiguredStore(t *testing.T) {
	s, err := NewStoreFromEnv("frostdb", t.TempDir())
	if err != nil {
		t.Fatalf("NewStoreFromEnv: %v", err)
	}
	defer s.Close()

	batch := readSentinelGolden(t)
	if err := s.Append(context.Background(), batch); err != nil {
		t.Fatalf("Append refused the sentinel's golden observation (%T): %v", s, err)
	}

	got, err := s.QueryRange(context.Background(), Query{
		After:  batch[0].Timestamp.Add(-time.Second),
		Before: batch[0].Timestamp.Add(time.Second),
	})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	if len(got) != len(batch) {
		t.Fatalf("stored %d observations, read back %d (%T)", len(batch), len(got), s)
	}
	for k, want := range batch[0].Labels {
		if got[0].Labels[k] != want {
			t.Errorf("label %q: stored %q, read back %q (%T)", k, want, got[0].Labels[k], s)
		}
	}
}
