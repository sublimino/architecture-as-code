// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// fakeDecisionDispatcher records every (decision, trigger) the Sink routes to it.
type fakeDecisionDispatcher struct {
	decisions []obscel.Decision
	triggers  []model.Observation
}

func (f *fakeDecisionDispatcher) Dispatch(_ context.Context, d obscel.Decision, trigger model.Observation) {
	f.decisions = append(f.decisions, d)
	f.triggers = append(f.triggers, trigger)
}

// The production wire for policy-failure→stun: a decision emitted by the Sink is
// offered to the DecisionDispatcher together with its triggering observation,
// and it fires in SHADOW mode too (the dispatch is before the mode gate — a
// Landlock-denial stun must not wait for the bundle to be promoted). Without the
// emitDecision wire this test sees zero decisions and zero triggers.
func TestSink_RoutesDecisionToDispatcherInShadow(t *testing.T) {
	b := testBundle(t, obscel.ModeShadow)
	windows := NewWindows([]*obscel.Bundle{b})
	fake := &fakeDecisionDispatcher{}

	sink := NewSink(&recordingSink{}, newSpyStore(t), newTestEvaluator(t), bundlesFor(b),
		Options{Windows: windows})
	sink.(*Sink).SetDecisionDispatcher(fake)

	// testBundle's window fires at threshold 3; feed three qualifying events.
	for i := range 3 {
		at := baseTime.Add(time.Duration(i) * time.Minute)
		obs := iamObs(fmt.Sprintf("obs-%d", i), at, "arn:aws:iam::1:user/agent", "AttachUserPolicy")
		if err := sink.IngestObservation(context.Background(), obs); err != nil {
			t.Fatalf("IngestObservation(%d): %v", i, err)
		}
	}

	if len(fake.decisions) != 1 {
		t.Fatalf("dispatcher saw %d decisions, want exactly 1 (the window decision)", len(fake.decisions))
	}
	if len(fake.triggers) != 1 || fake.triggers[0].ID == "" {
		t.Fatalf("dispatcher received no triggering observation (%+v) — pod identity would be lost", fake.triggers)
	}
	if fake.decisions[0].WindowID == "" {
		t.Fatalf("routed decision has no WindowID: %+v", fake.decisions[0])
	}
}

// A Sink with no dispatcher set must not panic and must still emit decisions
// (the route is optional; nil is today's default when no stun client exists).
func TestSink_NoDispatcherIsSafe(t *testing.T) {
	b := testBundle(t, obscel.ModeWarn)
	inner := &recordingSink{}
	sink := NewSink(inner, newSpyStore(t), newTestEvaluator(t), bundlesFor(b),
		Options{Windows: NewWindows([]*obscel.Bundle{b})})
	for i := range 3 {
		at := baseTime.Add(time.Duration(i) * time.Minute)
		obs := iamObs(fmt.Sprintf("obs-%d", i), at, "arn:aws:iam::1:user/agent", "AttachUserPolicy")
		if err := sink.IngestObservation(context.Background(), obs); err != nil {
			t.Fatalf("IngestObservation(%d): %v", i, err)
		}
	}
	if n := len(inner.bySource(obscel.SourceDecision)); n != 1 {
		t.Fatalf("with no dispatcher the Sink produced %d decisions, want 1", n)
	}
}
