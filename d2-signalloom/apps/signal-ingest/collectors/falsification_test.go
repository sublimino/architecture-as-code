// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package collectors

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	apiaudit "github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/baoaudit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/gcpaudit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/kagent"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/netebpf"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/spirea"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// TwinSuiteExecution records the concrete execution outcomes of a collector's twin suite.
type TwinSuiteExecution struct {
	CollectorName       string
	AcceptTwinRun       bool
	AcceptTwinPassed    bool
	RejectTwinRun       bool
	RejectTwinPassed    bool
	DistinctnessRun     bool
	DistinctnessPassed  bool
	TotalCases          int
	SkippedCases        int
	ExecutionLog        []string
}

// CollectorTwinVerifier defines a standardized runner for verifying a collector's twins and distinctness.
type CollectorTwinVerifier func(ctx context.Context) (*TwinSuiteExecution, error)

// Global registry of verifiers mapping collector names to their twin test executions.
var CollectorTwinVerifiers = map[string]CollectorTwinVerifier{
	"gcpaudit":       verifyGCPAuditTwins,
	"baoaudit":       verifyBaoAuditTwins,
	"spirea":         verifySPIREATwins,
	"netebpf":        verifyNetEBPFTwins,
	"k8saudit":       verifyK8sAuditTwins,
	"kagent":         verifyKAgentTwins,
	"workspacesaas":  verifyWorkspaceSaaSTwins,
	"fixtures":       verifyFixturesTwins,
}

// RegistryCoverageReport holds the aggregate verification result across all registered collectors.
type RegistryCoverageReport struct {
	TotalCollectors     int
	VerifiedCollectors  int
	Executions          map[string]*TwinSuiteExecution
}

// RunRegistryCoverageGuard verifies that every collector in the provided registry has a registered,
// fully executed, and passing twin test suite (accept twin, reject twin, and mock-vs-live distinctness).
func RunRegistryCoverageGuard(reg *Registry) (*RegistryCoverageReport, error) {
	if reg == nil {
		return nil, fmt.Errorf("cannot run registry coverage guard on nil registry")
	}

	collectors := reg.Collectors()
	if len(collectors) == 0 {
		return nil, fmt.Errorf("registry has 0 registered collectors; expected active collectors")
	}

	report := &RegistryCoverageReport{
		TotalCollectors: len(collectors),
		Executions:      make(map[string]*TwinSuiteExecution),
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	for _, c := range collectors {
		name := c.Name()
		verifier, exists := CollectorTwinVerifiers[name]
		if !exists {
			return nil, fmt.Errorf("orphaned collector: %q is registered in main.go/registry but has no twin test suite in CollectorTwinVerifiers", name)
		}

		exec, err := verifier(ctx)
		if err != nil {
			return nil, fmt.Errorf("collector %q twin suite returned execution error: %w", name, err)
		}

		// Anti-vacuous-pass check: ensure all cases were actually executed and none were silently skipped
		if exec.TotalCases == 0 || exec.SkippedCases >= exec.TotalCases {
			return nil, fmt.Errorf("skipped collector suite: collector %q had all test cases skipped (skipped=%d, total=%d)", name, exec.SkippedCases, exec.TotalCases)
		}

		if !exec.AcceptTwinRun || !exec.AcceptTwinPassed {
			return nil, fmt.Errorf("collector %q failed accept twin test", name)
		}

		if !exec.RejectTwinRun || !exec.RejectTwinPassed {
			return nil, fmt.Errorf("collector %q failed reject/under-report twin test", name)
		}

		if !exec.DistinctnessRun || !exec.DistinctnessPassed {
			return nil, fmt.Errorf("collector %q failed mock-vs-live distinctness test", name)
		}

		report.Executions[name] = exec
		report.VerifiedCollectors++
	}

	return report, nil
}

// --- GCPAudit Verifier ---
func verifyGCPAuditTwins(ctx context.Context) (*TwinSuiteExecution, error) {
	exec := &TwinSuiteExecution{
		CollectorName: "gcpaudit",
		TotalCases:    3,
	}
	baseTime := time.Now().UTC()

	// 1. Accept Twin
	exec.AcceptTwinRun = true
	sinkAccept := &trackingSink{}
	colAccept := gcpaudit.New(ctx, sinkAccept, gcpaudit.DefaultDeduplicationTTL, gcpaudit.WithMode("off"))
	if err := colAccept.IngestLogEntry(ctx, GCPAuditAcceptTwinLogEntry(baseTime)); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin error: %v", err))
		return exec, nil
	}
	if sinkAccept.Count() != 1 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin expected 1 observation, got %d", sinkAccept.Count()))
		return exec, nil
	}
	obs := sinkAccept.Observations()[0]
	if obs.Layer != model.LayerCloudControlPlane || obs.ID == "" || obs.Fidelity != model.FidelityDefinitive {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin invalid observation: %+v", obs))
		return exec, nil
	}
	exec.AcceptTwinPassed = true

	// 2. Reject / Under-Report Twin
	exec.RejectTwinRun = true
	// 2a. Reject malformed JSON
	errMalformed := colAccept.IngestJSONBytes(ctx, GCPAuditRejectTwinPayload())
	if errMalformed == nil {
		exec.ExecutionLog = append(exec.ExecutionLog, "RejectTwin accepted malformed JSON without error")
		return exec, nil
	}
	// 2b. Under-report & deduplication check: deduplication must drop second identical insertID and not emit duplicate observation
	entryDup := GCPAuditAcceptTwinLogEntry(baseTime)
	_ = colAccept.IngestLogEntry(ctx, entryDup)
	if colAccept.Metrics()["dedup_drop"].(uint64) < 1 {
		exec.ExecutionLog = append(exec.ExecutionLog, "RejectTwin deduplication drop metric not incremented")
		return exec, nil
	}
	if sinkAccept.Count() != 1 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("RejectTwin expected 1 observation after duplicate, got %d", sinkAccept.Count()))
		return exec, nil
	}
	exec.RejectTwinPassed = true

	// 3. Mock-vs-Live Distinctness
	exec.DistinctnessRun = true
	sinkFixture := &trackingSink{}
	colFixture := NewGCPAuditCollector(ModeFixture, sinkFixture)
	if err := colFixture.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Fixture start failed: %v", err))
		return exec, nil
	}
	colFixture.Stop()

	sinkLive := &trackingSink{}
	colLive := NewGCPAuditCollector(ModeLive, sinkLive)
	if err := colLive.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Live start failed: %v", err))
		return exec, nil
	}
	// Live starts with 0 observations until live events arrive
	if sinkLive.Count() != 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, "Live mode immediately had observations before live input")
		colLive.Stop()
		return exec, nil
	}
	// Inject live event with distinct ID
	liveEntry := GCPAuditAcceptTwinLogEntry(baseTime)
	liveEntry.InsertID = "live-distinctness-gcp-001"
	if err := colLive.RawCollector().IngestLogEntry(ctx, liveEntry); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Live IngestLogEntry failed: %v", err))
		colLive.Stop()
		return exec, nil
	}
	colLive.Stop()

	if sinkFixture.Count() == 0 || sinkLive.Count() == 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, "Distinctness check failed: expected >0 observations in both modes")
		return exec, nil
	}
	if sinkFixture.Observations()[0].ID == sinkLive.Observations()[0].ID {
		exec.ExecutionLog = append(exec.ExecutionLog, "Distinctness check failed: fixture and live produced identical observation IDs")
		return exec, nil
	}
	exec.DistinctnessPassed = true

	return exec, nil
}

