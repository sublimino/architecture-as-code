// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package collectors

import (
	"context"
	"fmt"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/k8saudit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// verifyK8sAuditKubeTwins is the k8saudit-kube entry in CollectorTwinVerifiers.
// It is required, not optional: the threat vertical is in the production
// registry, and RunRegistryCoverageGuard fails closed on a registered collector
// with no twin suite ("orphaned collector").
func verifyK8sAuditKubeTwins(ctx context.Context) (*TwinSuiteExecution, error) {
	exec := &TwinSuiteExecution{
		CollectorName: "k8saudit-kube",
		TotalCases:    3,
	}

	// 1. Accept twin: a genuinely projected fixture observation must validate and
	// be LayerKubernetes with the k8saudit-kube source. Taken from the real
	// projection so the twin cannot pass while the projection is broken.
	exec.AcceptTwinRun = true
	corpus, err := k8saudit.FixtureObservations()
	if err != nil || len(corpus) == 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin corpus load failed: %v (len=%d)", err, len(corpus)))
		return exec, nil
	}
	obsAccept := corpus[0]
	if err := obsAccept.Validate(); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin validation failed: %v", err))
		return exec, nil
	}
	if obsAccept.Layer != model.LayerKubernetes || obsAccept.Source != k8saudit.ObservationSource {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin wrong layer/source: %s/%s", obsAccept.Layer, obsAccept.Source))
		return exec, nil
	}
	exec.AcceptTwinPassed = true

	// 2. Reject / under-report twin: an invalid observation must fail Validate.
	exec.RejectTwinRun = true
	obsReject := model.Observation{Layer: model.Layer("not_a_layer"), Confidence: 7.5}
	if err := obsReject.Validate(); err == nil {
		exec.ExecutionLog = append(exec.ExecutionLog, "RejectTwin invalid observation unexpectedly passed validation")
		return exec, nil
	}
	exec.RejectTwinPassed = true

	// 3. Mock-vs-live distinctness: fixture mode replays the embedded corpus; live
	// mode with no warden audit path must fail explicitly, never silently collect
	// nothing while reporting healthy.
	exec.DistinctnessRun = true
	sinkFixture := &trackingSink{}
	colFixture := NewK8sAuditKubeCollector(ModeFixture, sinkFixture)
	if err := colFixture.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Fixture start failed: %v", err))
		return exec, nil
	}
	colFixture.Stop()
	if sinkFixture.Count() != len(corpus) {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Fixture mode expected %d observations, got %d", len(corpus), sinkFixture.Count()))
		return exec, nil
	}

	sinkLive := &trackingSink{}
	colLive := NewK8sAuditKubeCollector(ModeLive, sinkLive)
	colLive.cfg = k8saudit.Config{SourceName: "warden-local"} // no path: must fail
	if errLive := colLive.Start(ctx); errLive == nil {
		exec.ExecutionLog = append(exec.ExecutionLog, "Live mode expected an explicit error (no audit path), got nil")
		return exec, nil
	}
	if sinkLive.Count() != 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Live mode ingested %d observations before any source read", sinkLive.Count()))
		return exec, nil
	}
	exec.DistinctnessPassed = true

	return exec, nil
}

// TestCollectorFalsification_K8sAuditKube is the direct entrypoint for the
// threat vertical's twin suite.
func TestCollectorFalsification_K8sAuditKube(t *testing.T) {
	exec, err := verifyK8sAuditKubeTwins(context.Background())
	if err != nil {
		t.Fatalf("k8saudit-kube twin suite execution error: %v", err)
	}
	if !exec.AcceptTwinPassed {
		t.Errorf("k8saudit-kube accept twin failed: %v", exec.ExecutionLog)
	}
	if !exec.RejectTwinPassed {
		t.Errorf("k8saudit-kube reject/under-report twin failed: %v", exec.ExecutionLog)
	}
	if !exec.DistinctnessPassed {
		t.Errorf("k8saudit-kube distinctness test failed: %v", exec.ExecutionLog)
	}
}

// TestK8sAuditKube_RegisteredAndDefaultsToOff: the collector must be in the
// registry built from the environment, and absent configuration means off.
func TestK8sAuditKube_RegisteredAndDefaultsToOff(t *testing.T) {
	for _, k := range []string{"COLLECTOR_K8SAUDIT_KUBE_MODE", "SIGNAL_COLLECTOR_K8SAUDIT_KUBE", "K8SAUDIT_KUBE_MODE"} {
		t.Setenv(k, "")
	}
	reg := NewRegistryFromEnv(&trackingSink{})
	col := reg.GetCollector("k8saudit-kube")
	if col == nil {
		t.Fatal("k8saudit-kube is not registered in NewRegistryFromEnv")
	}
	if col.Mode() != ModeOff {
		t.Errorf("k8saudit-kube Mode() = %q with no configuration, want off", col.Mode())
	}
}

// TestK8sAuditKube_FixtureModeBindsTheConfiguredTenant proves the adapter wraps
// the sink with BindTenant and the tenant is configuration, not from a record.
func TestK8sAuditKube_FixtureModeBindsTheConfiguredTenant(t *testing.T) {
	t.Setenv("K8SAUDIT_TENANT_ID", "acme")
	sink := &trackingSink{}
	col := NewK8sAuditKubeCollector(ModeFixture, sink)
	if err := col.Start(context.Background()); err != nil {
		t.Fatalf("Start: %v", err)
	}
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
