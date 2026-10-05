// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

import (
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs/synth"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// The synthetic stream through the same production chain.
//
// The fixture suite answers "does each rule fire on the record it was written
// for". These answer the two questions a fixture cannot: does a rule stay quiet
// in VOLUME, and does a window fire on a burst nobody hand-placed.

// Seed, span and rate for the suite. Fixed so a failure is reproducible from the
// test name alone; synth.Generate is a pure function of these.
const (
	synthSeed    = 20261004
	synthMinutes = 120
	synthRate    = 25
)

func synthCorpus(t *testing.T, profile synth.Profile) ([]model.Observation, []synth.Burst) {
	t.Helper()
	s, err := synth.Generate(synthSeed, synthMinutes, synthRate, profile)
	if err != nil {
		t.Fatalf("synth.Generate(%s): %v", profile, err)
	}
	obs, err := s.Observations(Tenant, Region)
	if err != nil {
		t.Fatalf("Observations: %v", err)
	}
	if len(obs) == 0 {
		t.Fatalf("profile %s projected to nothing", profile)
	}
	return obs, s.Bursts
}

// THE FALSE-POSITIVE GATE. Three thousand benign records produce ZERO findings.
//
// This is the assertion the fixtures structurally cannot make. Every rule in
// both shipped bundles is an allowlist-shaped negative, so a rule that is one
// event name too broad does not look wrong on a seven-record fixture — it looks
// wrong here, as a finding against ListUsers or GetBucketPolicy.
//
// It is also the assertion most likely to go red for a GOOD reason: widening a
// rule to cover a new API is normal, and the fix is then one line in synth's
// benignEvents pool plus a deliberate look at whether the widening was right.
func TestKusariSynth_BaselineProducesNoFindings(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(1<<16))
	c, bursts := synthCorpus(t, synth.ProfileBaseline)
	if len(bursts) != 0 {
		t.Fatalf("the baseline profile injected %d bursts", len(bursts))
	}
	ingest(t, h, c)

	if n := len(h.Recorder.Findings); n != 0 {
		byRule := h.Recorder.FindingsByRule()
		t.Fatalf("%d benign records produced %d findings: %v\nthis is a false-positive rate, not a fixture mismatch",
			len(c), n, byRule)
	}
	if n := len(h.Recorder.Decisions); n != 0 {
		t.Fatalf("the baseline produced %d decisions", n)
	}
	// And it really did ingest: a gate that passes because nothing arrived is
	// the same gate as no gate.
	census := Census(rows(t, h))
	if census.Observations != len(c) {
		t.Fatalf("stored %d of %d benign observations", census.Observations, len(c))
	}
	t.Logf("false-positive gate: %d benign records over %d minutes at %d/min produced 0 findings",
		len(c), synthMinutes, synthRate)
}

// Each attack profile's burst crosses exactly the window its manifest names, and
// crosses no other.
//
// The bursts are injected into generated noise, so the arrival interleaving is
// whatever the seed produced rather than something a fixture author chose. That
// is the point: a window that only fires when its findings arrive contiguously
// would pass the fixture suite and fail here.
func TestKusariSynth_EachBurstCrossesItsWindow(t *testing.T) {
	for _, profile := range []synth.Profile{
		synth.ProfileIAMBurst, synth.ProfileRejectBurst, synth.ProfileCrossAccount,
	} {
		t.Run(string(profile), func(t *testing.T) {
			h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(1<<16))
			c, bursts := synthCorpus(t, profile)
			if len(bursts) != 1 {
				t.Fatalf("profile %s injected %d bursts, want 1", profile, len(bursts))
			}
			ingest(t, h, c)

			b := bursts[0]
			byWindow := h.Recorder.DecisionsByWindow()
			if got := byWindow[bundleCloudSignals+"/"+b.Window]; got != 1 {
				t.Errorf("burst %s produced %d %s decisions, want 1 (all windows: %v)",
					b.Kind, got, b.Window, byWindow)
			}
			// Nothing else fired. A burst that crosses a window it was not aimed
			// at means two windows are counting the same evidence.
			for key, n := range byWindow {
				if key != bundleCloudSignals+"/"+b.Window && n != 0 {
					t.Errorf("burst %s also crossed %s (%d decisions); the windows are not disjoint over this evidence",
						b.Kind, key, n)
				}
			}
			// The stage-1 rule the burst names fired at least as many times as
			// records were injected, which is what the window counted.
			if got := h.Recorder.FindingsByRule()[bundleCloudSignals+"/"+b.Rule]; got < b.Records {
				t.Errorf("burst %s injected %d records but rule %s produced %d findings",
					b.Kind, b.Records, b.Rule, got)
			}
			t.Logf("%s: %d injected records crossed %s in a stream of %d", b.Kind, b.Records, b.Window, len(c))
		})
	}
}

