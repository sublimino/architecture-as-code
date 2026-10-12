// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// liveSentinelGolden is the stun-sentinel wire contract (the same file
// signal-ingest's model/store sentinel-contract tests validate). It is the
// source of the live actor identity in the end-to-end scoping test below.
const liveSentinelGolden = "../../stun-sentinel/pkg/correlator/testdata/ingest-observation.golden.json"

// endpointBundlePath is the shipped Kusari endpoint-runtime bundle, four levels
// up from this package at the repo-root policy tree.
const endpointBundlePath = "../../../../policy/bundles/kusari/endpoint-runtime.yaml"

// testActorPseudonymiser is the real key ring over fixed key material, not a
// stub. The property under test is that the LIVE path and the REPLAY path agree
// on a value, and a stub that returned "pseudonym:"+v would make them agree for
// a reason the production key never supplies.
func testActorPseudonymiser(t *testing.T) *store.SegmentPseudonymiser {
	t.Helper()
	root, err := hex.DecodeString("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
	if err != nil {
		t.Fatalf("decoding the test key: %v", err)
	}
	p, err := store.NewSegmentPseudonymiser(root, store.DefaultSegmentTenantScope, 0)
	if err != nil {
		t.Fatalf("NewSegmentPseudonymiser: %v", err)
	}
	return p
}

const testActorARN = "arn:aws:iam::123456789012:user/kusari-builder"

// THE DEFECT, as a unit. A live observation carries a cleartext ActorHint; the
// SAME observation read back out of a segment-schema-v2 segment carries only
// HMACActorHint and an empty ActorHint. Both must project onto the same
// obs.actor, or every actor-reading rule and every actor-keyed window sees a
// different identity on replay than it saw live.
func TestActorIdentity_LiveAndReplayAgree(t *testing.T) {
	p := testActorPseudonymiser(t)
	want, err := p.Pseudonym(testActorARN)
	if err != nil {
		t.Fatalf("Pseudonym: %v", err)
	}
	if want == "" || want == testActorARN {
		t.Fatalf("the pseudonymiser returned %q for %q; the premise is gone", want, testActorARN)
	}

	live := &model.Observation{ID: "o1", ActorHint: testActorARN}
	replayed := &model.Observation{
		ID:            "o1",
		HMACActorHint: want,
	}

	gotLive, err := ActorIdentity(live, p)
	if err != nil {
		t.Fatalf("ActorIdentity(live): %v", err)
	}
	gotReplay, err := ActorIdentity(replayed, p)
	if err != nil {
		t.Fatalf("ActorIdentity(replayed): %v", err)
	}

	if gotLive != want {
		t.Errorf("live actor = %q, want the pseudonym %q", gotLive, want)
	}
	if gotReplay != want {
		t.Errorf("replayed actor = %q, want the pseudonym %q", gotReplay, want)
	}
	if gotLive != gotReplay {
		t.Errorf("live %q != replay %q: the pseudonymised-actor divergence is back", gotLive, gotReplay)
	}
}

// TestLiveSentinelStreamActorScopesUnexpectedExecve proves the full live chain:
// the stun-sentinel wire (the golden) carries actor_hint, signal-ingest
// pseudonymises it into a non-empty obs.actor (toObscel), and the endpoint
// unexpected-execve rule — whose allowed_exec_actors is pseudonymised with the
// SAME key (PseudonymiseActorVars) — is therefore scoped by the workload actor
// identity on the live stream. Before the actor_hint plumbing obs.actor was
// empty and the rule fired on every process_exec regardless of workload.
func TestLiveSentinelStreamActorScopesUnexpectedExecve(t *testing.T) {
	p := testActorPseudonymiser(t)

	// The live actor identity, read from the sentinel's own wire contract.
	raw, err := os.ReadFile(liveSentinelGolden)
	if err != nil {
		t.Fatalf("read the sentinel wire contract: %v", err)
	}
	var batch []model.Observation
	if err := json.Unmarshal(raw, &batch); err != nil {
		t.Fatalf("decode the sentinel wire contract: %v", err)
	}
	if len(batch) == 0 {
		t.Fatal("the sentinel wire contract holds no observations")
	}
	liveActor := batch[0].ActorHint
	if liveActor == "" {
		t.Fatal("the live sentinel wire carries no actor_hint; obs.actor would be empty and unexpected-execve would fire on every exec")
	}

	// obs.actor is the non-empty pseudonym of that hint.
	proj, err := toObscel(&batch[0], p)
	if err != nil {
		t.Fatalf("toObscel(live): %v", err)
	}
	wantPseudo, err := p.Pseudonym(liveActor)
	if err != nil {
		t.Fatalf("Pseudonym: %v", err)
	}
	if proj.Actor == "" || proj.Actor != wantPseudo {
		t.Fatalf("live obs.actor = %q, want the non-empty pseudonym %q of %q", proj.Actor, wantPseudo, liveActor)
	}

	ev, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatalf("NewEvaluator: %v", err)
	}

	// liveExec projects a live stun-sentinel process_exec in the aligned endpoint
	// label contract, with the given workload actor on actor_hint.
	liveExec := func(actorHint string) obscel.Observation {
		obs, err := toObscel(&model.Observation{
			ID:         "live-exec",
			Timestamp:  time.Unix(0, 0).UTC(),
			Layer:      model.LayerEndpointHost,
			Source:     "stun-sentinel",
			Fidelity:   model.FidelityStrong,
			Confidence: 0.95,
			ActorHint:  actorHint,
			Labels: map[string]string{
				TenantLabel:      "kusari",
				"classification": "process_exec",
				"syscall":        "sys_enter_execve",
			},
		}, p)
		if err != nil {
			t.Fatalf("toObscel(exec): %v", err)
		}
		return obs
	}

	// loadEndpointBundle loads the shipped bundle and pseudonymises its
	// allowed_exec_actors with the SAME key obs.actor is pseudonymised with, as
	// the live load path does. extraAllowed names cleartext actors to exempt.
	loadEndpointBundle := func(extraAllowed ...string) *obscel.Bundle {
		b, err := obscel.LoadBundleFile(endpointBundlePath)
		if err != nil {
			t.Fatalf("LoadBundleFile: %v", err)
		}
		if len(extraAllowed) > 0 {
			b.Vars["allowed_exec_actors"] = append(b.Vars["allowed_exec_actors"], extraAllowed...)
		}
		if err := obscel.PseudonymiseActorVars(b, p.Pseudonym); err != nil {
			t.Fatalf("PseudonymiseActorVars: %v", err)
		}
		return b
	}

	fired := func(b *obscel.Bundle, obs obscel.Observation) bool {
		findings, err := ev.EvaluateObservation(obs, b)
		if err != nil {
			t.Fatalf("EvaluateObservation: %v", err)
		}
		for _, f := range findings {
			if f.RuleID == "unexpected-execve" {
				return true
			}
		}
		return false
	}

	// POSITIVE: the live actor is not in the shipped allow-list -> fires.
	if !fired(loadEndpointBundle(), liveExec(liveActor)) {
		t.Error("unexpected-execve did not fire for a non-allowlisted live actor; the live stream is unscoped")
	}
	// NEGATIVE: exempt the live actor (cleartext) — after pseudonymisation its
	// value equals obs.actor, so the rule must NOT fire.
	if fired(loadEndpointBundle(liveActor), liveExec(liveActor)) {
		t.Error("unexpected-execve fired for an allow-listed live actor; the pseudonymised scope is not matching obs.actor")
	}
}

