// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package collectors

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
)

// TestAWSLogsLiveModeIsWired guards the blank import in awslogs_adapter.go.
//
// The live AWS implementation reaches the collector through a registration
// (awslogs.SetLiveClientFactory, called from the live package's init) rather than a
// direct call, because the live package imports awslogs for its value types and the
// dependency can only run one way. The cost of that shape is a link-time dependency
// that no compiler checks: delete the blank import and everything still builds,
// every test still passes, and live mode silently degrades to
// ErrLiveClientsNotWired — discovered on a customer account rather than here.
//
// This is that check. It is cheap and it is the only thing standing between SLAWS
// P3-1 and a deployment that reports a live cloud collector which collects nothing.
func TestAWSLogsLiveModeIsWired(t *testing.T) {
	if !awslogs.LiveClientFactoryRegistered() {
		t.Fatal("no awslogs live client factory is registered: the blank import of " +
			"collectors/awslogs/live has been dropped from awslogs_adapter.go, so live mode " +
			"will fail with ErrLiveClientsNotWired")
	}
}

// Registering the factory must not weaken the mode gate. An unconfigured live
// collector has to fail on its missing configuration, naming the variables, rather
// than reach the factory and fail with an opaque AWS credential-chain error — or
// worse, construct clients and start polling a queue URL it does not have.
func TestAWSLogsLiveModeStillRefusesAnUnconfiguredAccount(t *testing.T) {
	for _, env := range []string{
		awslogs.EnvTenantID, awslogs.EnvRoleARN, awslogs.EnvExternalID,
		awslogs.EnvQueueURL, awslogs.EnvRegion,
	} {
		t.Setenv(env, "")
	}
	// Belt and braces: nothing in this test may reach the EC2 metadata service even
	// if the configuration gate regressed.
	t.Setenv("AWS_EC2_METADATA_DISABLED", "true")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	err := NewAWSLogsCollector(ModeLive, &testMockSink{}).Start(ctx)
	if err == nil {
		t.Fatal("live mode with no configuration started successfully; the mode gate is decorative")
	}
	// It must name the missing variables. Reaching ErrLiveClientsNotWired here would
	// mean the factory is unregistered; reaching an AWS error would mean the
	// configuration gate ran too late to be useful.
	if errors.Is(err, awslogs.ErrLiveClientsNotWired) {
		t.Fatalf("live mode failed as unwired rather than as unconfigured: %v", err)
	}
	if !strings.Contains(err.Error(), awslogs.EnvRoleARN) {
		t.Errorf("error does not name the missing configuration (%s): %v", awslogs.EnvRoleARN, err)
	}
}
