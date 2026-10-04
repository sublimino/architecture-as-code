// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package collectors

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// verifyAWSLogsTwins is the awslogs entry in CollectorTwinVerifiers (falsification_test.go).
//
// It is required, not optional: awslogs is now in the production registry, and
// RunRegistryCoverageGuard fails closed on a registered collector that has no twin
// suite ("orphaned collector"). Adding the registration line without this would have
// turned TestRegistryCoverageGuard_ProductionRegistry red.
func verifyAWSLogsTwins(ctx context.Context) (*TwinSuiteExecution, error) {
	exec := &TwinSuiteExecution{
		CollectorName: "awslogs",
		TotalCases:    3,
	}
	baseTime := time.Now().UTC()

	// 1. Accept twin: a genuinely projected fixture observation must validate. It is
	// taken from the real projection rather than hand-built, so the twin cannot pass
	// while the projection is broken.
	exec.AcceptTwinRun = true
	obsAccept := AWSLogsAcceptTwinObservation(baseTime)
	if err := obsAccept.Validate(); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin observation validation failed: %v", err))
		return exec, nil
	}
	sinkAccept := &trackingSink{}
	if err := sinkAccept.IngestObservation(ctx, &obsAccept); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin IngestObservation failed: %v", err))
		return exec, nil
	}
	if sinkAccept.Count() != 1 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin expected 1 observation, got %d", sinkAccept.Count()))
		return exec, nil
	}
	exec.AcceptTwinPassed = true

	// 2. Reject / under-report twin.
	exec.RejectTwinRun = true
	obsReject := AWSLogsRejectTwinObservation()
	if err := obsReject.Validate(); err == nil {
		exec.ExecutionLog = append(exec.ExecutionLog, "RejectTwin invalid observation unexpectedly passed validation")
		return exec, nil
	}
	exec.RejectTwinPassed = true

	// 3. Mock-vs-live distinctness. Fixture mode replays the embedded objects; live
	// mode must fail explicitly, because the aws-sdk-go-v2 implementation of the three
	// seams is deferred to SLAWS P3-1. A live mode returning nil here would restore the
	// §8 defect exactly: a collector that reports healthy while collecting nothing.
	exec.DistinctnessRun = true
	sinkFixture := &trackingSink{}
	colFixture := NewAWSLogsCollector(ModeFixture, sinkFixture)
	if err := colFixture.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Fixture start failed: %v", err))
		return exec, nil
	}
	colFixture.Stop()
	if want := len(AWSLogsFixtures(baseTime)); sinkFixture.Count() != want {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Fixture mode expected %d observations, got %d", want, sinkFixture.Count()))
		return exec, nil
	}

	sinkLive := &trackingSink{}
	colLive := NewAWSLogsCollector(ModeLive, sinkLive)
	if errLive := colLive.Start(ctx); errLive == nil {
		exec.ExecutionLog = append(exec.ExecutionLog, "Live mode expected an explicit error, got nil")
		return exec, nil
	}
	if sinkLive.Count() != 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Live mode ingested %d observations before any AWS call", sinkLive.Count()))
		return exec, nil
	}
	exec.DistinctnessPassed = true

	return exec, nil
}

// TestAWSLogs_RegisteredInTheProductionRegistryAndDefaultsToOff is the registry row
// for awslogs (SLAWS ISC-11..17): it must be present in the registry built from the
// environment, and absent configuration must mean off, not live.
func TestAWSLogs_RegisteredInTheProductionRegistryAndDefaultsToOff(t *testing.T) {
	for _, k := range []string{"COLLECTOR_AWSLOGS_MODE", "SIGNAL_COLLECTOR_AWSLOGS", "AWSLOGS_MODE"} {
		t.Setenv(k, "")
	}

	reg := NewRegistryFromEnv(&trackingSink{})
	col := reg.GetCollector("awslogs")
	if col == nil {
		t.Fatal("awslogs is not registered in NewRegistryFromEnv")
	}
	if col.Mode() != ModeOff {
		t.Errorf("awslogs Mode() = %q with no configuration, want off", col.Mode())
	}
}

// TestAWSLogs_EachModeGateVariableSelectsTheMode walks all three accepted variables,
// in precedence order, so a deployment that sets the one the operator happens to know
// about gets the mode it asked for.
func TestAWSLogs_EachModeGateVariableSelectsTheMode(t *testing.T) {
	for _, key := range []string{"COLLECTOR_AWSLOGS_MODE", "SIGNAL_COLLECTOR_AWSLOGS", "AWSLOGS_MODE"} {
		t.Run(key, func(t *testing.T) {
			for _, k := range []string{"COLLECTOR_AWSLOGS_MODE", "SIGNAL_COLLECTOR_AWSLOGS", "AWSLOGS_MODE"} {
				t.Setenv(k, "")
			}
			t.Setenv(key, "fixture")

			reg := NewRegistryFromEnv(&trackingSink{})
			col := reg.GetCollector("awslogs")
			if col == nil {
				t.Fatal("awslogs is not registered")
			}
			if col.Mode() != ModeFixture {
				t.Errorf("%s=fixture gave Mode() = %q, want fixture", key, col.Mode())
			}
		})
	}
}