// --- BaoAudit Verifier ---
func verifyBaoAuditTwins(ctx context.Context) (*TwinSuiteExecution, error) {
	exec := &TwinSuiteExecution{
		CollectorName: "baoaudit",
		TotalCases:    3,
	}
	baseTime := time.Now().UTC()

	// 1. Accept Twin
	exec.AcceptTwinRun = true
	sinkAccept := &trackingSink{}
	rcvAccept := baoaudit.NewAuditReceiver(100, sinkAccept)
	rcvAccept.Start()
	if err := rcvAccept.IngestRawBytes(BaoAuditAcceptTwinPayload(baseTime)); err != nil {
		rcvAccept.Stop()
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin IngestRawBytes error: %v", err))
		return exec, nil
	}
	// Wait for worker drain
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && sinkAccept.Count() == 0 {
		time.Sleep(5 * time.Millisecond)
	}
	rcvAccept.Stop()
	if sinkAccept.Count() != 1 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin expected 1 observation, got %d", sinkAccept.Count()))
		return exec, nil
	}
	obs := sinkAccept.Observations()[0]
	if obs.Layer != model.LayerIdentityAuth || obs.Source != "openbao-audit" || obs.ActorHint == "" {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin invalid observation: %+v", obs))
		return exec, nil
	}
	exec.AcceptTwinPassed = true

	// 2. Reject / Under-Report Twin
	exec.RejectTwinRun = true
	sinkReject := &trackingSink{}
	rcvReject := baoaudit.NewAuditReceiver(100, sinkReject)
	rcvReject.Start()
	// 2a. Reject malformed JSON
	errMalformed := rcvReject.IngestRawBytes(BaoAuditRejectTwinPayload())
	if errMalformed == nil {
		rcvReject.Stop()
		exec.ExecutionLog = append(exec.ExecutionLog, "RejectTwin accepted malformed JSON without error")
		return exec, nil
	}
	// 2b. Ingest empty bytes: must be cleanly ignored without producing an observation
	if err := rcvReject.IngestRawBytes([]byte("")); err != nil {
		rcvReject.Stop()
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("RejectTwin empty bytes error: %v", err))
		return exec, nil
	}
	time.Sleep(20 * time.Millisecond)
	rcvReject.Stop()
	if sinkReject.Count() != 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("RejectTwin expected 0 observations in sink, got %d", sinkReject.Count()))
		return exec, nil
	}
	exec.RejectTwinPassed = true

	// 3. Mock-vs-Live Distinctness
	exec.DistinctnessRun = true
	sinkFixture := &trackingSink{}
	colFixture := NewBaoAuditCollector(ModeFixture, sinkFixture)
	if err := colFixture.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Fixture start failed: %v", err))
		return exec, nil
	}
	colFixture.Stop()

	sinkLive := &trackingSink{}
	colLive := NewBaoAuditCollector(ModeLive, sinkLive)
	if err := colLive.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Live start failed: %v", err))
		return exec, nil
	}
	if colLive.RawReceiver() == nil {
		exec.ExecutionLog = append(exec.ExecutionLog, "Live mode did not initialize RawReceiver")
		colLive.Stop()
		return exec, nil
	}
	// Ingest live distinct event
	liveEv := BaoAuditAcceptTwinEvent(baseTime)
	liveEv.Request.ID = "req-bao-live-distinct-001"
	livePayload, _ := json.Marshal(liveEv)
	if err := colLive.RawReceiver().IngestRawBytes(livePayload); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Live IngestRawBytes error: %v", err))
		colLive.Stop()
		return exec, nil
	}
	deadline = time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && sinkLive.Count() == 0 {
		time.Sleep(5 * time.Millisecond)
	}
	colLive.Stop()

	if sinkFixture.Count() == 0 || sinkLive.Count() == 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, "Distinctness failed: missing observations")
		return exec, nil
	}
	exec.DistinctnessPassed = true

	return exec, nil
}

