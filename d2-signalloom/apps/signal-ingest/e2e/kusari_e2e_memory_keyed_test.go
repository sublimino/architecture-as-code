package e2e

import (
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// A keyed MemoryStore (SLCO-P2-3) pseudonymises identifiers at rest. Replay must still reproduce
// live over it, which holds only if the policy path takes the store's pseudonymiser, so live
// evaluates obs.actor and the bundles' allowlists in the same pseudonym space replay reads back.
// Without it the two disagree by five findings on this corpus.
func TestKusariE2E_KeyedMemoryStoreReplayReproducesLive(t *testing.T) {
	t.Setenv(store.SegmentPseudonymKeyEnv, testPseudonymKeyMemory)
	TestKusariE2E_ReplayReproducesLive(t)
}

func TestKusariSynth_KeyedMemoryStoreReplayReproducesLive(t *testing.T) {
	t.Setenv(store.SegmentPseudonymKeyEnv, testPseudonymKeyMemory)
	TestKusariSynth_ReplayReproducesLiveOverTheCombinedCorpus(t)
}

const testPseudonymKeyMemory = "4242424242424242424242424242424242424242424242424242424242424242"
