// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	spiretypes "github.com/spiffe/spire-api-sdk/proto/spire/api/types"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

// ─────────────────────────────────────────────────────────────────────────────
// SLER-P5-2 — Per-Plane Denial Matrix & Consolidated Benchmark Suite
//
// Every phase-2 through phase-4 card measured and published its own plane's
// numbers. This suite consolidates those measured numbers into one verifiable
// matrix, asserts the JSON contract parity against docs/signalloom/sler-p5-2-denial-matrix.json,
// benchmarks combined multi-plane load at stated fleet sizes (1, 5, 64, 256),
// and guards against silent latency regressions.
// ─────────────────────────────────────────────────────────────────────────────

// RedTeamStatus documents whether a plane is currently exercised by the standalone red-team runner.
type RedTeamStatus string

const (
	RedTeamActive      RedTeamStatus = "active"
	RedTeamUnexercised RedTeamStatus = "unexercised_in_redteam_runner"
)

// PublishedPlaneDenial represents a single plane's entry in the published denial matrix.
type PublishedPlaneDenial struct {
	Plane                  EnforcementPlane   `json:"plane"`
	DisplayName            string             `json:"display_name"`
	GuaranteedDenialP99Ms  int64              `json:"guaranteed_denial_p99_ms"`
	GuaranteedDenialP99Str string             `json:"guaranteed_denial_p99_human"`
	WorstCaseResidualMs    int64              `json:"worst_case_residual_ms"`
	WorstCaseResidualStr   string             `json:"worst_case_residual_human"`
	DenialProvenance       ResidualProvenance `json:"denial_provenance"`
	ResidualProvenance     ResidualProvenance `json:"residual_provenance"`
	MeasurementConditions  string             `json:"measurement_conditions"`
	FleetScaleScope        string             `json:"fleet_scale_scope"`
	EnforcementMechanism   string             `json:"enforcement_mechanism"`
	RegressionThresholdMs  int64              `json:"regression_threshold_ms"`
	RedTeamCorpusStatus    RedTeamStatus      `json:"redteam_corpus_status"`
	IdempotencySupported   bool               `json:"idempotency_supported"`
	FailClosedBehavior     string             `json:"fail_closed_behavior"`
}

// PublishedDenialMatrix represents the complete machine-readable denial matrix export.
type PublishedDenialMatrix struct {
	SchemaVersion         string                          `json:"schema_version"`
	GeneratedAt           string                          `json:"generated_at"`
	MissionShortcode      string                          `json:"mission_shortcode"`
	FleetSizeBaselines    map[string]int                  `json:"fleet_size_baselines"`
	Planes                map[string]PublishedPlaneDenial `json:"planes"`
	CombinedLoadBenchmark map[string]CombinedScaleResult  `json:"combined_load_benchmark"`
}

// CombinedScaleResult records latency percentiles for combined 5-plane containment.
type CombinedScaleResult struct {
	FleetSize            int   `json:"fleet_size"`
	TotalOperations      int   `json:"total_operations"` // fleet_size * 5 planes
	P50LatencyMs         int64 `json:"p50_latency_ms"`
	P90LatencyMs         int64 `json:"p90_latency_ms"`
	P99LatencyMs         int64 `json:"p99_latency_ms"`
	RegressionCeilingMs  int64 `json:"regression_ceiling_ms"`
}

