// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs_test

import (
	"context"
	"slices"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
)

// The fixture SET selects what fixture mode replays. The default set is
// FixtureFiles() and nothing else, so the default replay path and every total the
// contract tests assert over it are unchanged. The kusari set appends the Kusari
// pilot corpus, burst records included, so a cluster running fixture mode can
// produce stage-2 decisions without anyone hand-placing a burst.

// FixtureFiles is the default replay set and stays exactly four objects. The
// Kusari corpus, and the burst records in particular, are opt-in through the
// kusari set; moving them in here would shift every count contract_test.go and
// policy/e2e_fixture_test.go assert. A change to this list is deliberate.
func TestFixtureFiles_DefaultSetIsPinned(t *testing.T) {
	want := []string{awslogs.FixtureCloudTrail, awslogs.FixtureIAM, awslogs.FixtureVPCFlow, awslogs.FixturePoisoned}
	if got := awslogs.FixtureFiles(); !slices.Equal(got, want) {
		t.Fatalf("FixtureFiles() = %v, want %v", got, want)
	}
}

func TestFixtureSetFiles(t *testing.T) {
	for _, set := range []string{"", awslogs.FixtureSetDefault} {
		got, err := awslogs.FixtureSetFiles(set)
		if err != nil {
			t.Fatalf("FixtureSetFiles(%q): %v", set, err)
		}
		if !slices.Equal(got, awslogs.FixtureFiles()) {
			t.Errorf("FixtureSetFiles(%q) = %v, want FixtureFiles()", set, got)
		}
	}

	got, err := awslogs.FixtureSetFiles(awslogs.FixtureSetKusari)
	if err != nil {
		t.Fatalf("FixtureSetFiles(kusari): %v", err)
	}
	want := append(awslogs.FixtureFiles(), awslogs.KusariFixtureFiles()...)
	if !slices.Equal(got, want) {
		t.Fatalf("FixtureSetFiles(kusari) = %v, want FixtureFiles()+KusariFixtureFiles()", got)
	}
	for _, burst := range []string{awslogs.KusariFixtureIAMBurst, awslogs.KusariFixtureVPCRejectBurst} {
		if !slices.Contains(got, burst) {
			t.Errorf("the kusari set does not replay %s; stage 2 has no burst to count", burst)
		}
	}
	// INVERTED AT MERGE, because its premise stopped being true.
	//
	// This assertion required the EventBridge envelope to be ABSENT, on the
	// grounds that it "projects to nothing by design". That was correct when
	// written: there was no GuardDuty projector, so replaying the envelope added
	// a fixture that contributed no observations and silently skewed any
	// count-based stage assertion.
	//
	// The projector now exists. fixtures_kusari.go:39-44 describes the envelope
	// as "projected by ProjectGuardDuty: the positive for
	// guardduty-high-severity", and
	// TestKusariFixtures_EventBridgeEnvelopeProjectsToAGuardDutyObservation
	// passes, which is the positive evidence rather than the comment. So the
	// envelope now belongs in the set, and excluding it would drop the only
	// high-severity GuardDuty positive from the replay.
	//
	// Two sides of one merge each held half of this: the fixture list came from
	// the line that built the projector, the assertion from the line that
	// predated it. Git merged both without noticing they disagreed, which is why
	// the suite went red on a tree where each half was correct alone.
	if !slices.Contains(got, awslogs.KusariFixtureEventBridgeEnvelope) {
		t.Error("the kusari set does not replay the EventBridge envelope; " +
			"guardduty-high-severity then has no positive to fire on")
	}

	if _, err := awslogs.FixtureSetFiles("everything"); err == nil {
		t.Fatal("an unknown fixture set was accepted; it must refuse rather than fall back to a default")
	}
}

func TestCollector_FixtureModeKusariSetReplaysTheBurstRecords(t *testing.T) {
	sink := &orderedSink{}
	cfg := awslogs.AWSCollectorConfig{TenantID: "kusari", FixtureSet: awslogs.FixtureSetKusari}
	c, err := awslogs.New(cfg, sink, awslogs.WithMode(string(awslogs.ModeFixture)))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := c.Start(context.Background()); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer c.Stop()

	def, err := awslogs.FixtureObservations("kusari", "us-east-1")
	if err != nil {
		t.Fatalf("FixtureObservations: %v", err)
	}
	kus, err := awslogs.KusariFixtureObservations("kusari", "us-east-1")
	if err != nil {
		t.Fatalf("KusariFixtureObservations: %v", err)
	}
	if want := len(def) + len(kus); len(sink.obs) != want {
		t.Fatalf("kusari fixture set ingested %d observations, want %d (%d default + %d kusari)",
			len(sink.obs), want, len(def), len(kus))
	}

	seen := map[string]int{}
	for _, o := range sink.obs {
		ref, _, _ := strings.Cut(o.RawEvidenceRef, "#")
		seen[ref]++
	}
	for _, burst := range []string{awslogs.KusariFixtureIAMBurst, awslogs.KusariFixtureVPCRejectBurst} {
		if seen["testdata/"+burst] == 0 {
			t.Errorf("fixture mode with the kusari set ingested nothing from %s", burst)
		}
	}
}

func TestCollector_FixtureModeDefaultSetReplaysNoKusariRecord(t *testing.T) {
	sink := &orderedSink{}
	c, err := awslogs.New(awslogs.AWSCollectorConfig{TenantID: "kusari"}, sink, awslogs.WithMode(string(awslogs.ModeFixture)))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := c.Start(context.Background()); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer c.Stop()
	for _, o := range sink.obs {
		if strings.HasPrefix(o.RawEvidenceRef, "testdata/kusari/") {
			t.Fatalf("the default fixture set replayed %s", o.RawEvidenceRef)
		}
	}
}

func TestCollector_UnknownFixtureSetRefusesToBoot(t *testing.T) {
	cfg := awslogs.AWSCollectorConfig{TenantID: "kusari", FixtureSet: "everything"}
	if _, err := awslogs.New(cfg, &orderedSink{}, awslogs.WithMode(string(awslogs.ModeFixture))); err == nil {
		t.Fatal("fixture mode accepted an unknown fixture set; it would replay something nobody asked for")
	}
}

func TestConfigFromEnv_ReadsTheFixtureSet(t *testing.T) {
	t.Setenv(awslogs.EnvFixtureSet, awslogs.FixtureSetKusari)
	if got := awslogs.ConfigFromEnv().FixtureSet; got != awslogs.FixtureSetKusari {
		t.Fatalf("ConfigFromEnv().FixtureSet = %q, want %q", got, awslogs.FixtureSetKusari)
	}
	t.Setenv(awslogs.EnvFixtureSet, "")
	if got := awslogs.ConfigFromEnv().FixtureSet; got != awslogs.FixtureSetDefault {
		t.Fatalf("unset %s resolved to %q, want %q", awslogs.EnvFixtureSet, got, awslogs.FixtureSetDefault)
	}
}
