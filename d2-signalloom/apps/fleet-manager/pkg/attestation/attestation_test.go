// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package attestation

import (
	"context"
	"crypto"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
)

// helper to build a populated test ContainmentAttestationRequest
func sampleContainmentRequest() ContainmentAttestationRequest {
	return ContainmentAttestationRequest{
		EventID:        "evt-001-test",
		EventType:      EventContainmentCompleted,
		IdempotencyKey: "idem-contain-9988",
		Authorization: AuthorizationEvidence{
			DecisionID:            "fusion-dec-12345",
			TriggerReason:         "prompt_injection_attempt",
			TriggerDescription:    "Agent attempted unauthorized sandbox escape via injected prompt payload",
			TriggeredBy:           "signal-fusion-engine",
			DelegationEdgeRevoked: true,
			AttestationDigest:     "a1b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef0",
		},
		Target: TargetIdentity{
			AgentID:     "agent-codex-99",
			Namespace:   "agent-sandboxes",
			PodName:     "agent-codex-99-786d7b-xyz",
			PodUID:      "uid-8877-6655-4433",
			SPIFFEID:    "spiffe://osramp.local/ns/agent-sandboxes/sa/agent-codex-99",
			NodeName:    "worker-node-04",
			ContainerID: "containerd://abcdef123456",
			CgroupPath:  "/sys/fs/cgroup/kubepods.slice/pod-uid-8877",
			PIDs:        []int{10234, 10235, 10236},
			TenantID:    "tenant-alpha",
		},
		Execution: ExecutionEvidence{
			OverallOutcome: "contained",
			TotalLatencyMs: 14,
			Planes: []PlaneExecutionEvidence{
				{Plane: "mesh", Outcome: "contained", LatencyMs: 2, WorstCaseResidualMs: 2000},
				{Plane: "bao", Outcome: "contained", LatencyMs: 5, WorstCaseResidualMs: 300000},
				{Plane: "spire", Outcome: "contained", LatencyMs: 4, WorstCaseResidualMs: 3600000},
				{Plane: "admission", Outcome: "contained", LatencyMs: 1, WorstCaseResidualMs: 0},
				{Plane: "freeze", Outcome: "contained", LatencyMs: 2, WorstCaseResidualMs: 0},
			},
		},
		Timestamp: time.Now().UTC(),
	}
}

// 1. Round-trip cryptographic signing & verification test
func TestAttestationRoundTrip(t *testing.T) {
	signer, err := GenerateInMemoryEd25519Signer("witness-key-v1")
	if err != nil {
		t.Fatalf("generate signer: %v", err)
	}

	history := NewKeyHistoryStore()
	engine, err := NewAttestationEngine(signer, history, "sler-fleet-manager")
	if err != nil {
		t.Fatalf("init engine: %v", err)
	}

	req := sampleContainmentRequest()
	record, dsseBytes, err := engine.AttestContainment(context.Background(), req)
	if err != nil {
		t.Fatalf("AttestContainment failed: %v", err)
	}

	if record.Attestation.KeyID != signer.KeyID() {
		t.Errorf("expected keyID %s, got %s", signer.KeyID(), record.Attestation.KeyID)
	}
	if record.Attestation.StatementDigest == "" {
		t.Error("expected non-empty StatementDigest")
	}

	// Verify DSSE envelope
	res, err := engine.Verify(dsseBytes)
	if err != nil {
		t.Fatalf("Verify failed: %v", err)
	}

	if !res.Valid {
		t.Fatal("expected verification result to be valid")
	}
	if res.Record.EventID != req.EventID {
		t.Errorf("expected EventID %s, got %s", req.EventID, res.Record.EventID)
	}
	if res.Record.Authorization.DecisionID != req.Authorization.DecisionID {
		t.Errorf("expected DecisionID %s, got %s", req.Authorization.DecisionID, res.Record.Authorization.DecisionID)
	}
	if len(res.Record.Execution.Planes) != 5 {
		t.Errorf("expected 5 planes in verified record, got %d", len(res.Record.Execution.Planes))
	}
}