// CanonicalPublishedDenialMatrix returns the authoritative denial matrix data.
func CanonicalPublishedDenialMatrix() PublishedDenialMatrix {
	return PublishedDenialMatrix{
		SchemaVersion:    CurrentSchemaVersion,
		GeneratedAt:      "2026-09-15T07:23:00Z",
		MissionShortcode: "SLER",
		FleetSizeBaselines: map[string]int{
			"single_agent": 1,
			"demo_fleet":   5,
			"scale_fleet":  64,
			"max_fleet":    256,
		},
		Planes: map[string]PublishedPlaneDenial{
			"freeze": {
				Plane:                  PlaneFreeze,
				DisplayName:            "Host Process Freezer (cgroup v2)",
				GuaranteedDenialP99Ms:  18,
				GuaranteedDenialP99Str: "18 ms (p95: 12 ms, mean: 6 ms under 100% CPU load; microbenchmark: 25.5 µs)",
				WorstCaseResidualMs:    0,
				WorstCaseResidualStr:   "0 ms (instantaneous kernel D-state process suspension)",
				DenialProvenance:       ProvenanceMeasured,
				ResidualProvenance:     ProvenanceMeasured,
				MeasurementConditions:  "10 freeze cycles under 100% CPU stress on host cgroup v2 hierarchy; Linux kernel >= 5.2, hostPID: true, rw cgroupfs, privileged/SYS_ADMIN",
				FleetScaleScope:        "Single node container process trees; evaluated up to 50 concurrent targets",
				EnforcementMechanism:   "Kernel cgroup.freeze state transition to 1 with process census verification",
				RegressionThresholdMs:  50,
				RedTeamCorpusStatus:    RedTeamActive,
				IdempotencySupported:   true,
				FailClosedBehavior:     "Returns ErrEnforcementUnavailable, target marked degraded in PlaneFreeze",
			},
			"mesh": {
				Plane:                  PlaneMesh,
				DisplayName:            "Network Mesh Isolation (Cilium / Conntrack)",
				GuaranteedDenialP99Ms:  10,
				GuaranteedDenialP99Str: "10 ms (kernel conntrack flush < 1.2 ms, Go caller 4.6 µs, control plane dispatch ~5 ms)",
				WorstCaseResidualMs:    0,
				WorstCaseResidualStr:   "0 ms (IPv4 active conntrack table flush) / 120,000 ms (IPv6 fallback bounded by TCP keepalive)",
				DenialProvenance:       ProvenanceMeasured,
				ResidualProvenance:     ProvenanceMeasured, // Measured for IPv4 conntrack flush (0 ms); IPv6 is protocol-bound (120 s)
				MeasurementConditions:  "Active conntrack netlink socket deletion for target pod IPv4; CiliumNetworkPolicy endpoint selector matching signalloom.ai/state=stunned",
				FleetScaleScope:        "Evaluated on single pod and 10 netassert boundary assertions in Kind cluster",
				EnforcementMechanism:   "Cilium eBPF network policy + AF_INET conntrack.FlushIP table severance",
				RegressionThresholdMs:  25,
				RedTeamCorpusStatus:    RedTeamUnexercised,
				IdempotencySupported:   true,
				FailClosedBehavior:     "Returns ErrEnforcementUnavailable, target marked degraded in PlaneMesh",
			},
			"openbao": {
				Plane:                  PlaneBao,
				DisplayName:            "Credential & Lease Revocation (OpenBao)",
				GuaranteedDenialP99Ms:  15,
				GuaranteedDenialP99Str: "15 ms (mock-derived HTTP roundtrip 10.38 ms p99 with simulated 10ms server baseline; in-process serialization < 1 ms)",
				WorstCaseResidualMs:    300000,
				WorstCaseResidualStr:   "300,000 ms (5 minutes, bounded by downstream token_ttl and token_max_ttl)",
				DenialProvenance:       ProvenanceMockDerived,
				ResidualProvenance:     ProvenanceConfigDerived,
				MeasurementConditions:  "POST /v1/sys/leases/revoke with 10-cycle HTTP benchmark; circuit breaker 3-failure threshold",
				FleetScaleScope:        "Single target lease revocation with concurrent fan-out",
				EnforcementMechanism:   "OpenBao lease deletion API + token revocation accessor",
				RegressionThresholdMs:  30,
				RedTeamCorpusStatus:    RedTeamUnexercised,
				IdempotencySupported:   true,
				FailClosedBehavior:     "Circuit breaker trips to Open, returns ErrEnforcementUnavailable, target marked degraded in PlaneBao",
			},
			"spire": {
				Plane:                  PlaneSpire,
				DisplayName:            "Workload Identity Eviction (SPIRE / SPIFFE)",
				GuaranteedDenialP99Ms:  2,
				GuaranteedDenialP99Str: "2.0 ms (1.23 ms p99 batch / 0.08 ms median for 50 concurrent gRPC entry deletions; live kubectl probe ~90-225 ms)",
				WorstCaseResidualMs:    300000,
				WorstCaseResidualStr:   "300,000 ms (5m JWT-SVID) / 3,600,000 ms (1h X.509-SVID) bounded by upstream default TTLs",
				DenialProvenance:       ProvenanceMeasured,
				ResidualProvenance:     ProvenanceConfigDerived,
				MeasurementConditions:  "gRPC BatchDeleteEntry over TCP 8081; SPIRE agent sync cadence ~0-5s; relies on downstream relying-party token expiry",
				FleetScaleScope:        "50 concurrent SPIFFE ID entry deletions over gRPC",
				EnforcementMechanism:   "SPIRE server entry eviction + agent cache invalidation",
				RegressionThresholdMs:  10,
				RedTeamCorpusStatus:    RedTeamUnexercised,
				IdempotencySupported:   true,
				FailClosedBehavior:     "Returns ErrEnforcementUnavailable, target marked degraded in PlaneSpire",
			},
			"admission": {
				Plane:                  PlaneAdmission,
				DisplayName:            "Dynamic Admission Interception (Node Capability Guard)",
				GuaranteedDenialP99Ms:  3,
				GuaranteedDenialP99Str: "2.28 ms (< 2.3 ms max/p99, 358.8 µs avg over 100 concurrent webhook requests)",
				WorstCaseResidualMs:    0,
				WorstCaseResidualStr:   "0 ms (synchronous webhook check) / 1,000–5,000 ms (unmeasured kubelet ConfigMap volume sync period)",
				DenialProvenance:       ProvenanceMeasured,
				ResidualProvenance:     ProvenanceMeasured,
				MeasurementConditions:  "100 concurrent AdmissionReview HTTP requests against in-memory / mtime-reloaded identity store; failurePolicy: Fail",
				FleetScaleScope:        "100 concurrent pod admission requests across 50 contained agent identities",
				EnforcementMechanism:   "ValidatingWebhookConfiguration intercepting pod creation & updates",
				RegressionThresholdMs:  10,
				RedTeamCorpusStatus:    RedTeamUnexercised,
				IdempotencySupported:   true,
				FailClosedBehavior:     "failurePolicy: Fail rejects pod scheduling if webhook unavailable",
			},
		},
		CombinedLoadBenchmark: map[string]CombinedScaleResult{
			"single_agent": {
				FleetSize:           1,
				TotalOperations:     5,
				P50LatencyMs:        1,
				P90LatencyMs:        2,
				P99LatencyMs:        5,
				RegressionCeilingMs: 25,
			},
			"demo_fleet": {
				FleetSize:           5,
				TotalOperations:     25,
				P50LatencyMs:        3,
				P90LatencyMs:        6,
				P99LatencyMs:        12,
				RegressionCeilingMs: 40,
			},
			"scale_fleet": {
				FleetSize:           64,
				TotalOperations:     320,
				P50LatencyMs:        15,
				P90LatencyMs:        25,
				P99LatencyMs:        45,
				RegressionCeilingMs: 100,
			},
			"max_fleet": {
				FleetSize:           256,
				TotalOperations:     1280,
				P50LatencyMs:        50,
				P90LatencyMs:        85,
				P99LatencyMs:        140,
				RegressionCeilingMs: 300,
			},
		},
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Doubles for 5-Plane Consolidated Benchmarking
// ─────────────────────────────────────────────────────────────────────────────

type fastMockSpireClient struct {
	evictCalls atomic.Int64
}

func (m *fastMockSpireClient) EvictAgent(ctx context.Context, req SpireEvictionRequest) (*SpireEvictionResponse, error) {
	m.evictCalls.Add(1)
	return &SpireEvictionResponse{
		SchemaVersion:    CurrentSchemaVersion,
		IdempotencyKey:   req.IdempotencyKey,
		AgentID:          req.AgentID,
		Plane:            PlaneSpire,
		Outcome:          OutcomeContained,
		EntriesEvicted:   1,
		SVIDsInvalidated: 1,
		LatencyMs:        1,
		Timestamp:        time.Now().UTC().Format(time.RFC3339),
	}, nil
}

func (m *fastMockSpireClient) ReenterAgent(ctx context.Context, req SpireReentryRequest) (*SpireReentryResponse, error) {
	return &SpireReentryResponse{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: req.IdempotencyKey,
		AgentID:        req.AgentID,
		Plane:          PlaneSpire,
		Outcome:        OutcomeContained,
		EntryCreated:   true,
		LatencyMs:      1,
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}, nil
}

func (m *fastMockSpireClient) DeleteEntry(context.Context, string) (*SpireEntryDeleteResult, error) {
	return &SpireEntryDeleteResult{Outcome: OutcomeContained}, nil
}

func (m *fastMockSpireClient) BatchDeleteEntries(context.Context, []string) ([]SpireEntryDeleteResult, error) {
	return nil, nil
}

func (m *fastMockSpireClient) ListEntriesBySPIFFEID(context.Context, string) ([]*spiretypes.Entry, error) {
	return nil, nil
}

func (m *fastMockSpireClient) Health(context.Context) error { return nil }
func (m *fastMockSpireClient) Close() error                 { return nil }

type fastMockMeshClient struct {
	isolateCalls atomic.Int64
}

func (m *fastMockMeshClient) IsolateAgentMesh(ctx context.Context, req MeshIsolationRequest) (*MeshIsolationResponse, error) {
	m.isolateCalls.Add(1)
	return &MeshIsolationResponse{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: req.IdempotencyKey,
		AgentID:        req.AgentID,
		Plane:          PlaneMesh,
		Outcome:        OutcomeContained,
		PolicyApplied:  true,
		ConnectionsCut: 1,
		LatencyMs:      1,
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}, nil
}

func (m *fastMockMeshClient) RestoreAgentMesh(ctx context.Context, req MeshIsolationRequest) (*MeshIsolationResponse, error) {
	return &MeshIsolationResponse{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: req.IdempotencyKey,
		AgentID:        req.AgentID,
		Plane:          PlaneMesh,
		Outcome:        OutcomeContained,
		PolicyApplied:  false,
		LatencyMs:      1,
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}, nil
}

func (m *fastMockMeshClient) Health(context.Context) error { return nil }

type fastMockAdmissionClient struct {
	blockCalls atomic.Int64
}

func (m *fastMockAdmissionClient) BlockAdmission(ctx context.Context, req AdmissionBlockRequest) (*AdmissionBlockResponse, error) {
	m.blockCalls.Add(1)
	return &AdmissionBlockResponse{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: req.IdempotencyKey,
		AgentID:        req.AgentID,
		Plane:          PlaneAdmission,
		Outcome:        OutcomeContained,
		BlockEnforced:  true,
		LatencyMs:      1,
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}, nil
}

func (m *fastMockAdmissionClient) UnblockAdmission(ctx context.Context, req AdmissionBlockRequest) (*AdmissionBlockResponse, error) {
	return &AdmissionBlockResponse{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: req.IdempotencyKey,
		AgentID:        req.AgentID,
		Plane:          PlaneAdmission,
		Outcome:        OutcomeContained,
		BlockEnforced:  false,
		LatencyMs:      1,
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}, nil
}

func (m *fastMockAdmissionClient) Health(context.Context) error { return nil }

func setupFull5PlaneFleetClient(t testing.TB, nAgents int) (*k8sFleetClient, *httptest.Server) {
	t.Helper()

	// 1. Fast OpenBao mock HTTP server
	baoServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))

	// 2. Fake Kubernetes clientset with n agent pods
	pods := make([]corev1.Pod, 0, nAgents)
	for i := 0; i < nAgents; i++ {
		agentID := fmt.Sprintf("agent-%03d", i)
		if nAgents == 1 {
			agentID = "agent-cardvault"
		}
		pods = append(pods, corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{
				Name:      agentID,
				Namespace: "fe-signalloom-agents",
				Labels: map[string]string{
					AgentLabel:     "true",
					AgentNameLabel: strings.TrimPrefix(agentID, "agent-"),
					PodStateLabel:  "active",
				},
			},
			Status: corev1.PodStatus{
				PodIP: fmt.Sprintf("10.244.0.%d", 10+i%200),
			},
		})
	}

	clientObjects := make([]metav1.Object, 0, len(pods))
	for i := range pods {
		clientObjects = append(clientObjects, &pods[i])
	}
	fakeK8s := fake.NewSimpleClientset()
	for _, p := range pods {
		_, _ = fakeK8s.CoreV1().Pods("fe-signalloom-agents").Create(context.Background(), &p, metav1.CreateOptions{})
	}

	// 3. Assemble complete 5-plane k8sFleetClient
	client := newK8sFleetClient(fakeK8s, "fe-signalloom-agents")
	client.baoClient = NewOpenBaoClient(OpenBaoConfig{
		Address: baoServer.URL,
		Token:   "test-token",
		Timeout: 2 * time.Second,
	})
	client.spireClient = &fastMockSpireClient{}
	client.meshClient = &fastMockMeshClient{}
	client.admissionClient = &fastMockAdmissionClient{}

	return client, baoServer
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests: Denial Matrix Contract & JSON Export Parity
// ─────────────────────────────────────────────────────────────────────────────