// An observation that names no actor projects an empty actor, NOT the pseudonym
// of "". A VPC Flow record names no principal, and a constant digest in that
// position would be a join key linking every identity-free record to every
// other -- and would make `obs.actor != ""` true for all of them, which is the
// guard two shipped rules rely on.
func TestActorIdentity_NoActorStaysEmpty(t *testing.T) {
	p := testActorPseudonymiser(t)
	got, err := ActorIdentity(&model.Observation{ID: "flow"}, p)
	if err != nil {
		t.Fatalf("ActorIdentity: %v", err)
	}
	if got != "" {
		t.Errorf("an actorless observation projected actor %q, want empty", got)
	}
}

// A v1 segment still carries cleartext, and it must pseudonymise to exactly the
// value a v2 segment would have stored -- otherwise a corpus spanning the schema
// change (the documented steady state) counts one identity as two.
func TestActorIdentity_V1CleartextMatchesV2Pseudonym(t *testing.T) {
	p := testActorPseudonymiser(t)
	v2, err := p.Pseudonym(testActorARN)
	if err != nil {
		t.Fatalf("Pseudonym: %v", err)
	}
	got, err := ActorIdentity(&model.Observation{ID: "o1", ActorHint: testActorARN}, p)
	if err != nil {
		t.Fatalf("ActorIdentity: %v", err)
	}
	if got != v2 {
		t.Errorf("v1 cleartext projected %q, v2 pseudonym is %q", got, v2)
	}
}

// toObscel puts the pseudonym on obs.actor, which is the field every bundle rule
// reads.
func TestToObscel_ActorIsThePseudonym(t *testing.T) {
	p := testActorPseudonymiser(t)
	want, _ := p.Pseudonym(testActorARN)

	got, err := toObscel(&model.Observation{
		ID:        "o1",
		Timestamp: time.Unix(0, 0).UTC(),
		ActorHint: testActorARN,
		Labels:    map[string]string{TenantLabel: "kusari"},
	}, p)
	if err != nil {
		t.Fatalf("toObscel: %v", err)
	}
	if got.Actor != want {
		t.Errorf("toObscel actor = %q, want the pseudonym %q", got.Actor, want)
	}
	if got.Actor == testActorARN {
		t.Error("toObscel put the cleartext ARN on obs.actor")
	}
}