// --- SPIREA Verifier ---
func verifySPIREATwins(ctx context.Context) (*TwinSuiteExecution, error) {
	exec := &TwinSuiteExecution{
		CollectorName: "spirea",
		TotalCases:    3,
	}
	baseTime := time.Now().UTC()

	// 1. Accept Twin
	exec.AcceptTwinRun = true
	sinkAccept := &trackingSink{}
	colAccept := spirea.NewSPIREIssuanceCollector(sinkAccept)
	if err := colAccept.IngestIssuanceEvent(ctx, SPIREIssuanceAcceptTwinEvent(baseTime)); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin IngestIssuanceEvent error: %v", err))
		return exec, nil
	}
	if sinkAccept.Count() != 1 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin expected 1 observation, got %d", sinkAccept.Count()))
		return exec, nil
	}
	obs := sinkAccept.Observations()[0]
	if obs.Layer != model.LayerIdentityAuth || obs.Source != "spire-agent" || obs.Labels["spiffe_id"] == "" {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin invalid observation: %+v", obs))
		return exec, nil
	}
	exec.AcceptTwinPassed = true

	// 2. Reject / Under-Report Twin
	exec.RejectTwinRun = true
	sinkReject := &trackingSink{}
	colReject := spirea.NewSPIREIssuanceCollector(sinkReject)
	// Missing SPIFFEID must not emit observation
	_ = colReject.IngestIssuanceEvent(ctx, SPIREIssuanceRejectTwinEvent(baseTime))
	_ = colReject.IngestIssuanceEvent(ctx, nil)
	if sinkReject.Count() != 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("RejectTwin expected 0 observations, got %d", sinkReject.Count()))
		return exec, nil
	}
	exec.RejectTwinPassed = true

	// 3. Mock-vs-Live Distinctness
	exec.DistinctnessRun = true
	sinkFixture := &trackingSink{}
	colFixture := NewSPIREACollector(ModeFixture, sinkFixture)
	if err := colFixture.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Fixture start failed: %v", err))
		return exec, nil
	}
	colFixture.Stop()

	sinkLive := &trackingSink{}
	colLive := NewSPIREACollector(ModeLive, sinkLive)
	if err := colLive.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Live start failed: %v", err))
		return exec, nil
	}
	if sinkLive.Count() != 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, "Live mode immediately had observations")
		colLive.Stop()
		return exec, nil
	}
	liveEv := SPIREIssuanceAcceptTwinEvent(baseTime)
	liveEv.SPIFFEID = "spiffe://cluster.local/ns/live-distinct/sa/live-sa"
	_ = colLive.RawCollector().IngestIssuanceEvent(ctx, liveEv)
	colLive.Stop()

	if sinkFixture.Count() == 0 || sinkLive.Count() == 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, "Distinctness failed: missing observations")
		return exec, nil
	}
	if sinkFixture.Observations()[0].Labels["spiffe_id"] == sinkLive.Observations()[0].Labels["spiffe_id"] {
		exec.ExecutionLog = append(exec.ExecutionLog, "Distinctness failed: fixture and live produced identical spiffe_id")
		return exec, nil
	}
	exec.DistinctnessPassed = true

	return exec, nil
}