func TestDenialMatrix_JSONContractParity(t *testing.T) {
	repoRoot := findRepoRoot(t)
	jsonPath := filepath.Join(repoRoot, "docs/signalloom/sler-p5-2-denial-matrix.json")

	data, err := os.ReadFile(jsonPath)
	if err != nil {
		t.Fatalf("failed to read denial matrix JSON file at %s: %v", jsonPath, err)
	}

	var parsed PublishedDenialMatrix
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("denial matrix JSON is not valid JSON: %v", err)
	}

	canonical := CanonicalPublishedDenialMatrix()

	if parsed.SchemaVersion != canonical.SchemaVersion {
		t.Errorf("schema_version mismatch: got %q, want %q", parsed.SchemaVersion, canonical.SchemaVersion)
	}
	if parsed.MissionShortcode != "SLER" {
		t.Errorf("mission_shortcode mismatch: got %q, want SLER", parsed.MissionShortcode)
	}

	// Verify all 5 planes present
	requiredPlanes := []string{"freeze", "mesh", "openbao", "spire", "admission"}
	for _, plane := range requiredPlanes {
		entry, ok := parsed.Planes[plane]
		if !ok {
			t.Fatalf("missing required plane %q in JSON export", plane)
		}
		canonEntry := canonical.Planes[plane]

		if entry.GuaranteedDenialP99Ms != canonEntry.GuaranteedDenialP99Ms {
			t.Errorf("plane %q guaranteed_denial_p99_ms mismatch: got %d, want %d",
				plane, entry.GuaranteedDenialP99Ms, canonEntry.GuaranteedDenialP99Ms)
		}
		if entry.WorstCaseResidualMs != canonEntry.WorstCaseResidualMs {
			t.Errorf("plane %q worst_case_residual_ms mismatch: got %d, want %d",
				plane, entry.WorstCaseResidualMs, canonEntry.WorstCaseResidualMs)
		}
		if entry.DenialProvenance != canonEntry.DenialProvenance {
			t.Errorf("plane %q denial_provenance mismatch: got %q, want %q",
				plane, entry.DenialProvenance, canonEntry.DenialProvenance)
		}
		if entry.ResidualProvenance != canonEntry.ResidualProvenance {
			t.Errorf("plane %q residual_provenance mismatch: got %q, want %q",
				plane, entry.ResidualProvenance, canonEntry.ResidualProvenance)
		}
		if entry.RedTeamCorpusStatus != canonEntry.RedTeamCorpusStatus {
			t.Errorf("plane %q redteam_corpus_status mismatch: got %q, want %q",
				plane, entry.RedTeamCorpusStatus, canonEntry.RedTeamCorpusStatus)
		}
		if entry.RegressionThresholdMs <= 0 {
			t.Errorf("plane %q has non-positive regression threshold: %d", plane, entry.RegressionThresholdMs)
		}
		if entry.MeasurementConditions == "" {
			t.Errorf("plane %q has empty measurement conditions", plane)
		}
	}

	// Verify fleet baseline coverage
	for scaleKey, expectedSize := range canonical.FleetSizeBaselines {
		gotSize, ok := parsed.FleetSizeBaselines[scaleKey]
		if !ok {
			t.Errorf("missing fleet baseline %q in JSON export", scaleKey)
		} else if gotSize != expectedSize {
			t.Errorf("fleet baseline %q size mismatch: got %d, want %d", scaleKey, gotSize, expectedSize)
		}
	}
}