// Replay equals live over the combined corpus: fixtures plus a full-attack
// synthetic stream, roughly three thousand records.
//
// The fixture-only equality test proves the mechanism. This proves it at volume
// and across the interleaving of two independently-generated corpora, which is
// where an ordering assumption in stage 2 would show up.
func TestKusariSynth_ReplayReproducesLiveOverTheCombinedCorpus(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(1<<16))
	synthObs, bursts := synthCorpus(t, synth.ProfileAll)
	combined := append(corpus(t), synthObs...)
	ingest(t, h, combined)

	live := h.Recorder.CanonicalLines()
	if len(live) == 0 {
		t.Fatal("the combined run recorded nothing")
	}
	// Every burst plus every fixture window fired, so the comparison is over a
	// corpus that actually exercised both stages.
	if got := len(h.Recorder.Decisions); got < len(bursts)+wantKusariDecisions {
		t.Fatalf("the combined corpus produced %d decisions, want at least %d fixture + %d burst",
			got, wantKusariDecisions, len(bursts))
	}

	replayed := replayLines(t, h, combined)
	if len(replayed) != len(live) {
		t.Fatalf("replay wrote %d canonical lines over the combined corpus, live recorded %d", len(replayed), len(live))
	}
	for i := range live {
		if live[i] != replayed[i] {
			t.Fatalf("replay diverged at line %d of %d\n  live:   %s\n  replay: %s", i, len(live), live[i], replayed[i])
		}
	}
	t.Logf("replay equals live over %d records: %d canonical lines (%d findings, %d decisions)",
		len(combined), len(live), len(h.Recorder.Findings), len(h.Recorder.Decisions))
}

// A second pass of the combined corpus changes nothing, at volume.
func TestKusariSynth_SecondPassOfTheCombinedCorpusIsANoOp(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(1<<16))
	synthObs, _ := synthCorpus(t, synth.ProfileAll)
	combined := append(corpus(t), synthObs...)

	ingest(t, h, combined)
	first := Census(rows(t, h))
	firstFindings := len(h.Recorder.Findings)
	firstDecisions := len(h.Recorder.Decisions)

	ingest(t, h, combined)

	if second := Census(rows(t, h)); first != second {
		t.Errorf("the second pass changed the store: %+v -> %+v", first, second)
	}
	if got := len(h.Recorder.Findings); got != firstFindings {
		t.Errorf("stage 1 evaluated %d findings over two passes, want %d", got, firstFindings)
	}
	if got := len(h.Recorder.Decisions); got != firstDecisions {
		t.Errorf("stage 2 produced %d decisions over two passes, want %d: a burst was reached by a redelivery", got, firstDecisions)
	}
	if h.Deduper.Dropped() != uint64(len(combined)) {
		t.Errorf("the deduper refused %d of %d replayed records", h.Deduper.Dropped(), len(combined))
	}
	if h.Deduper.Evicted() != 0 {
		t.Errorf("the deduper evicted %d IDs at this volume; the capacity in this test is too small and the no-op claim is weakened",
			h.Deduper.Evicted())
	}
}

// Determinism, end to end: the same seed through the whole pipeline produces the
// same canonical output.
//
// synth's own test asserts byte-identical OBJECTS. This asserts identical
// FINDINGS AND DECISIONS, which is the claim an operator cares about and which
// also covers the projection and both policy stages.
func TestKusariSynth_SameSeedProducesTheSameDetections(t *testing.T) {
	run := func() []string {
		h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(1<<16))
		obs, _ := synthCorpus(t, synth.ProfileAll)
		ingest(t, h, obs)
		return h.Recorder.CanonicalLines()
	}
	a, b := run(), run()
	if len(a) == 0 {
		t.Fatal("the stream produced no detections; equality would be vacuous")
	}
	if len(a) != len(b) {
		t.Fatalf("two runs at seed %d produced %d and %d canonical lines", synthSeed, len(a), len(b))
	}
	for i := range a {
		if a[i] != b[i] {
			t.Fatalf("two runs at seed %d diverged at line %d\n  %s\n  %s", synthSeed, i, a[i], b[i])
		}
	}
	t.Logf("seed %d is reproducible end to end: %d canonical lines", synthSeed, len(a))
}