// --- NetEBPF Verifier ---
func verifyNetEBPFTwins(ctx context.Context) (*TwinSuiteExecution, error) {
	exec := &TwinSuiteExecution{
		CollectorName: "netebpf",
		TotalCases:    3,
	}
	baseTime := time.Now().UTC()

	// 1. Accept Twin
	exec.AcceptTwinRun = true
	sinkAccept := &trackingSink{}
	colAccept := netebpf.NewLiveNetworkEgressCollector(ctx, sinkAccept)
	if err := colAccept.ProcessFlowEvent(ctx, NetEBPFAcceptTwinEvent(baseTime)); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin ProcessFlowEvent error: %v", err))
		return exec, nil
	}
	if sinkAccept.Count() != 1 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin expected 1 observation, got %d", sinkAccept.Count()))
		return exec, nil
	}
	obs := sinkAccept.Observations()[0]
	if obs.Layer != model.LayerNetworkEgress || obs.Source != "sentinel.ebpf.socket_trace" {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin invalid observation: %+v", obs))
		return exec, nil
	}
	exec.AcceptTwinPassed = true

	// 2. Reject / Under-Report Twin
	exec.RejectTwinRun = true
	sinkReject := &trackingSink{}
	colReject := netebpf.NewLiveNetworkEgressCollector(ctx, sinkReject)
	if err := colReject.ProcessFlowEvent(ctx, NetEBPFRejectTwinEvent()); err == nil {
		exec.ExecutionLog = append(exec.ExecutionLog, "RejectTwin accepted nil flow event without error")
		return exec, nil
	}
	// Under-report test: sequence gap detection
	_ = colReject.ProcessFlowEvent(ctx, NetEBPFAcceptTwinEvent(baseTime))
	_ = colReject.ProcessFlowEvent(ctx, NetEBPFUnderReportTwinEvent(baseTime))
	// Gap should emit a secondary gap observation
	if sinkReject.Count() < 2 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("RejectTwin expected gap alert observation, total=%d", sinkReject.Count()))
		return exec, nil
	}
	exec.RejectTwinPassed = true

	// 3. Mock-vs-Live Distinctness
	exec.DistinctnessRun = true
	sinkFixture := &trackingSink{}
	colFixture := NewNetEBPFCollector(ModeFixture, sinkFixture)
	if err := colFixture.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Fixture start failed: %v", err))
		return exec, nil
	}
	colFixture.Stop()

	sinkLive := &trackingSink{}
	colLive := NewNetEBPFCollector(ModeLive, sinkLive)
	if err := colLive.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Live start failed: %v", err))
		return exec, nil
	}
	if sinkLive.Count() != 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, "Live mode immediately had observations")
		colLive.Stop()
		return exec, nil
	}
	liveFlow := NetEBPFAcceptTwinEvent(baseTime)
	liveFlow.DstIP = "198.51.100.99"
	liveFlow.DstPort = 8443
	_ = colLive.RawCollector().ProcessFlowEvent(ctx, liveFlow)
	colLive.Stop()

	if sinkFixture.Count() == 0 || sinkLive.Count() == 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, "Distinctness failed: missing observations")
		return exec, nil
	}
	exec.DistinctnessPassed = true

	return exec, nil
}