// TestAWSLogs_UnrecognisedModeFailsClosed: an unparseable mode must be off, never
// live. A typo in a deployment variable should silence a collector, not point it at a
// customer's AWS account.
func TestAWSLogs_UnrecognisedModeFailsClosed(t *testing.T) {
	t.Setenv("COLLECTOR_AWSLOGS_MODE", "LIVE-ish")
	t.Setenv("SIGNAL_COLLECTOR_AWSLOGS", "")
	t.Setenv("AWSLOGS_MODE", "")

	reg := NewRegistryFromEnv(&trackingSink{})
	if got := reg.GetCollector("awslogs").Mode(); got != ModeOff {
		t.Errorf("an unrecognised mode gave Mode() = %q, want off", got)
	}
}

// TestAWSLogs_RegistryStartAndStopDriveTheCollector is the lifecycle row: the registry
// starts a fixture-mode awslogs collector, observations arrive, and Stop reaches it.
//
// Stop reaching it is the point. The v1 `Stop() error` did not satisfy Stopper, so
// Registry.Stop silently skipped the collector and a live instance leaked its
// goroutines on every shutdown — a missing optional interface is not a compile error
// at the registration site, so nothing anywhere said so.
func TestAWSLogs_RegistryStartAndStopDriveTheCollector(t *testing.T) {
	t.Setenv("COLLECTOR_AWSLOGS_MODE", "fixture")
	for _, k := range []string{
		"COLLECTOR_GCPAUDIT_MODE", "GCPAUDIT_MODE",
		"COLLECTOR_BAOAUDIT_MODE", "BAOAUDIT_MODE",
		"COLLECTOR_SPIREA_MODE", "SPIREA_MODE",
		"COLLECTOR_NETEBPF_MODE", "NETEBPF_MODE",
		"COLLECTOR_K8SAUDIT_MODE", "K8SAUDIT_MODE",
		"COLLECTOR_KAGENT_MODE", "KAGENT_MODE", "SIGNAL_COLLECTOR_KAGENT",
		"COLLECTOR_WORKSPACESAAS_MODE", "WORKSPACESAAS_MODE", "SIGNAL_COLLECTOR_WORKSPACESAAS",
		"COLLECTOR_AGENTNONO_MODE", "AGENTNONO_MODE",
		"COLLECTOR_FIXTURES_MODE", "FIXTURES_MODE",
	} {
		t.Setenv(k, "")
	}

	sink := &trackingSink{}
	reg := NewRegistryFromEnv(sink)
	ctx := context.Background()

	if err := reg.Start(ctx); err != nil {
		t.Fatalf("Registry.Start: %v", err)
	}
	if err := reg.Health(ctx); err != nil {
		t.Fatalf("Registry.Health: %v", err)
	}

	want := len(AWSLogsFixtures(time.Now().UTC()))
	if want == 0 {
		t.Fatal("AWSLogsFixtures returned nothing; the rest of this test would be vacuous")
	}
	if got := sink.Count(); got != want {
		t.Errorf("registry-started awslogs ingested %d observations, want %d", got, want)
	}

	col := reg.GetCollector("awslogs")
	if _, ok := col.(Stopper); !ok {
		t.Fatal("awslogs does not satisfy Stopper, so Registry.Stop will silently skip it (the v1 Stop() error defect)")
	}
	reg.Stop()
}

// TestAWSLogs_FixtureModeBindsTheConfiguredTenant proves the adapter wraps the sink
// with BindTenant and that the tenant comes from configuration (SLAWS D7), not from
// the record.
func TestAWSLogs_FixtureModeBindsTheConfiguredTenant(t *testing.T) {
	t.Setenv("AWSLOGS_TENANT_ID", "acme")
	t.Setenv("COLLECTOR_AWSLOGS_MODE", "fixture")

	sink := &trackingSink{}
	col := NewAWSLogsCollector(ModeFixture, sink)
	if got := col.Config().TenantID; got != "acme" {
		t.Fatalf("Config().TenantID = %q, want acme (from AWSLOGS_TENANT_ID)", got)
	}
	if err := col.Start(context.Background()); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer col.Stop()

	obs := sink.Observations()
	if len(obs) == 0 {
		t.Fatal("fixture mode ingested nothing")
	}
	for _, o := range obs {
		if o.Labels["tenant_id"] != "acme" {
			t.Errorf("observation %s has tenant_id %q, want acme", o.ID, o.Labels["tenant_id"])
		}
	}
}