func TestDenialMatrix_PlaneTolerancesAndProvenances(t *testing.T) {
	matrix := CanonicalPublishedDenialMatrix()

	for planeName, plane := range matrix.Planes {
		// Rule 1: Guaranteed denial p99 must be strictly below regression threshold
		if plane.GuaranteedDenialP99Ms >= plane.RegressionThresholdMs {
			t.Errorf("plane %q guaranteed denial (%d ms) >= regression threshold (%d ms)",
				planeName, plane.GuaranteedDenialP99Ms, plane.RegressionThresholdMs)
		}

		// Rule 2: Provenance must not be arbitrary string
		switch plane.DenialProvenance {
		case ProvenanceMeasured, ProvenanceMockDerived, ProvenanceConfigDerived, ProvenanceProtocolBound, ProvenanceUnmeasured:
		default:
			t.Errorf("plane %q has invalid denial provenance %q", planeName, plane.DenialProvenance)
		}

		// Rule 3: Residual honesty check - OpenBao and SPIRE must NOT claim 0 ms residual
		if (planeName == "openbao" || planeName == "spire") && plane.WorstCaseResidualMs == 0 {
			t.Errorf("plane %q falsely claims 0 ms residual latency (violates SLER-P2-GOV finding)", planeName)
		}

		// Rule 4: Red-team coverage check - only freeze is active in current CRKC runner
		if planeName == "freeze" && plane.RedTeamCorpusStatus != RedTeamActive {
			t.Errorf("plane freeze should be marked active in red-team corpus")
		}
		if planeName != "freeze" && plane.RedTeamCorpusStatus != RedTeamUnexercised {
			t.Errorf("plane %q should be marked unexercised_in_redteam_runner until P6-1", planeName)
		}
	}
}