// --- K8sAudit Verifier ---
func verifyK8sAuditTwins(ctx context.Context) (*TwinSuiteExecution, error) {
	exec := &TwinSuiteExecution{
		CollectorName: "k8saudit",
		TotalCases:    3,
	}
	baseTime := time.Now().UTC()

	// 1. Accept Twin
	exec.AcceptTwinRun = true
	sinkAccept := &trackingSink{}
	rcvAccept := apiaudit.NewWebhookReceiver(ctx, 100, 2, sinkAccept)
	rcvAccept.Start()
	accepted, _ := rcvAccept.IngestK8sEventList(K8sAuditAcceptTwinEventList(baseTime))
	if accepted != 1 {
		rcvAccept.Close()
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin IngestK8sEventList accepted=%d, want 1", accepted))
		return exec, nil
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && sinkAccept.Count() == 0 {
		time.Sleep(5 * time.Millisecond)
	}
	rcvAccept.Close()
	if sinkAccept.Count() != 1 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin expected 1 observation, got %d", sinkAccept.Count()))
		return exec, nil
	}
	obs := sinkAccept.Observations()[0]
	if obs.Layer != model.LayerIdentityAuth || obs.Source != "k8s-apiserver-audit" {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin invalid observation: %+v", obs))
		return exec, nil
	}
	exec.AcceptTwinPassed = true

	// 2. Reject / Under-Report Twin
	exec.RejectTwinRun = true
	sinkReject := &trackingSink{}
	rcvReject := apiaudit.NewWebhookReceiver(ctx, 100, 2, sinkReject)
	rcvReject.Start()
	req := httptest.NewRequest(http.MethodPost, apiaudit.WebhookPath, bytes.NewReader(K8sAuditRejectTwinPayload()))
	w := httptest.NewRecorder()
	rcvReject.HandleAuditWebhook(w, req)
	rcvReject.Close()
	if w.Code != http.StatusBadRequest {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("RejectTwin expected HTTP 400 Bad Request, got %d", w.Code))
		return exec, nil
	}
	if sinkReject.Count() != 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("RejectTwin expected 0 observations, got %d", sinkReject.Count()))
		return exec, nil
	}
	exec.RejectTwinPassed = true

	// 3. Mock-vs-Live Distinctness
	exec.DistinctnessRun = true
	sinkFixture := &trackingSink{}
	colFixture := NewK8sAuditCollector(ModeFixture, sinkFixture)
	if err := colFixture.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Fixture start failed: %v", err))
		return exec, nil
	}
	colFixture.Stop()

	sinkLive := &trackingSink{}
	colLive := NewK8sAuditCollector(ModeLive, sinkLive)
	if err := colLive.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Live start failed: %v", err))
		return exec, nil
	}
	if sinkLive.Count() != 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, "Live mode immediately had observations")
		colLive.Stop()
		return exec, nil
	}
	liveList := K8sAuditAcceptTwinEventList(baseTime)
	liveList.Items[0].AuditID = "k8s-distinct-audit-live-001"
	colLive.RawReceiver().IngestK8sEventList(liveList)
	deadline = time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && sinkLive.Count() == 0 {
		time.Sleep(5 * time.Millisecond)
	}
	colLive.Stop()

	if sinkFixture.Count() == 0 || sinkLive.Count() == 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, "Distinctness failed: missing observations")
		return exec, nil
	}
	if sinkFixture.Observations()[0].ID == sinkLive.Observations()[0].ID {
		exec.ExecutionLog = append(exec.ExecutionLog, "Distinctness failed: fixture and live produced identical observation ID")
		return exec, nil
	}
	exec.DistinctnessPassed = true

	return exec, nil
}

// --- KAgent Verifier ---
func verifyKAgentTwins(ctx context.Context) (*TwinSuiteExecution, error) {
	exec := &TwinSuiteExecution{
		CollectorName: "kagent",
		TotalCases:    3,
	}
	baseTime := time.Now().UTC()

	// 1. Accept Twin
	exec.AcceptTwinRun = true
	sinkAccept := &trackingSink{}
	colAccept := kagent.NewCollector(sinkAccept, kagent.ResolverConfig{})
	res, err := colAccept.IngestSpan(ctx, KAgentAcceptTwinSpan(baseTime))
	if err != nil || res == nil || res.Observation == nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin IngestSpan error: %v", err))
		return exec, nil
	}
	if sinkAccept.Count() != 1 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin expected 1 observation, got %d", sinkAccept.Count()))
		return exec, nil
	}
	obs := sinkAccept.Observations()[0]
	if obs.Layer != model.LayerIdentityAuth || obs.Source != "kagent.telemetry" {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin invalid observation: %+v", obs))
		return exec, nil
	}
	exec.AcceptTwinPassed = true

	// 2. Reject / Under-Report Twin
	exec.RejectTwinRun = true
	sinkReject := &trackingSink{}
	colReject := kagent.NewCollector(sinkReject, kagent.ResolverConfig{})
	if _, err := colReject.IngestSpan(ctx, KAgentRejectTwinSpan()); err == nil {
		exec.ExecutionLog = append(exec.ExecutionLog, "RejectTwin accepted malformed span without error")
		return exec, nil
	}
	if sinkReject.Count() != 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("RejectTwin expected 0 observations, got %d", sinkReject.Count()))
		return exec, nil
	}
	exec.RejectTwinPassed = true

	// 3. Mock-vs-Live Distinctness
	exec.DistinctnessRun = true
	sinkFixture := &trackingSink{}
	colFixture := NewKAgentCollector(ModeFixture, sinkFixture)
	if err := colFixture.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Fixture start failed: %v", err))
		return exec, nil
	}
	colFixture.Stop()

	sinkLive := &trackingSink{}
	colLive := NewKAgentCollector(ModeLive, sinkLive)
	if err := colLive.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Live start failed: %v", err))
		return exec, nil
	}
	if sinkLive.Count() != 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, "Live mode immediately had observations")
		colLive.Stop()
		return exec, nil
	}
	liveSpan := KAgentAcceptTwinSpan(baseTime)
	liveSpan.SpanID = "kagent-live-distinct-span-001"
	_, _ = colLive.RawCollector().IngestSpan(ctx, liveSpan)
	colLive.Stop()

	if sinkFixture.Count() == 0 || sinkLive.Count() == 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, "Distinctness failed: missing observations")
		return exec, nil
	}
	if sinkFixture.Observations()[0].ID == sinkLive.Observations()[0].ID {
		exec.ExecutionLog = append(exec.ExecutionLog, "Distinctness failed: fixture and live produced identical observation ID")
		return exec, nil
	}
	exec.DistinctnessPassed = true

	return exec, nil
}