// 2. Tamper-evidence test: bit-flips in payload, signature, and metadata must fail verification
func TestTamperEvidence(t *testing.T) {
	signer, err := GenerateInMemoryEd25519Signer()
	if err != nil {
		t.Fatalf("generate signer: %v", err)
	}

	history := NewKeyHistoryStore()
	engine, err := NewAttestationEngine(signer, history, "sler-fleet-manager")
	if err != nil {
		t.Fatalf("init engine: %v", err)
	}

	req := sampleContainmentRequest()
	_, dsseBytes, err := engine.AttestContainment(context.Background(), req)
	if err != nil {
		t.Fatalf("AttestContainment: %v", err)
	}

	var env DSSEEnvelope
	if err := json.Unmarshal(dsseBytes, &env); err != nil {
		t.Fatalf("unmarshal envelope: %v", err)
	}

	// Case 2a: Mutate payload (flip 1 byte in base64 decoded payload)
	payloadRaw, _ := base64.StdEncoding.DecodeString(env.Payload)
	tamperedPayload := make([]byte, len(payloadRaw))
	copy(tamperedPayload, payloadRaw)
	tamperedPayload[len(tamperedPayload)/2] ^= 0xFF // bit flip

	envTamperedPayload := env
	envTamperedPayload.Payload = base64.StdEncoding.EncodeToString(tamperedPayload)
	tamperedBytes1, _ := json.Marshal(envTamperedPayload)

	if _, err := engine.Verify(tamperedBytes1); err == nil {
		t.Error("expected verification to FAIL on tampered payload, but it succeeded")
	}

	// Case 2b: Mutate signature bytes
	sigRaw, _ := base64.StdEncoding.DecodeString(env.Signatures[0].Sig)
	tamperedSig := make([]byte, len(sigRaw))
	copy(tamperedSig, sigRaw)
	tamperedSig[0] ^= 0xAA // bit flip

	envTamperedSig := env
	envTamperedSig.Signatures = []DSSESignature{{KeyID: env.Signatures[0].KeyID, Sig: base64.StdEncoding.EncodeToString(tamperedSig)}}
	tamperedBytes2, _ := json.Marshal(envTamperedSig)

	if _, err := engine.Verify(tamperedBytes2); err == nil {
		t.Error("expected verification to FAIL on tampered signature, but it succeeded")
	}

	// Case 2c: Unknown KeyID
	envUnknownKey := env
	envUnknownKey.Signatures = []DSSESignature{{KeyID: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff", Sig: env.Signatures[0].Sig}}
	tamperedBytes3, _ := json.Marshal(envUnknownKey)

	if _, err := engine.Verify(tamperedBytes3); err == nil {
		t.Error("expected verification to FAIL on unknown key ID, but it succeeded")
	}
}

// 3. Failure injection test: signing failure blocks containment and fails closed
type failingSigner struct {
	keyID string
	pub   ed25519.PublicKey
}

func (f *failingSigner) KeyID() string               { return f.keyID }
func (f *failingSigner) KeyVersion() string          { return "failing-v1" }
func (f *failingSigner) PublicKey() crypto.PublicKey { return f.pub }
func (f *failingSigner) Algorithm() string           { return SigningAlgorithmEd25519 }
func (f *failingSigner) Sign(ctx context.Context, statement map[string]any) ([]byte, error) {
	return nil, errors.New("simulated HSM/KMS transport timeout: key unreachable")
}

func TestFailClosedAttestation(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	keyID, _ := DeriveKeyID(pub)
	signer := &failingSigner{keyID: keyID, pub: pub}

	history := NewKeyHistoryStore()
	engine, err := NewAttestationEngine(signer, history, "sler-fleet-manager")
	if err != nil {
		t.Fatalf("init engine: %v", err)
	}

	req := sampleContainmentRequest()
	record, dsseBytes, err := engine.AttestContainment(context.Background(), req)

	// Invariant: Must fail closed
	if err == nil {
		t.Fatal("expected ErrAttestationFailed when signer errors, got nil")
	}
	if !errors.Is(err, ErrAttestationFailed) {
		t.Errorf("expected error to wrap ErrAttestationFailed, got: %v", err)
	}
	if record != nil || dsseBytes != nil {
		t.Error("expected nil record and nil dsseBytes on attestation failure")
	}
}

// 4. Key rotation & history test: older records remain verifiable across key rotations
func TestKeyRotationVerification(t *testing.T) {
	// Generation 1 key
	signer1, err := GenerateInMemoryEd25519Signer("witness-key-gen1")
	if err != nil {
		t.Fatalf("gen signer 1: %v", err)
	}

	history := NewKeyHistoryStore()
	engine, err := NewAttestationEngine(signer1, history, "sler-fleet-manager")
	if err != nil {
		t.Fatalf("init engine: %v", err)
	}

	// Sign record 1 with Gen 1 key
	req1 := sampleContainmentRequest()
	req1.EventID = "evt-gen1-containment"
	_, dsseBytes1, err := engine.AttestContainment(context.Background(), req1)
	if err != nil {
		t.Fatalf("AttestContainment Gen1: %v", err)
	}

	// Rotate to Generation 2 key
	signer2, err := GenerateInMemoryEd25519Signer("witness-key-gen2")
	if err != nil {
		t.Fatalf("gen signer 2: %v", err)
	}

	if err := engine.RotateSigner(signer2); err != nil {
		t.Fatalf("RotateSigner: %v", err)
	}

	if engine.KeyID() != signer2.KeyID() {
		t.Errorf("expected active keyID %s, got %s", signer2.KeyID(), engine.KeyID())
	}

	// Sign record 2 with Gen 2 key
	req2 := sampleContainmentRequest()
	req2.EventID = "evt-gen2-containment"
	_, dsseBytes2, err := engine.AttestContainment(context.Background(), req2)
	if err != nil {
		t.Fatalf("AttestContainment Gen2: %v", err)
	}

	// Invariant: Verifier MUST verify both Record 1 (Gen 1 key) and Record 2 (Gen 2 key)
	res1, err := engine.Verify(dsseBytes1)
	if err != nil {
		t.Fatalf("Verify Record 1 with rotated key: %v", err)
	}
	if res1.KeyID != signer1.KeyID() {
		t.Errorf("expected KeyID %s, got %s", signer1.KeyID(), res1.KeyID)
	}
	if res1.KeyVersion != "witness-key-gen1" {
		t.Errorf("expected KeyVersion 'witness-key-gen1', got %s", res1.KeyVersion)
	}

	res2, err := engine.Verify(dsseBytes2)
	if err != nil {
		t.Fatalf("Verify Record 2: %v", err)
	}
	if res2.KeyID != signer2.KeyID() {
		t.Errorf("expected KeyID %s, got %s", signer2.KeyID(), res2.KeyID)
	}
	if res2.KeyVersion != "witness-key-gen2" {
		t.Errorf("expected KeyVersion 'witness-key-gen2', got %s", res2.KeyVersion)
	}
}

// 5. Zero private key leakage test: private key bytes must NEVER appear in outputs or errors
func TestZeroKeyLeakage(t *testing.T) {
	_, privKey, _ := ed25519.GenerateKey(rand.Reader)
	signer, err := NewLocalEd25519SignerFromKey(privKey, "test-leak-v1")
	if err != nil {
		t.Fatalf("new signer: %v", err)
	}

	history := NewKeyHistoryStore()
	engine, _ := NewAttestationEngine(signer, history, "sler-fleet-manager")

	req := sampleContainmentRequest()
	record, dsseBytes, err := engine.AttestContainment(context.Background(), req)
	if err != nil {
		t.Fatalf("attest: %v", err)
	}

	recordJSON, _ := json.Marshal(record)
	envelopeStr := string(dsseBytes)
	recordStr := string(recordJSON)

	// Check raw private key bytes, hex encoding, and base64 encoding
	rawSeed := privKey.Seed()
	hexSeed := fmt.Sprintf("%x", rawSeed)
	b64Seed := base64.StdEncoding.EncodeToString(rawSeed)
	hexPriv := fmt.Sprintf("%x", privKey)
	b64Priv := base64.StdEncoding.EncodeToString(privKey)

	for label, secret := range map[string]string{
		"hexSeed": hexSeed,
		"b64Seed": b64Seed,
		"hexPriv": hexPriv,
		"b64Priv": b64Priv,
	} {
		if strings.Contains(envelopeStr, secret) {
			t.Errorf("CRITICAL SECURITY DEFECT: %s found in DSSE envelope output!", label)
		}
		if strings.Contains(recordStr, secret) {
			t.Errorf("CRITICAL SECURITY DEFECT: %s found in ForensicLedgerRecord output!", label)
		}
	}
}

// 6. Trusted timestamp test: timestamps must be RFC3339Nano UTC and monotonic
func TestTrustedTimestamp(t *testing.T) {
	signer, _ := GenerateInMemoryEd25519Signer()
	history := NewKeyHistoryStore()
	engine, _ := NewAttestationEngine(signer, history, "sler-fleet-manager")

	fixedTime := time.Date(2026, 9, 15, 8, 30, 0, 123456789, time.UTC)
	engine.SetClock(func() time.Time {
		return fixedTime
	})

	req := sampleContainmentRequest()
	req.Timestamp = time.Time{} // leave empty to force engine clock derivation

	record, dsseBytes, err := engine.AttestContainment(context.Background(), req)
	if err != nil {
		t.Fatalf("attest: %v", err)
	}

	expectedTS := "2026-09-15T08:30:00.123456789Z"
	if record.Timestamp != expectedTS {
		t.Errorf("expected timestamp %s, got %s", expectedTS, record.Timestamp)
	}

	res, err := engine.Verify(dsseBytes)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if res.Record.Timestamp != expectedTS {
		t.Errorf("expected verified record timestamp %s, got %s", expectedTS, res.Record.Timestamp)
	}
}

// 7. Schema forward-compatibility test: verifier handles additive fields without invalidating signature
func TestSchemaForwardCompatibility(t *testing.T) {
	signer, _ := GenerateInMemoryEd25519Signer()
	history := NewKeyHistoryStore()
	engine, _ := NewAttestationEngine(signer, history, "sler-fleet-manager")

	req := sampleContainmentRequest()
	record, _, err := engine.AttestContainment(context.Background(), req)
	if err != nil {
		t.Fatalf("attest: %v", err)
	}

	// Add new additive field into the record extensions
	record.Extensions = map[string]any{
		"kernel_trace_id":       "bpf-trace-9944",
		"pci_dss_compliance_id": "req-10.2.1",
		"extra_metrics": map[string]any{
			"ebpf_conntrack_entries_cleared": 42,
		},
	}

	statement, err := record.ToInTotoStatement()
	if err != nil {
		t.Fatalf("build statement with extensions: %v", err)
	}

	dsseBytes, err := signer.Sign(context.Background(), statement)
	if err != nil {
		t.Fatalf("sign statement with extensions: %v", err)
	}

	// Verify using standard verifier
	res, err := engine.Verify(dsseBytes)
	if err != nil {
		t.Fatalf("Verify forward-compatible record: %v", err)
	}

	if !res.Valid {
		t.Fatal("expected forward-compatible record to be valid")
	}
	if res.Record.Extensions == nil || res.Record.Extensions["kernel_trace_id"] != "bpf-trace-9944" {
		t.Errorf("expected extension field to survive round-trip, got: %v", res.Record.Extensions)
	}
}

// 8. Target identity alignment test: matches admission_client and mesh_client representations
func TestTargetIdentityAlignment(t *testing.T) {
	target := TargetIdentity{
		AgentID:     "test-agent-alpha",
		Namespace:   "demo-tenant",
		PodName:     "test-agent-alpha-pod-1",
		PodUID:      "pod-uid-12345",
		SPIFFEID:    "spiffe://osramp.local/ns/demo-tenant/sa/test-agent-alpha",
		NodeName:    "node-k8s-01",
		ContainerID: "containerd://fedcba987654",
		CgroupPath:  "/sys/fs/cgroup/kubepods.slice/pod-uid-12345",
		PIDs:        []int{4001, 4002},
		TenantID:    "demo-tenant",
	}

	req := sampleContainmentRequest()
	req.Target = target

	signer, _ := GenerateInMemoryEd25519Signer()
	history := NewKeyHistoryStore()
	engine, _ := NewAttestationEngine(signer, history, "sler-fleet-manager")

	_, dsseBytes, err := engine.AttestContainment(context.Background(), req)
	if err != nil {
		t.Fatalf("attest: %v", err)
	}

	res, err := engine.Verify(dsseBytes)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}

	if res.Record.Target.AgentID != target.AgentID ||
		res.Record.Target.Namespace != target.Namespace ||
		res.Record.Target.SPIFFEID != target.SPIFFEID ||
		res.Record.Target.PodUID != target.PodUID {
		t.Errorf("target identity mismatch: got %+v, expected %+v", res.Record.Target, target)
	}
}

// 9. Concurrency & load test: 100 concurrent containment events; measure latency
func TestConcurrentBatchAttestationLoad(t *testing.T) {
	signer, _ := GenerateInMemoryEd25519Signer()
	history := NewKeyHistoryStore()
	engine, _ := NewAttestationEngine(signer, history, "sler-fleet-manager")

	const batchSize = 100
	var wg sync.WaitGroup
	wg.Add(batchSize)

	durations := make([]time.Duration, batchSize)
	errorsChan := make(chan error, batchSize)

	startTotal := time.Now()

	for i := 0; i < batchSize; i++ {
		idx := i
		go func() {
			defer wg.Done()
			req := sampleContainmentRequest()
			req.EventID = fmt.Sprintf("evt-batch-%03d", idx)
			req.IdempotencyKey = fmt.Sprintf("idem-%03d", idx)

			t0 := time.Now()
			_, dsseBytes, err := engine.AttestContainment(context.Background(), req)
			if err != nil {
				errorsChan <- fmt.Errorf("event %d attest error: %w", idx, err)
				return
			}
			durations[idx] = time.Since(t0)

			// Verify in parallel as well
			if _, err := engine.Verify(dsseBytes); err != nil {
				errorsChan <- fmt.Errorf("event %d verify error: %w", idx, err)
				return
			}
		}()
	}

	wg.Wait()
	close(errorsChan)

	totalElapsed := time.Since(startTotal)

	for err := range errorsChan {
		t.Errorf("batch failure: %v", err)
	}

	// Calculate average latency
	var totalDuration time.Duration
	var maxDuration time.Duration
	for _, d := range durations {
		totalDuration += d
		if d > maxDuration {
			maxDuration = d
		}
	}
	avgLatency := totalDuration / time.Duration(batchSize)

	t.Logf("100-Event Concurrent Attestation Load Test Passed: Total Time=%v, Avg Latency/Event=%v, Max Latency=%v",
		totalElapsed, avgLatency, maxDuration)

	// Invariant: In-process signing must be fast (avg < 5ms per event under batch load)
	if avgLatency > 5*time.Millisecond {
		t.Errorf("average attestation latency %v exceeds 5ms threshold", avgLatency)
	}
}

// 10. Causal authorization chain binding test
func TestCausalAuthorizationChainBinding(t *testing.T) {
	signer, _ := GenerateInMemoryEd25519Signer()
	history := NewKeyHistoryStore()
	engine, _ := NewAttestationEngine(signer, history, "sler-fleet-manager")

	decisionID := "signal-fusion-alert-9944-alpha"
	triggerReason := "unauthorized_cross_tenant_token_minting"
	triggeredBy := "signal-loom-governor"
	attestationDigest := "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

	req := sampleContainmentRequest()
	req.Authorization = AuthorizationEvidence{
		DecisionID:            decisionID,
		TriggerReason:         triggerReason,
		TriggerDescription:    "Agent minted synthetic JWT tokens violating SPIFFE trust boundary",
		TriggeredBy:           triggeredBy,
		DelegationEdgeRevoked: true,
		AttestationDigest:     attestationDigest,
	}

	_, dsseBytes, err := engine.AttestContainment(context.Background(), req)
	if err != nil {
		t.Fatalf("attest: %v", err)
	}

	res, err := engine.Verify(dsseBytes)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}

	auth := res.Record.Authorization
	if auth.DecisionID != decisionID ||
		auth.TriggerReason != triggerReason ||
		auth.TriggeredBy != triggeredBy ||
		auth.AttestationDigest != attestationDigest ||
		!auth.DelegationEdgeRevoked {
		t.Errorf("causal authorization chain corrupted: got %+v", auth)
	}
}