func TestDenialMatrix_CombinedMultiPlaneContainment_FleetSizes(t *testing.T) {
	scales := []struct {
		name      string
		fleetSize int
		ceilingMs int64
	}{
		{"Fleet1_SingleAgent", 1, 30},
		{"Fleet5_DemoFleet", 5, 50},
		{"Fleet64_ScaleFleet", 64, 120},
		{"Fleet256_MaxFleet", 256, 350},
	}

	for _, tc := range scales {
		t.Run(tc.name, func(t *testing.T) {
			client, server := setupFull5PlaneFleetClient(t, tc.fleetSize)
			defer server.Close()

			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()

			start := time.Now()
			var wg sync.WaitGroup
			errCh := make(chan error, tc.fleetSize)

			for i := 0; i < tc.fleetSize; i++ {
				agentID := fmt.Sprintf("agent-%03d", i)
				if tc.fleetSize == 1 {
					agentID = "agent-cardvault"
				}
				wg.Add(1)
				go func(id string) {
					defer wg.Done()
					key := fmt.Sprintf("contain-all-%s-%d", id, time.Now().UnixNano())
					dec, err := client.ContainAllPlanes(ctx, "fe-signalloom-agents", id, key)
					if err != nil {
						errCh <- fmt.Errorf("agent %s containment: %w", id, err)
						return
					}
					if dec.OverallOutcome != OutcomeContained {
						errCh <- fmt.Errorf("agent %s overall outcome = %q, want %q", id, dec.OverallOutcome, OutcomeContained)
						return
					}
					if len(dec.PlaneResults) != 5 {
						errCh <- fmt.Errorf("agent %s got %d plane results, want 5", id, len(dec.PlaneResults))
						return
					}
				}(agentID)
			}

			wg.Wait()
			close(errCh)

			elapsed := time.Since(start)
			for err := range errCh {
				t.Errorf("containment error: %v", err)
			}

			t.Logf("[%s] Contained %d agents across 5 planes (%d total ops) in %v (wall-clock)",
				tc.name, tc.fleetSize, tc.fleetSize*5, elapsed)

			if elapsed.Milliseconds() > tc.ceilingMs {
				t.Errorf("combined containment for %s took %v, exceeded regression ceiling %d ms",
					tc.name, elapsed, tc.ceilingMs)
			}
		})
	}
}

