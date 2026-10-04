//go:build frostdb

package awslogs_test

import (
	"context"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// kind-osramp, SLAWS P4-GOV: the first fixture observation was refused by the FrostDB
// segment label allow-list ("resource_name" not allowed) and the collector failed to
// start. Every awslogs fixture must append to the configured durable store, so the
// §2.3 label contract and the allow-list can never drift apart again.
func TestEveryAWSLogsFixtureAppendsToFrostDB(t *testing.T) {
	obs, err := awslogs.FixtureObservations("kusari", "eu-west-2")
	if err != nil {
		t.Fatalf("FixtureObservations: %v", err)
	}
	if len(obs) == 0 {
		t.Fatal("no fixture observations")
	}
	// The segment store fails closed without a pseudonymisation key (the same contract
	// that stopped the kind-osramp pod); supply test key material as store's TestMain does.
	t.Setenv(store.SegmentPseudonymKeyEnv, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
	st, err := store.NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer st.Close()
	if err := st.Append(context.Background(), obs); err != nil {
		t.Fatalf("FrostDB refused the awslogs fixture corpus (%d observations): %v", len(obs), err)
	}
}