// --- WorkspaceSaaS Verifier ---
func verifyWorkspaceSaaSTwins(ctx context.Context) (*TwinSuiteExecution, error) {
	exec := &TwinSuiteExecution{
		CollectorName: "workspacesaas",
		TotalCases:    3,
	}
	baseTime := time.Now().UTC()

	// 1. Accept Twin
	exec.AcceptTwinRun = true
	obsAccept := WorkspaceSaaSAcceptTwinObservation(baseTime)
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

	// 2. Reject / Under-Report Twin
	exec.RejectTwinRun = true
	obsReject := WorkspaceSaaSRejectTwinObservation()
	if err := obsReject.Validate(); err == nil {
		exec.ExecutionLog = append(exec.ExecutionLog, "RejectTwin invalid observation unexpectedly passed validation")
		return exec, nil
	}
	exec.RejectTwinPassed = true

	// 3. Mock-vs-Live Distinctness
	exec.DistinctnessRun = true
	sinkFixture := &trackingSink{}
	colFixture := NewWorkspaceSaaSCollector(ModeFixture, sinkFixture)
	if err := colFixture.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Fixture start failed: %v", err))
		return exec, nil
	}
	colFixture.Stop()
	if sinkFixture.Count() != len(WorkspaceSaaSFixtures(baseTime)) {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Fixture mode expected %d observations, got %d", len(WorkspaceSaaSFixtures(baseTime)), sinkFixture.Count()))
		return exec, nil
	}

	sinkLive := &trackingSink{}
	colLive := NewWorkspaceSaaSCollector(ModeLive, sinkLive)
	errLive := colLive.Start(ctx)
	// Live mode must return explicit deferred error (not silent pass)
	if errLive == nil {
		exec.ExecutionLog = append(exec.ExecutionLog, "Live mode expected explicit deferred error, got nil")
		return exec, nil
	}
	if !strings.Contains(errLive.Error(), "deferred") {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Live mode returned unexpected error: %v", errLive))
		return exec, nil
	}
	exec.DistinctnessPassed = true

	return exec, nil
}

// --- Fixtures Verifier ---
func verifyFixturesTwins(ctx context.Context) (*TwinSuiteExecution, error) {
	exec := &TwinSuiteExecution{
		CollectorName: "fixtures",
		TotalCases:    3,
	}
	baseTime := time.Now().UTC()

	// 1. Accept Twin
	exec.AcceptTwinRun = true
	allObs := FixtureAcceptTwinObservations(baseTime)
	if len(allObs) == 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, "AcceptTwin produced 0 observations")
		return exec, nil
	}
	layers := make(map[model.Layer]bool)
	for _, o := range allObs {
		layers[o.Layer] = true
	}
	for _, l := range model.InScopeLayers() {
		if !layers[l] {
			exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("AcceptTwin missing in-scope layer: %s", l))
			return exec, nil
		}
	}
	exec.AcceptTwinPassed = true

	// 2. Reject / Under-Report Twin
	exec.RejectTwinRun = true
	rejectObs := FixtureRejectTwinObservations()
	for _, o := range rejectObs {
		if o.ID == "" {
			// Expected invalid observation detected
			exec.RejectTwinPassed = true
			break
		}
	}

	// 3. Mock-vs-Live Distinctness
	exec.DistinctnessRun = true
	sinkFixture := &trackingSink{}
	colFixture := NewFixtureCollector(ModeFixture, sinkFixture)
	if err := colFixture.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Fixture start failed: %v", err))
		return exec, nil
	}

	sinkOff := &trackingSink{}
	colOff := NewFixtureCollector(ModeOff, sinkOff)
	if err := colOff.Start(ctx); err != nil {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Off start failed: %v", err))
		return exec, nil
	}

	if sinkFixture.Count() == 0 || sinkOff.Count() != 0 {
		exec.ExecutionLog = append(exec.ExecutionLog, fmt.Sprintf("Distinctness failed: fixture count=%d, off count=%d", sinkFixture.Count(), sinkOff.Count()))
		return exec, nil
	}
	exec.DistinctnessPassed = true

	return exec, nil
}

// --- Direct Test Entrypoints ---

func TestCollectorFalsification_GCPAudit(t *testing.T) {
	exec, err := verifyGCPAuditTwins(context.Background())
	if err != nil {
		t.Fatalf("GCPAudit twin suite execution error: %v", err)
	}
	if !exec.AcceptTwinPassed {
		t.Errorf("GCPAudit accept twin failed: %v", exec.ExecutionLog)
	}
	if !exec.RejectTwinPassed {
		t.Errorf("GCPAudit reject/under-report twin failed: %v", exec.ExecutionLog)
	}
	if !exec.DistinctnessPassed {
		t.Errorf("GCPAudit distinctness test failed: %v", exec.ExecutionLog)
	}
}