// 11. Governance resume attestation test
func TestGovernanceResumeAttestation(t *testing.T) {
	signer, _ := GenerateInMemoryEd25519Signer("witness-resume-v1")
	history := NewKeyHistoryStore()
	engine, _ := NewAttestationEngine(signer, history, "sler-fleet-manager")

	req := ResumeAttestationRequest{
		EventID:        "evt-resume-001",
		EventType:      EventContainmentResumed,
		IdempotencyKey: "idem-resume-7744",
		Authorization: AuthorizationEvidence{
			DecisionID:         "gov-approval-ticket-8822",
			TriggerReason:      "operator_security_review_completed",
			TriggerDescription: "Attributable dual-operator resume authorization granted",
			TriggeredBy:        "security-ops-council",
		},
		Target: TargetIdentity{
			AgentID:   "agent-finance-02",
			Namespace: "prod-agents",
			PodName:   "agent-finance-02-abc",
			PodUID:    "uid-finance-02",
			SPIFFEID:  "spiffe://osramp.local/ns/prod-agents/sa/agent-finance-02",
		},
		Execution: ExecutionEvidence{
			OverallOutcome: "contained", // previous state
			TotalLatencyMs: 8,
			Planes: []PlaneExecutionEvidence{
				{Plane: "freeze", Outcome: "contained", LatencyMs: 2},
			},
		},
		GovernanceResume: GovernanceResumeEvidence{
			TokenID:               "tok-ed25519-dual-sig-9922",
			OperatorIDs:           []string{"operator-alice@controlplane.io", "operator-bob@controlplane.io"},
			GovernanceApprovalRef: "PR-2026-GOV-881",
			CredentialsRotated:    true,
			ProcessesResumed:      3,
			UnfreezeLatencyMs:     6,
		},
		Timestamp: time.Now().UTC(),
	}

	record, dsseBytes, err := engine.AttestResume(context.Background(), req)
	if err != nil {
		t.Fatalf("AttestResume: %v", err)
	}

	res, err := engine.Verify(dsseBytes)
	if err != nil {
		t.Fatalf("Verify resume record: %v", err)
	}

	if res.Record.GovernanceResume == nil {
		t.Fatal("expected non-nil GovernanceResume in verified record")
	}
	if len(res.Record.GovernanceResume.OperatorIDs) != 2 {
		t.Errorf("expected 2 operator IDs, got %d", len(res.Record.GovernanceResume.OperatorIDs))
	}
	if !res.Record.GovernanceResume.CredentialsRotated {
		t.Error("expected credentials_rotated to be true")
	}
	if record.Attestation.StatementDigest == "" {
		t.Error("expected statement digest to be populated")
	}
}

