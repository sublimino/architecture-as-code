// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"context"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// sourceIPBundle keys a window on a SOURCE-OBSERVATION label, which is the case
// the closed policy label set could not round-trip. It mirrors
// cloud-signals.yaml's vpc-reject-burst-5m, which documents the limit this
// change removes.
func sourceIPBundle(t *testing.T) *obscel.Bundle {
	t.Helper()
	b := &obscel.Bundle{
		ID: "test-flow", TenantID: testTenant, Version: "1.0.0", Mode: obscel.ModeShadow,
		Rules: []obscel.Rule{{
			ID: "vpc-reject", Name: "rejected egress", Severity: "low",
			Expression: `obs.layer == "network_egress" && has(obs.labels.event_name) && obs.labels.event_name == "REJECT"`,
		}},
		Windows: []obscel.Window{{
			ID:       "reject-burst",
			OverRule: "vpc-reject",
			Key:      []string{obscel.KeyTenantID, obscel.KeyLabelPrefix + "source_ip"},
			Window:   5 * time.Minute, Threshold: 3, Severity: "medium",
		}},
	}
	if errs := obscel.Conform(b); len(errs) > 0 {
		t.Fatalf("fixture bundle is not conformant: %v", obscel.JoinRuleErrors(errs))
	}
	return b
}

func flowObs(id string, at time.Time, sourceIP string) *model.Observation {
	return &model.Observation{
		ID: id, Timestamp: at, Layer: model.LayerNetworkEgress,
		Fidelity: model.FidelityStrong, Source: "aws:vpcflow", Confidence: 0.9,
		Labels: map[string]string{TenantLabel: testTenant, "event_name": "REJECT", "source_ip": sourceIP},
	}
}

// KeyedLabelKeys reports exactly the labels.<k> dimensions, and nothing else.
func TestWindows_KeyedLabelKeys(t *testing.T) {
	b := sourceIPBundle(t)
	got := NewWindows([]*obscel.Bundle{b}).KeyedLabelKeys("vpc-reject", b)
	if len(got) != 1 || got[0] != "source_ip" {
		t.Errorf("KeyedLabelKeys = %v, want [source_ip]", got)
	}
	// tenant_id and actor are key dimensions too, but they are NOT label
	// dimensions and the closed policy set already carries both. Copying them
	// as labels would duplicate them under a second name.
	if n := len(NewWindows([]*obscel.Bundle{testBundle(t, obscel.ModeShadow)}).
		KeyedLabelKeys("iam-priv-change", testBundle(t, obscel.ModeShadow))); n != 0 {
		t.Errorf("a [tenant_id, actor] window reported %d keyed label keys, want 0", n)
	}
}

// THE DEFECT, as a unit. A window keyed on labels.source_ip must rebuild at
// warm-up with ONE COUNTER PER ADDRESS.
//
// Before this change the stored finding carried the closed policy label set
// only, so every warmed finding read an empty source_ip and collapsed into a
// single counter: twenty hosts each retrying once warmed as one host scanning
// twenty times, and a pod could come up already over threshold on evidence that
// is nothing of the kind. cloud-signals.yaml's vpc-reject-burst-5m names this
// limit and names policy/convert.go as the fix.
//
// The assertion is behavioural, not a count of map entries: after warm-up, two
// findings from .9 plus one more must cross a threshold of 3, while .8's single
// warmed finding must NOT have contributed to that counter.
func TestWindows_WarmRebuildsALabelKeyedWindowPerValue(t *testing.T) {
	ctx := context.Background()
	st := store.NewMemoryStore()
	b := sourceIPBundle(t)

	// Two findings from .9 and one from .8, stored the way the live path stores
	// them -- through findingObservation with the window's keyed dimensions.
	keyed := NewWindows([]*obscel.Bundle{b}).KeyedLabelKeys("vpc-reject", b)
	var rows []model.Observation
	for _, spec := range []struct {
		id, ip string
		offset time.Duration
	}{
		{"o-9a", "10.0.9.9", 0},
		{"o-9b", "10.0.9.9", time.Minute},
		{"o-8a", "10.0.8.8", 2 * time.Minute},
	} {
		src := flowObs(spec.id, baseTime.Add(spec.offset), spec.ip)
		projected, err := toObscel(src, nil)
		if err != nil {
			t.Fatalf("toObscel: %v", err)
		}
		f := obscel.NewFinding(projected, b, b.Rules[0])
		rows = append(rows, findingObservation(f, src, b.Mode, keyed))
	}
	if err := st.Append(ctx, rows); err != nil {
		t.Fatalf("Append: %v", err)
	}

	// A fresh process warms from the store.
	ws := NewWindows([]*obscel.Bundle{b})
	if err := ws.Warm(ctx, st, baseTime.Add(3*time.Minute)); err != nil {
		t.Fatalf("Warm: %v", err)
	}
	if n := ws.WarmedCount(); n != 3 {
		t.Fatalf("warm-up folded in %d findings, want 3", n)
	}

	// One more REJECT from .9 takes ITS counter to 3 and fires.
	srcNext := flowObs("o-9c", baseTime.Add(3*time.Minute), "10.0.9.9")
	projected, err := toObscel(srcNext, nil)
	if err != nil {
		t.Fatalf("toObscel: %v", err)
	}
	decisions := ws.Offer(obscel.NewFinding(projected, b, b.Rules[0]), b)
	if len(decisions) != 1 {
		t.Fatalf("a third REJECT from 10.0.9.9 produced %d decisions, want 1; "+
			"the warmed counter for that address was not rebuilt", len(decisions))
	}
	if got := decisions[0].Count; got != 3 {
		t.Errorf("decision count = %d, want 3: only 10.0.9.9's findings may be in this counter, "+
			"not 10.0.8.8's (which would make it 4 and is the collapsed-counter defect)", got)
	}
}