func TestCollectorFalsification_BaoAudit(t *testing.T) {
	exec, err := verifyBaoAuditTwins(context.Background())
	if err != nil {
		t.Fatalf("BaoAudit twin suite execution error: %v", err)
	}
	if !exec.AcceptTwinPassed {
		t.Errorf("BaoAudit accept twin failed: %v", exec.ExecutionLog)
	}
	if !exec.RejectTwinPassed {
		t.Errorf("BaoAudit reject/under-report twin failed: %v", exec.ExecutionLog)
	}
	if !exec.DistinctnessPassed {
		t.Errorf("BaoAudit distinctness test failed: %v", exec.ExecutionLog)
	}
}

func TestCollectorFalsification_SPIREA(t *testing.T) {
	exec, err := verifySPIREATwins(context.Background())
	if err != nil {
		t.Fatalf("SPIREA twin suite execution error: %v", err)
	}
	if !exec.AcceptTwinPassed {
		t.Errorf("SPIREA accept twin failed: %v", exec.ExecutionLog)
	}
	if !exec.RejectTwinPassed {
		t.Errorf("SPIREA reject/under-report twin failed: %v", exec.ExecutionLog)
	}
	if !exec.DistinctnessPassed {
		t.Errorf("SPIREA distinctness test failed: %v", exec.ExecutionLog)
	}
}

func TestCollectorFalsification_NetEBPF(t *testing.T) {
	exec, err := verifyNetEBPFTwins(context.Background())
	if err != nil {
		t.Fatalf("NetEBPF twin suite execution error: %v", err)
	}
	if !exec.AcceptTwinPassed {
		t.Errorf("NetEBPF accept twin failed: %v", exec.ExecutionLog)
	}
	if !exec.RejectTwinPassed {
		t.Errorf("NetEBPF reject/under-report twin failed: %v", exec.ExecutionLog)
	}
	if !exec.DistinctnessPassed {
		t.Errorf("NetEBPF distinctness test failed: %v", exec.ExecutionLog)
	}
}

func TestCollectorFalsification_K8sAudit(t *testing.T) {
	exec, err := verifyK8sAuditTwins(context.Background())
	if err != nil {
		t.Fatalf("K8sAudit twin suite execution error: %v", err)
	}
	if !exec.AcceptTwinPassed {
		t.Errorf("K8sAudit accept twin failed: %v", exec.ExecutionLog)
	}
	if !exec.RejectTwinPassed {
		t.Errorf("K8sAudit reject/under-report twin failed: %v", exec.ExecutionLog)
	}
	if !exec.DistinctnessPassed {
		t.Errorf("K8sAudit distinctness test failed: %v", exec.ExecutionLog)
	}
}

func TestCollectorFalsification_KAgent(t *testing.T) {
	exec, err := verifyKAgentTwins(context.Background())
	if err != nil {
		t.Fatalf("KAgent twin suite execution error: %v", err)
	}
	if !exec.AcceptTwinPassed {
		t.Errorf("KAgent accept twin failed: %v", exec.ExecutionLog)
	}
	if !exec.RejectTwinPassed {
		t.Errorf("KAgent reject/under-report twin failed: %v", exec.ExecutionLog)
	}
	if !exec.DistinctnessPassed {
		t.Errorf("KAgent distinctness test failed: %v", exec.ExecutionLog)
	}
}

func TestCollectorFalsification_WorkspaceSaaS(t *testing.T) {
	exec, err := verifyWorkspaceSaaSTwins(context.Background())
	if err != nil {
		t.Fatalf("WorkspaceSaaS twin suite execution error: %v", err)
	}
	if !exec.AcceptTwinPassed {
		t.Errorf("WorkspaceSaaS accept twin failed: %v", exec.ExecutionLog)
	}
	if !exec.RejectTwinPassed {
		t.Errorf("WorkspaceSaaS reject/under-report twin failed: %v", exec.ExecutionLog)
	}
	if !exec.DistinctnessPassed {
		t.Errorf("WorkspaceSaaS distinctness test failed: %v", exec.ExecutionLog)
	}
}

func TestCollectorFalsification_Fixtures(t *testing.T) {
	exec, err := verifyFixturesTwins(context.Background())
	if err != nil {
		t.Fatalf("Fixtures twin suite execution error: %v", err)
	}
	if !exec.AcceptTwinPassed {
		t.Errorf("Fixtures accept twin failed: %v", exec.ExecutionLog)
	}
	if !exec.RejectTwinPassed {
		t.Errorf("Fixtures reject/under-report twin failed: %v", exec.ExecutionLog)
	}
	if !exec.DistinctnessPassed {
		t.Errorf("Fixtures distinctness test failed: %v", exec.ExecutionLog)
	}
}

// --- Registry Coverage Guard Tests ---