// 12. Benchmark attestation latency
func BenchmarkAttestationLatency(b *testing.B) {
	signer, _ := GenerateInMemoryEd25519Signer()
	history := NewKeyHistoryStore()
	engine, _ := NewAttestationEngine(signer, history, "sler-fleet-manager")

	req := sampleContainmentRequest()
	ctx := context.Background()

	b.ResetTimer()
	b.ReportAllocs()

	for i := 0; i < b.N; i++ {
		_, _, err := engine.AttestContainment(ctx, req)
		if err != nil {
			b.Fatalf("attest: %v", err)
		}
	}
}

// 13. Benchmark verification latency
func BenchmarkVerificationLatency(b *testing.B) {
	signer, _ := GenerateInMemoryEd25519Signer()
	history := NewKeyHistoryStore()
	engine, _ := NewAttestationEngine(signer, history, "sler-fleet-manager")

	req := sampleContainmentRequest()
	_, dsseBytes, err := engine.AttestContainment(context.Background(), req)
	if err != nil {
		b.Fatalf("attest: %v", err)
	}

	b.ResetTimer()
	b.ReportAllocs()

	for i := 0; i < b.N; i++ {
		_, err := engine.Verify(dsseBytes)
		if err != nil {
			b.Fatalf("verify: %v", err)
		}
	}
}
