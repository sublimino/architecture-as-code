//go:build frostdb

package store

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// Fixture generator for docs/signalloom/runbooks/slaws-duckdb-last-resort.md.
//
// The runbook's whole claim is that a human can read the Parquet directory with DuckDB when
// signal-ingest is down. A runbook whose commands were never run is a guess, so this writes a real
// store, flushed to real Parquet, for the documented query to be executed against. Keeping the
// generator in the test suite rather than in a scratch script means it compiles against the
// current schema: if the segment schema changes, this breaks and the runbook gets revisited.
//
// Opt-in by design. Unset, it skips -- it writes outside t.TempDir() to a caller-chosen path,
// which is not something a plain `go test ./...` should do. It is NOT guarding a missing
// dependency: the store under test is compiled in either way and frostdb_test.go covers its
// behaviour, so this skip cannot hide a build failure.
//
//	SIGNAL_STORE_FIXTURE_DIR=/tmp/signal-store-fixture \
//	  go test -tags frostdb -run TestWriteDuckDBFixture -count=1 ./store/
const fixtureDirEnv = "SIGNAL_STORE_FIXTURE_DIR"

// fixtureObservations is the shape the runbook describes: six layers represented, actors
// pseudonymised by the store, and a one-line plaintext description.
var fixtureLayers = []model.Layer{
	model.LayerNetworkEgress,
	model.LayerIdentityAuth,
	model.LayerApplicationSaaS,
	model.LayerEndpointHost,
	model.LayerBehavioural,
	model.LayerCloudControlPlane,
}

func TestWriteDuckDBFixture(t *testing.T) {
	dir := os.Getenv(fixtureDirEnv)
	if dir == "" {
		t.Skipf("set %s to write a Parquet fixture for the DuckDB runbook", fixtureDirEnv)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", dir, err)
	}

	// A fixed root key and epoch so the fixture is reproducible: the HMAC actor columns in the
	// runbook's output are stable across runs, and are demonstrably not reversible to the input.
	p, err := NewSegmentPseudonymiser([]byte("slaws-duckdb-runbook-fixture-root-key"), "tenant-demo", 1)
	if err != nil {
		t.Fatalf("NewSegmentPseudonymiser: %v", err)
	}

	s, err := NewFrostDBStoreWithBucket(dir, WithManualFlush(), WithSegmentPseudonymiser(p))
	if err != nil {
		t.Fatalf("NewFrostDBStoreWithBucket: %v", err)
	}

	// Deterministic timestamps: a fixed base, not time.Now(), so repeated runs are comparable.
	base := time.Date(2026, 10, 4, 9, 0, 0, 0, time.UTC)
	const perLayer = 5
	var obs []model.Observation
	for i, layer := range fixtureLayers {
		for j := 0; j < perLayer; j++ {
			n := i*perLayer + j
			obs = append(obs, model.Observation{
				ID:             "fixture-" + strconv.Itoa(n),
				Timestamp:      base.Add(time.Duration(n) * time.Second),
				Layer:          layer,
				Fidelity:       model.FidelityStrong,
				Source:         "duckdb-runbook-fixture",
				Confidence:     0.8,
				ActorHint:      "arn:aws:iam::123456789012:user/agent-" + strconv.Itoa(i),
				RawEvidenceRef: "s3://customer-bucket/cloudtrail/" + strconv.Itoa(n) + ".json.gz",
				Description:    "fixture observation for the DuckDB last-resort runbook",
			})
		}
	}

	ctx := context.Background()
	if err := s.Append(ctx, obs); err != nil {
		t.Fatalf("Append: %v", err)
	}
	// Without this the rows sit in the active in-memory block and the directory holds no Parquet
	// object at all -- which is the mistake the runbook warns a reader about.
	if err := s.Flush(ctx); err != nil {
		t.Fatalf("Flush: %v", err)
	}

	// Assert what the runbook promises a reader will find, so a schema change that empties the
	// directory fails here rather than silently producing a runbook that cannot work.
	found, err := filepath.Glob(filepath.Join(dir, "*", "*", "*.parquet"))
	if err != nil {
		t.Fatal(err)
	}
	if len(found) == 0 {
		deep, _ := filepath.Glob(filepath.Join(dir, "*", "*", "*", "*.parquet"))
		found = append(found, deep...)
	}
	if len(found) == 0 {
		t.Fatalf("Flush wrote no .parquet under %s; the runbook's read_parquet glob would match nothing", dir)
	}
	t.Logf("wrote %d observations across %d layers; %d parquet object(s) under %s",
		len(obs), len(fixtureLayers), len(found), dir)
}