// THE MUTATION. Drop the keyed label values from the stored finding -- exactly
// the pre-change behaviour -- and warm-up stops working for this window
// entirely.
//
// The failure is worse than "the counters merge", which is how
// cloud-signals.yaml and the old Warm comment both described it. Every warmed
// finding reads an empty source_ip, so they all land in the counter keyed
// `source_ip=`, a key NO LIVE FINDING WILL EVER HAVE. So the live counter for
// 10.0.9.9 starts from zero and the third REJECT does not fire at all -- warm-up
// contributed nothing -- while the phantom empty-keyed counter sits latched
// above its threshold. The restart therefore MISSES the burst it was warmed to
// catch, which is the opposite direction from the "could fire early" the bundle
// comment predicted.
//
// Asserted rather than described, because "the fix works" and "the fix is
// load-bearing" are different claims and only this one shows the mechanism is
// what produces the behaviour above.
func TestWindows_WarmCollapsesWithoutTheKeyedLabels(t *testing.T) {
	ctx := context.Background()
	st := store.NewMemoryStore()
	b := sourceIPBundle(t)

	var rows []model.Observation
	for _, spec := range []struct {
		id, ip string
		offset time.Duration
	}{
		{"o-9a", "10.0.9.9", 0},
		{"o-9b", "10.0.9.9", time.Minute},
		{"o-8a", "10.0.8.8", 2 * time.Minute},
	} {
		src := flowObs(spec.id, baseTime.Add(spec.offset), spec.ip)
		projected, err := toObscel(src, nil)
		if err != nil {
			t.Fatalf("toObscel: %v", err)
		}
		// nil keyed labels: the mutation.
		rows = append(rows, findingObservation(obscel.NewFinding(projected, b, b.Rules[0]), src, b.Mode, nil))
	}
	if err := st.Append(ctx, rows); err != nil {
		t.Fatalf("Append: %v", err)
	}

	ws := NewWindows([]*obscel.Bundle{b})
	if err := ws.Warm(ctx, st, baseTime.Add(3*time.Minute)); err != nil {
		t.Fatalf("Warm: %v", err)
	}
	// All three findings warmed -- they simply warmed under the wrong key. That
	// is what makes the miss silent: the warm-up metric reports three findings
	// folded in and the burst is still missed. Checked BEFORE the live offer,
	// which would otherwise add its own entry to the total.
	if n := ws.WarmedCount(); n != 3 {
		t.Fatalf("WarmedCount = %d, want 3", n)
	}
	if n := ws.WarmedMissingKeyedLabels(); n != 3 {
		t.Errorf("WarmedMissingKeyedLabels = %d, want 3: this is the only signal an operator gets", n)
	}

	srcNext := flowObs("o-9c", baseTime.Add(3*time.Minute), "10.0.9.9")
	projected, err := toObscel(srcNext, nil)
	if err != nil {
		t.Fatalf("toObscel: %v", err)
	}
	decisions := ws.Offer(obscel.NewFinding(projected, b, b.Rules[0]), b)
	if len(decisions) != 0 {
		t.Fatalf("the third REJECT from 10.0.9.9 fired %d decisions without the keyed labels; "+
			"the mutation no longer reproduces, so the test above proves nothing about the mechanism",
			len(decisions))
	}
}

// Warm reports how many warmed findings were MISSING a keyed dimension, rather
// than warning up front that the dimension cannot be rebuilt at all. The blanket
// warning was correct before findings carried these values and is now wrong: it
// would fire on every boot of a correctly-functioning window.
func TestWindows_WarmCountsMissingKeyedLabelsRatherThanWarningAlways(t *testing.T) {
	ctx := context.Background()
	st := store.NewMemoryStore()
	b := sourceIPBundle(t)
	keyed := NewWindows([]*obscel.Bundle{b}).KeyedLabelKeys("vpc-reject", b)

	src := flowObs("o-1", baseTime, "10.0.9.9")
	projected, err := toObscel(src, nil)
	if err != nil {
		t.Fatalf("toObscel: %v", err)
	}
	good := findingObservation(obscel.NewFinding(projected, b, b.Rules[0]), src, b.Mode, keyed)

	// A finding stored by an older binary: no keyed label on it.
	old := findingObservation(obscel.NewFinding(projected, b, b.Rules[0]), src, b.Mode, nil)
	old.ID = "legacy-1"

	if err := st.Append(ctx, []model.Observation{good, old}); err != nil {
		t.Fatalf("Append: %v", err)
	}

	ws := NewWindows([]*obscel.Bundle{b})
	if err := ws.Warm(ctx, st, baseTime.Add(time.Minute)); err != nil {
		t.Fatalf("Warm: %v", err)
	}
	if got := ws.WarmedMissingKeyedLabels(); got != 1 {
		t.Errorf("WarmedMissingKeyedLabels = %d, want 1 (the legacy row only)", got)
	}
}