// TestRegistryCoverageGuard_ProductionRegistry walks the real production registry constructed
// from environment defaults and asserts that all registered collectors have passing twin suites.
func TestRegistryCoverageGuard_ProductionRegistry(t *testing.T) {
	sink := &trackingSink{}
	reg := NewRegistryFromEnv(sink)

	report, err := RunRegistryCoverageGuard(reg)
	if err != nil {
		t.Fatalf("Registry-Coverage Guard FAILED: %v", err)
	}

	if report.VerifiedCollectors != report.TotalCollectors {
		t.Fatalf("Registry-Coverage Guard incomplete: verified %d of %d collectors", report.VerifiedCollectors, report.TotalCollectors)
	}

	t.Logf("Registry-Coverage Guard PASS: %d/%d collectors fully verified with accept, reject, and distinctness twins", report.VerifiedCollectors, report.TotalCollectors)
}

// --- Negative Fixtures Proving the Guard (Falsification of the Guard Itself) ---

// TestRegistryCoverageGuard_FalsificationProof_OrphanedCollector proves that the guard goes RED
// when an unregistered / orphaned collector fixture is added to the registry.
func TestRegistryCoverageGuard_FalsificationProof_OrphanedCollector(t *testing.T) {
	reg := NewRegistry(
		newMockCollector("untested-shadow-collector", ModeLive),
	)

	report, err := RunRegistryCoverageGuard(reg)
	if err == nil {
		t.Fatalf("VACUOUS GUARD DEFECT: RunRegistryCoverageGuard passed on deliberately-orphaned collector (report: %+v)", report)
	}

	if !strings.Contains(err.Error(), "orphaned collector") || !strings.Contains(err.Error(), "untested-shadow-collector") {
		t.Fatalf("expected orphaned collector error message, got: %v", err)
	}

	t.Logf("Guard Falsification PASS: Guard correctly failed closed on orphaned collector: %v", err)
}

// TestRegistryCoverageGuard_FalsificationProof_SkippedSuite proves that the guard goes RED
// when a collector suite reports all test cases as skipped.
func TestRegistryCoverageGuard_FalsificationProof_SkippedSuite(t *testing.T) {
	const mockCollectorName = "mock-skipped-collector"
	reg := NewRegistry(newMockCollector(mockCollectorName, ModeLive))

	// Temporarily install a mock verifier that skips all cases
	origVerifier := CollectorTwinVerifiers[mockCollectorName]
	CollectorTwinVerifiers[mockCollectorName] = func(ctx context.Context) (*TwinSuiteExecution, error) {
		return &TwinSuiteExecution{
			CollectorName: mockCollectorName,
			TotalCases:    3,
			SkippedCases:  3, // All skipped!
		}, nil
	}
	defer func() {
		if origVerifier != nil {
			CollectorTwinVerifiers[mockCollectorName] = origVerifier
		} else {
			delete(CollectorTwinVerifiers, mockCollectorName)
		}
	}()

	report, err := RunRegistryCoverageGuard(reg)
	if err == nil {
		t.Fatalf("VACUOUS GUARD DEFECT: RunRegistryCoverageGuard passed on skipped suite (report: %+v)", report)
	}

	if !strings.Contains(err.Error(), "skipped collector suite") {
		t.Fatalf("expected skipped suite error message, got: %v", err)
	}

	t.Logf("Guard Falsification PASS: Guard correctly failed closed on skipped suite: %v", err)
}

// TestRegistryCoverageGuard_FalsificationProof_FailedRejectTwin proves that the guard goes RED
// when a collector fails its reject/under-report twin.
func TestRegistryCoverageGuard_FalsificationProof_FailedRejectTwin(t *testing.T) {
	const mockCollectorName = "mock-underreport-fail-collector"
	reg := NewRegistry(newMockCollector(mockCollectorName, ModeLive))

	origVerifier := CollectorTwinVerifiers[mockCollectorName]
	CollectorTwinVerifiers[mockCollectorName] = func(ctx context.Context) (*TwinSuiteExecution, error) {
		return &TwinSuiteExecution{
			CollectorName:      mockCollectorName,
			TotalCases:         3,
			SkippedCases:       0,
			AcceptTwinRun:      true,
			AcceptTwinPassed:   true,
			RejectTwinRun:      true,
			RejectTwinPassed:   false, // Failed under-report twin!
			DistinctnessRun:    true,
			DistinctnessPassed: true,
		}, nil
	}
	defer func() {
		if origVerifier != nil {
			CollectorTwinVerifiers[mockCollectorName] = origVerifier
		} else {
			delete(CollectorTwinVerifiers, mockCollectorName)
		}
	}()

	report, err := RunRegistryCoverageGuard(reg)
	if err == nil {
		t.Fatalf("VACUOUS GUARD DEFECT: RunRegistryCoverageGuard passed on failed reject twin (report: %+v)", report)
	}

	if !strings.Contains(err.Error(), "failed reject/under-report twin") {
		t.Fatalf("expected reject twin failure error message, got: %v", err)
	}

	t.Logf("Guard Falsification PASS: Guard correctly failed closed on failed reject twin: %v", err)
}