// A stored finding carries the pseudonym in its `actor` label.
//
// ActorHint on the derived observation is not enough on its own: under FrostDB
// v2 the store pseudonymises it again on write and the read path returns no
// cleartext, so warm-up could not recover an actor at all and every actor-keyed
// window would collapse into one counter after a restart. The label round-trips.
func TestFindingObservation_CarriesThePseudonymAsALabel(t *testing.T) {
	p := testActorPseudonymiser(t)
	pseudo, _ := p.Pseudonym(testActorARN)

	src := &model.Observation{ID: "o1", Layer: model.LayerCloudControlPlane, Fidelity: model.FidelityStrong}
	f := obscel.Finding{
		ID: "f1", Timestamp: time.Unix(0, 0).UTC(), TenantID: "kusari",
		Actor: pseudo, RuleID: "r", BundleID: "b", BundleVersion: "1.0.0", Severity: "high",
		SourceObsID: "o1",
	}

	fo := findingObservation(f, src, obscel.ModeShadow, nil)
	if got := fo.Labels[LabelActor]; got != pseudo {
		t.Errorf("stored finding %s label = %q, want the pseudonym %q", LabelActor, got, pseudo)
	}
	for _, v := range fo.Labels {
		if v == testActorARN {
			t.Error("a stored finding label carries the cleartext ARN")
		}
	}

	// And it round-trips, which is what warm-up depends on.
	back := findingFromObservation(fo)
	if back.Actor != pseudo {
		t.Errorf("findingFromObservation recovered actor %q, want %q", back.Actor, pseudo)
	}
}

// A stored decision carries it too, for the same reason.
func TestDecisionObservation_CarriesThePseudonymAsALabel(t *testing.T) {
	p := testActorPseudonymiser(t)
	pseudo, _ := p.Pseudonym(testActorARN)

	trigger := &model.Observation{ID: "o1", Layer: model.LayerCloudControlPlane, Fidelity: model.FidelityStrong}
	do := decisionObservation(obscel.Decision{
		ID: "d1", Timestamp: time.Unix(0, 0).UTC(), TenantID: "kusari", Actor: pseudo,
		WindowID: "w", RuleID: "r", BundleID: "b", BundleVersion: "1.0.0",
		Severity: "high", Mode: obscel.ModeShadow, FindingIDs: []string{"f1"}, Count: 1,
	}, trigger)

	if got := do.Labels[LabelActor]; got != pseudo {
		t.Errorf("stored decision %s label = %q, want the pseudonym %q", LabelActor, got, pseudo)
	}
}

// The value under LabelActor is always a keyed pseudonym, never cleartext.
//
// This assertion lives HERE, at the writer, because it cannot live anywhere
// else. The segment allow-list bounds label KEYS and never VALUES, so nothing
// downstream can check that `actor_pseudonym` holds a pseudonym; the store will
// write whatever it is handed. Policy is the only writer of this key, so this is
// the one place the claim is checkable -- and the claim is what justifies
// admitting the key to the allow-list at all.
func TestFindingObservation_ActorPseudonymLabelIsAPseudonym(t *testing.T) {
	p := testActorPseudonymiser(t)
	obs := &model.Observation{
		ID:        "o1",
		Timestamp: time.Unix(0, 0).UTC(),
		ActorHint: testActorARN,
		Labels:    map[string]string{TenantLabel: "kusari"},
	}
	projected, err := toObscel(obs, p)
	if err != nil {
		t.Fatalf("toObscel: %v", err)
	}
	fo := findingObservation(obscel.Finding{
		ID: "f1", Timestamp: obs.Timestamp, TenantID: "kusari", Actor: projected.Actor,
		RuleID: "r", BundleID: "b", BundleVersion: "1.0.0", Severity: "high", SourceObsID: "o1",
	}, obs, obscel.ModeShadow, nil)

	got := fo.Labels[LabelActor]
	if len(got) != 64 {
		t.Fatalf("%s = %q (%d chars), want a 64-character hex pseudonym", LabelActor, got, len(got))
	}
	if _, err := hex.DecodeString(got); err != nil {
		t.Errorf("%s = %q, which is not hex: %v", LabelActor, got, err)
	}
	if strings.Contains(got, "arn:") || strings.Contains(got, "@") {
		t.Errorf("%s = %q looks like a direct identifier", LabelActor, got)
	}
}