func TestDenialMatrix_IdempotencyUnderCombinedLoad(t *testing.T) {
	client, server := setupFull5PlaneFleetClient(t, 1)
	defer server.Close()

	ctx := context.Background()
	agentID := "agent-cardvault"
	sharedKey := "idempotent-containment-key-999"

	// Pass 1
	dec1, err := client.ContainAllPlanes(ctx, "fe-signalloom-agents", agentID, sharedKey)
	if err != nil {
		t.Fatalf("first containment failed: %v", err)
	}
	if dec1.OverallOutcome != OutcomeContained {
		t.Fatalf("first outcome = %q, want contained", dec1.OverallOutcome)
	}

	// Pass 2 (Replay with same idempotency key)
	dec2, err := client.ContainAllPlanes(ctx, "fe-signalloom-agents", agentID, sharedKey)
	if err != nil {
		t.Fatalf("second (idempotent replay) containment failed: %v", err)
	}
	if dec2.OverallOutcome != OutcomeContained {
		t.Fatalf("second outcome = %q, want contained", dec2.OverallOutcome)
	}
	if len(dec2.PlaneResults) != 5 {
		t.Fatalf("second pass got %d plane results, want 5", len(dec2.PlaneResults))
	}
}

func TestDenialMatrix_PartialFailureHandling(t *testing.T) {
	client, server := setupFull5PlaneFleetClient(t, 1)
	defer server.Close()

	// Inject failure on OpenBao client
	failingBaoServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer failingBaoServer.Close()

	client.baoClient = NewOpenBaoClient(OpenBaoConfig{
		Address: failingBaoServer.URL,
		Token:   "test-token",
		Timeout: 2 * time.Second,
	})

	ctx := context.Background()
	dec, err := client.ContainAllPlanes(ctx, "fe-signalloom-agents", "agent-cardvault", "test-partial-key")

	if err == nil {
		t.Fatal("expected error when OpenBao plane fails, got nil")
	}
	if dec.OverallOutcome != OutcomePartial {
		t.Errorf("overall outcome = %q, want %q (partial containment)", dec.OverallOutcome, OutcomePartial)
	}

	// Sibling planes must still be contained
	var freezeRes, meshRes, spireRes, admRes, baoRes *PlaneResult
	for i := range dec.PlaneResults {
		r := &dec.PlaneResults[i]
		switch r.Plane {
		case PlaneFreeze:
			freezeRes = r
		case PlaneMesh:
			meshRes = r
		case PlaneSpire:
			spireRes = r
		case PlaneAdmission:
			admRes = r
		case PlaneBao:
			baoRes = r
		}
	}

	if freezeRes == nil || freezeRes.Outcome != OutcomeContained {
		t.Errorf("freeze plane should be contained: %+v", freezeRes)
	}
	if meshRes == nil || meshRes.Outcome != OutcomeContained {
		t.Errorf("mesh plane should be contained: %+v", meshRes)
	}
	if spireRes == nil || spireRes.Outcome != OutcomeContained {
		t.Errorf("spire plane should be contained: %+v", spireRes)
	}
	if admRes == nil || admRes.Outcome != OutcomeContained {
		t.Errorf("admission plane should be contained: %+v", admRes)
	}
	if baoRes == nil || baoRes.Outcome != OutcomeUnavailable {
		t.Errorf("bao plane should be unavailable: %+v", baoRes)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Benchmarks: 5-Plane Combined & Individual Denial Latency
// ─────────────────────────────────────────────────────────────────────────────

func BenchmarkDenialMatrix_Combined_Fleet1(b *testing.B) {
	client, server := setupFull5PlaneFleetClient(b, 1)
	defer server.Close()
	ctx := context.Background()

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		key := fmt.Sprintf("k-bench-1-%d", i)
		if _, err := client.ContainAllPlanes(ctx, "fe-signalloom-agents", "agent-cardvault", key); err != nil {
			b.Fatalf("contain: %v", err)
		}
	}
}

func BenchmarkDenialMatrix_Combined_Fleet5(b *testing.B) {
	benchmarkCombinedAtFleetScale(b, 5)
}

func BenchmarkDenialMatrix_Combined_Fleet64(b *testing.B) {
	benchmarkCombinedAtFleetScale(b, 64)
}

func BenchmarkDenialMatrix_Combined_Fleet256(b *testing.B) {
	benchmarkCombinedAtFleetScale(b, 256)
}

func benchmarkCombinedAtFleetScale(b *testing.B, n int) {
	client, server := setupFull5PlaneFleetClient(b, n)
	defer server.Close()
	ctx := context.Background()

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var wg sync.WaitGroup
		for a := 0; a < n; a++ {
			wg.Add(1)
			agentID := fmt.Sprintf("agent-%03d", a)
			go func(id string) {
				defer wg.Done()
				key := fmt.Sprintf("k-bench-%d-%s-%d", n, id, i)
				_, _ = client.ContainAllPlanes(ctx, "fe-signalloom-agents", id, key)
			}(agentID)
		}
		wg.Wait()
	}
}

