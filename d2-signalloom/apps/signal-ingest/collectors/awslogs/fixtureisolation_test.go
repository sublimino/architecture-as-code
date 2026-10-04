// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs_test

import (
	"context"
	"errors"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
)

// Fixture mode is the local EAP path (proposal §2.1): it replays embedded testdata
// and must reach no AWS account, under any configuration, ever.
//
// "No SDK in the core package's import graph" is a structural argument for that, and
// it is a good one, but it is not the whole claim. The live client factory is a
// package-level variable that the `live` package sets from its init, so in a binary
// that links live mode in — which the production binary does — the factory IS
// present while fixture mode runs. Nothing structural stops a future Start from
// building clients before it looks at the mode, or from "warming" them, or from
// health-checking them on the way past. Each of those would dial the customer's
// account from a mode whose entire purpose is not to.
//
// So the assertion is behavioural and negative: install a factory and a set of seams
// that fail the test if they are touched at all, then run fixture mode end to end
// and require that none of them is.

// exploder is an SQSClient, S3Fetcher and STSAssumer in one, and every method fails
// the test. Any AWS call from fixture mode lands here instead of on a network.
type exploder struct {
	t *testing.T
}

func (e *exploder) ReceiveMessages(context.Context, string, int32) ([]awslogs.Message, error) {
	e.t.Error("fixture mode called sqs:ReceiveMessage; it must reach no AWS account")
	return nil, errors.New("exploder: ReceiveMessages must not be called in fixture mode")
}

func (e *exploder) DeleteMessage(context.Context, string, string) error {
	e.t.Error("fixture mode called sqs:DeleteMessage; it must reach no AWS account")
	return errors.New("exploder: DeleteMessage must not be called in fixture mode")
}

func (e *exploder) GetObject(context.Context, awslogs.ObjectRef) ([]byte, error) {
	e.t.Error("fixture mode called s3:GetObject; the fixture objects are embedded, not fetched")
	return nil, errors.New("exploder: GetObject must not be called in fixture mode")
}

func (e *exploder) AssumeRole(context.Context, string, string) (awslogs.Credentials, error) {
	e.t.Error("fixture mode called sts:AssumeRole; it must present no identity to any account")
	return awslogs.Credentials{}, errors.New("exploder: AssumeRole must not be called in fixture mode")
}

var (
	_ awslogs.SQSClient  = (*exploder)(nil)
	_ awslogs.S3Fetcher  = (*exploder)(nil)
	_ awslogs.STSAssumer = (*exploder)(nil)
)

// withFailingLiveFactory installs a live client factory that fails the test if it is
// ever invoked, and restores the previous one afterwards.
//
// Restoring matters: the factory is package-level state, and leaving a poisoned one
// behind would fail whichever test ran next in this binary rather than this one.
func withFailingLiveFactory(t *testing.T) {
	t.Helper()

	// This test binary does not link the `live` package, so nothing has registered a
	// factory and clearing it on the way out restores the natural state. Asserting
	// that up front rather than assuming it: if a future import pulls `live` in, the
	// cleanup below would silently unregister production wiring for every test that
	// ran afterwards, and the failure would land on an unrelated test.
	if awslogs.LiveClientFactoryRegistered() {
		t.Fatal("a live client factory is already registered in this test binary; clearing it in cleanup would break whichever test runs next, so this helper needs a real save/restore first")
	}

	awslogs.SetLiveClientFactory(func(context.Context, awslogs.AWSCollectorConfig) (
		awslogs.SQSClient, awslogs.S3Fetcher, awslogs.STSAssumer, awslogs.NotificationParser, error,
	) {
		t.Error("fixture mode invoked the live client factory; building an AWS client is already too far — LoadDefaultConfig probes the credential chain, which includes IMDS over the network")
		return nil, nil, nil, nil, errors.New("the live client factory must not be invoked in fixture mode")
	})

	t.Cleanup(func() { awslogs.SetLiveClientFactory(nil) })
}

// Fixture mode runs to completion, ingests every embedded object, and touches no AWS
// seam and no factory.
func TestCollector_FixtureModeNeverBuildsOrCallsALiveClient(t *testing.T) {
	withFailingLiveFactory(t)

	sink := &orderedSink{}
	boom := &exploder{t: t}

	// The seams are injected as well as the factory being poisoned, because the two
	// cover different routes to the same place: the factory catches "fixture mode
	// built a client", the seams catch "fixture mode used one that was handed to it".
	c, err := awslogs.New(
		awslogs.AWSCollectorConfig{TenantID: "kusari", Region: "us-east-1"},
		sink,
		awslogs.WithMode(string(awslogs.ModeFixture)),
		awslogs.WithAWS(boom, boom, boom),
	)
	if err != nil {
		t.Fatalf("New in fixture mode: %v", err)
	}

	ctx := context.Background()
	if err := c.Start(ctx); err != nil {
		t.Fatalf("Start in fixture mode: %v", err)
	}
	defer c.Stop()

	// End to end means the fixtures actually landed. Without this the test would pass
	// just as well against a fixture mode that did nothing at all, which is the
	// failure the mode gate was added to prevent in the first place (§8).
	wantObs, err := awslogs.FixtureObservations("kusari", "us-east-1")
	if err != nil {
		t.Fatalf("FixtureObservations: %v", err)
	}
	if len(wantObs) == 0 {
		t.Fatal("the fixtures project to no observations; this test would prove nothing")
	}
	if len(sink.obs) != len(wantObs) {
		t.Errorf("fixture mode ingested %d observations, want %d", len(sink.obs), len(wantObs))
	}
	if stats := c.Stats(); stats["processed_total"] != uint64(len(wantObs)) {
		t.Errorf("processed_total = %d, want %d", stats["processed_total"], len(wantObs))
	}

	// No ring either: fixture mode is synchronous and leaves no state on disk, so an
	// off-or-fixture deployment cannot be told apart from a live one by its buffer
	// directory.
	if ring := c.Ring(); ring != nil {
		t.Error("fixture mode opened the disk ring buffer; it replays synchronously and should leave no trace")
	}
}

// Fixture mode is also inert when it is configured as if for live mode — a full set
// of trust parameters present and a factory registered. This is the realistic
// misconfiguration: the mode is flipped to fixture for a demo while the account
// credentials and queue URL stay in the environment.
func TestCollector_FixtureModeIsInertEvenWithAFullLiveConfiguration(t *testing.T) {
	withFailingLiveFactory(t)

	sink := &orderedSink{}

	cfg := liveConfig(t)
	c, err := awslogs.New(cfg, sink, awslogs.WithMode(string(awslogs.ModeFixture)))
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	ctx := context.Background()
	if err := c.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer c.Stop()

	if len(sink.obs) == 0 {
		t.Error("fixture mode ingested nothing")
	}
	if stats := c.Stats(); stats["assume_role_total"] != 0 {
		t.Errorf("assume_role_total = %d, want 0: fixture mode presents no identity", stats["assume_role_total"])
	}

	// Health is the other door into the live clients, and the registry calls it on a
	// schedule. In fixture mode it must answer without assuming a role.
	if err := c.Health(ctx); err != nil {
		t.Errorf("Health in fixture mode = %v, want nil", err)
	}
	if stats := c.Stats(); stats["assume_role_total"] != 0 {
		t.Errorf("assume_role_total = %d after Health, want 0", stats["assume_role_total"])
	}
}