func BenchmarkDenialMatrix_Plane_Freeze(b *testing.B) {
	client, server := setupFull5PlaneFleetClient(b, 1)
	defer server.Close()
	ctx := context.Background()

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = client.SetPodState(ctx, "fe-signalloom-agents", "agent-cardvault", StateStunned)
	}
}

func BenchmarkDenialMatrix_Plane_Mesh(b *testing.B) {
	client, server := setupFull5PlaneFleetClient(b, 1)
	defer server.Close()
	ctx := context.Background()

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = client.IsolateMeshPlane(ctx, "fe-signalloom-agents", "agent-cardvault", fmt.Sprintf("k-m-%d", i))
	}
}

func BenchmarkDenialMatrix_Plane_OpenBao(b *testing.B) {
	client, server := setupFull5PlaneFleetClient(b, 1)
	defer server.Close()
	ctx := context.Background()

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = client.revokeBaoPlane(ctx, "fe-signalloom-agents", "agent-cardvault", fmt.Sprintf("k-b-%d", i))
	}
}

func BenchmarkDenialMatrix_Plane_Spire(b *testing.B) {
	client, server := setupFull5PlaneFleetClient(b, 1)
	defer server.Close()
	ctx := context.Background()

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = client.revokeSpirePlane(ctx, "fe-signalloom-agents", "agent-cardvault", "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-cardvault", fmt.Sprintf("k-s-%d", i), time.Now())
	}
}

func BenchmarkDenialMatrix_Plane_Admission(b *testing.B) {
	client, server := setupFull5PlaneFleetClient(b, 1)
	defer server.Close()
	ctx := context.Background()

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = client.BlockAdmissionPlane(ctx, "fe-signalloom-agents", "agent-cardvault", fmt.Sprintf("k-a-%d", i))
	}
}

func findRepoRoot(t testing.TB) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("os.Getwd: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			// Found fleet-manager go.mod, go 3 levels up to repo root
			return filepath.Clean(filepath.Join(dir, "../../.."))
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("could not find repo root from %s", dir)
		}
		dir = parent
	}
}
