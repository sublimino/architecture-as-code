package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	spiretypes "github.com/spiffe/spire-api-sdk/proto/spire/api/types"
	"k8s.io/client-go/kubernetes/fake"
)

// ── Test doubles and helpers for Resume Governance ───────────────────────────

type countingRotateSpireClient struct {
	reenterCalls atomic.Int64
	evictCalls   atomic.Int64
	keysSeen     chan string
	outcome      PlaneOutcome
	returnErr    error
}

func newCountingRotateSpireClient(outcome PlaneOutcome) *countingRotateSpireClient {
	return &countingRotateSpireClient{
		outcome:  outcome,
		keysSeen: make(chan string, 16),
	}
}

func (m *countingRotateSpireClient) ReenterAgent(ctx context.Context, req SpireReentryRequest) (*SpireReentryResponse, error) {
	m.reenterCalls.Add(1)
	select {
	case m.keysSeen <- req.IdempotencyKey:
	default:
	}
	if m.returnErr != nil {
		return nil, m.returnErr
	}
	return &SpireReentryResponse{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: req.IdempotencyKey,
		AgentID:        req.AgentID,
		Plane:          PlaneSpire,
		Outcome:        m.outcome,
		EntryCreated:   true,
		LatencyMs:      1,
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}, nil
}

func (m *countingRotateSpireClient) EvictAgent(ctx context.Context, req SpireEvictionRequest) (*SpireEvictionResponse, error) {
	m.evictCalls.Add(1)
	return &SpireEvictionResponse{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: req.IdempotencyKey,
		AgentID:        req.AgentID,
		Plane:          PlaneSpire,
		Outcome:        m.outcome,
		EntriesEvicted: 1,
		LatencyMs:      1,
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}, nil
}

func (m *countingRotateSpireClient) DeleteEntry(context.Context, string) (*SpireEntryDeleteResult, error) {
	return nil, errors.New("not used")
}
func (m *countingRotateSpireClient) BatchDeleteEntries(context.Context, []string) ([]SpireEntryDeleteResult, error) {
	return nil, errors.New("not used")
}
func (m *countingRotateSpireClient) ListEntriesBySPIFFEID(context.Context, string) ([]*spiretypes.Entry, error) {
	return nil, errors.New("not used")
}
func (m *countingRotateSpireClient) Health(context.Context) error { return nil }
func (m *countingRotateSpireClient) Close() error                 { return nil }

var _ SpireClient = (*countingRotateSpireClient)(nil)

type rotateBaoServer struct {
	*httptest.Server
	rotateCalls atomic.Int64
	keysSeen    chan string
}

func newRotateBaoServer(status int) *rotateBaoServer {
	b := &rotateBaoServer{keysSeen: make(chan string, 16)}
	b.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b.rotateCalls.Add(1)
		select {
		case b.keysSeen <- r.Header.Get("X-Idempotency-Key"):
		default:
		}
		w.WriteHeader(status)
		if status == http.StatusOK {
			_, _ = w.Write([]byte(`{"data":{"token":"s.rot-new-token","lease_id":"auth/token/rot-lease"}}`))
		} else {
			_, _ = w.Write([]byte(`{"errors":["rotation failed"]}`))
		}
	}))
	return b
}

func newResumeFleetClient(t *testing.T, spire SpireClient, baoAddr string) *k8sFleetClient {
	t.Helper()
	pod := agentPod("agent-llm-classifier", "contained", nil)
	c := newK8sFleetClientWithSpire(fake.NewSimpleClientset(pod), "fe-signalloom-agents", spire)
	if c.baoClient == nil {
		t.Fatal("production constructor did not set baoClient")
	}
	c.baoClient = NewOpenBaoClient(OpenBaoConfig{
		Address: baoAddr,
		Token:   "test-token",
		Timeout: 2 * time.Second,
	})
	return c
}

func liveDualSignedToken(t *testing.T) (ResumeToken, *StaticOperatorKeyRegistry) {
	t.Helper()
	now := time.Now().UTC()
	alicePub, alicePriv := keyFromSeed(t, seedOperatorAlice)
	bobPub, bobPriv := keyFromSeed(t, seedOperatorBob)
	malPub, _ := keyFromSeed(t, seedOperatorMal)

	raw := ResumeToken{
		SchemaVersion:         FrozenSchemaVersion,
		TokenID:               "rt-live-" + base64.RawURLEncoding.EncodeToString([]byte(now.Format(time.RFC3339Nano))),
		Algorithm:             ResumeTokenAlgEd25519,
		AgentID:               "agent-llm-classifier",
		Namespace:             "fe-signalloom-agents",
		Audience:              "signalloom-fleet/local",
		GovernanceApprovalRef: "CHG-2026-09-15-0042",
		IssuedAt:              now.Add(-2 * time.Minute).Format(time.RFC3339),
		ExpiresAt:             now.Add(8 * time.Minute).Format(time.RFC3339),
		Nonce:                 base64.StdEncoding.EncodeToString([]byte("sler-p4-3-nonce!")),
		TrustRootID:           refTrustRoot,
		RequiredSignatures:    2,
	}

	token, err := SignResumeToken(raw, opAlice, alicePriv, now.Add(-2*time.Minute))
	if err != nil {
		t.Fatalf("alice sign: %v", err)
	}
	token, err = SignResumeToken(token, opBob, bobPriv, now.Add(-90*time.Second))
	if err != nil {
		t.Fatalf("bob sign: %v", err)
	}
	reg := NewStaticOperatorKeyRegistry(
		OperatorKeyEntry{OperatorID: opAlice, KeyID: ComputeKeyID(alicePub), PublicKey: alicePub},
		OperatorKeyEntry{OperatorID: opBob, KeyID: ComputeKeyID(bobPub), PublicKey: bobPub},
		OperatorKeyEntry{OperatorID: opMal, KeyID: ComputeKeyID(malPub), PublicKey: malPub},
	)
	return token, reg
}

// ── Tests ───────────────────────────────────────────────────────────────────

func TestEnforceResume_DualOperator_Success(t *testing.T) {
	token, reg := liveDualSignedToken(t)
	policy := dualPolicy()
	ledger := NewReplayLedger()

	spire := newCountingRotateSpireClient(OutcomeContained)
	bao := newRotateBaoServer(http.StatusOK)
	defer bao.Close()

	client := newResumeFleetClient(t, spire, bao.URL)

	req := ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "idem-resume-001",
		AgentID:        token.AgentID,
		Namespace:      token.Namespace,
		Token:          token,
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}

	resp, err := EnforceResume(context.Background(), req, reg, policy, ledger, client)
	if err != nil {
		t.Fatalf("EnforceResume failed: %v", err)
	}

	if !resp.Success {
		t.Errorf("resp.Success = false, want true")
	}
	if !resp.CredentialsRotated {
		t.Errorf("resp.CredentialsRotated = false, want true (mandatory credential rotation)")
	}
	if resp.ProcessesResumed != 1 {
		t.Errorf("resp.ProcessesResumed = %d, want 1", resp.ProcessesResumed)
	}

	// Verify both credential planes fired
	if got := spire.reenterCalls.Load(); got != 1 {
		t.Errorf("spire reenter calls = %d, want 1", got)
	}
	if got := bao.rotateCalls.Load(); got != 1 {
		t.Errorf("bao rotate calls = %d, want 1", got)
	}
}

func TestEnforceResume_ReplayProtection_DifferentIdempotencyKey(t *testing.T) {
	token, reg := liveDualSignedToken(t)
	policy := dualPolicy()
	ledger := NewReplayLedger()

	spire := newCountingRotateSpireClient(OutcomeContained)
	bao := newRotateBaoServer(http.StatusOK)
	defer bao.Close()
	client := newResumeFleetClient(t, spire, bao.URL)

	req1 := ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "idem-resume-001",
		AgentID:        token.AgentID,
		Namespace:      token.Namespace,
		Token:          token,
	}
	_, err := EnforceResume(context.Background(), req1, reg, policy, ledger, client)
	if err != nil {
		t.Fatalf("initial resume failed: %v", err)
	}

	// Present same token with different idempotency key -> MUST fail with ErrResumeTokenReplayed
	req2 := ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "idem-resume-002",
		AgentID:        token.AgentID,
		Namespace:      token.Namespace,
		Token:          token,
	}
	_, err = EnforceResume(context.Background(), req2, reg, policy, ledger, client)
	if !errors.Is(err, ErrResumeTokenReplayed) {
		t.Fatalf("expected ErrResumeTokenReplayed on replay, got: %v", err)
	}
}

func TestEnforceResume_IdempotentRetry_SameIdempotencyKey(t *testing.T) {
	token, reg := liveDualSignedToken(t)
	policy := dualPolicy()
	ledger := NewReplayLedger()

	spire := newCountingRotateSpireClient(OutcomeContained)
	bao := newRotateBaoServer(http.StatusOK)
	defer bao.Close()
	client := newResumeFleetClient(t, spire, bao.URL)

	req := ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "idem-retry-same",
		AgentID:        token.AgentID,
		Namespace:      token.Namespace,
		Token:          token,
	}
	resp1, err := EnforceResume(context.Background(), req, reg, policy, ledger, client)
	if err != nil {
		t.Fatalf("initial resume failed: %v", err)
	}
	if !resp1.Success || !resp1.CredentialsRotated {
		t.Errorf("initial response invalid: %+v", resp1)
	}

	// Retry with EXACT SAME idempotency key -> returns success without re-invoking planes
	resp2, err := EnforceResume(context.Background(), req, reg, policy, ledger, client)
	if err != nil {
		t.Fatalf("idempotent retry failed: %v", err)
	}
	if !resp2.Success || !resp2.CredentialsRotated {
		t.Errorf("idempotent retry response invalid: %+v", resp2)
	}

	// Planes must NOT have been called a second time
	if got := spire.reenterCalls.Load(); got != 1 {
		t.Errorf("spire reenter calls = %d, want 1 (idempotent retry should not re-invoke)", got)
	}
	if got := bao.rotateCalls.Load(); got != 1 {
		t.Errorf("bao rotate calls = %d, want 1 (idempotent retry should not re-invoke)", got)
	}
}

func TestEnforceResume_SingleOperator_FailsUnderDualPolicy(t *testing.T) {
	now := time.Now().UTC()
	alicePub, alicePriv := keyFromSeed(t, seedOperatorAlice)
	reg := NewStaticOperatorKeyRegistry(
		OperatorKeyEntry{OperatorID: opAlice, KeyID: ComputeKeyID(alicePub), PublicKey: alicePub},
	)
	raw := ResumeToken{
		SchemaVersion:         FrozenSchemaVersion,
		TokenID:               "rt-single-001",
		Algorithm:             ResumeTokenAlgEd25519,
		AgentID:               "agent-llm-classifier",
		Namespace:             "fe-signalloom-agents",
		Audience:              "signalloom-fleet/local",
		GovernanceApprovalRef: "CHG-2026-09-15-0042",
		IssuedAt:              now.Add(-2 * time.Minute).Format(time.RFC3339),
		ExpiresAt:             now.Add(8 * time.Minute).Format(time.RFC3339),
		Nonce:                 base64.StdEncoding.EncodeToString([]byte("sler-p4-3-nonce!")),
		TrustRootID:           refTrustRoot,
		RequiredSignatures:    2,
	}
	token, err := SignResumeToken(raw, opAlice, alicePriv, now.Add(-2*time.Minute))
	if err != nil {
		t.Fatalf("alice sign: %v", err)
	}

	policy := dualPolicy() // requires 2 signatures
	ledger := NewReplayLedger()

	req := ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "idem-single-op",
		AgentID:        token.AgentID,
		Namespace:      token.Namespace,
		Token:          token,
	}
	_, err = EnforceResume(context.Background(), req, reg, policy, ledger, nil)
	if !errors.Is(err, ErrResumeTokenInsufficientSignature) {
		t.Fatalf("expected ErrResumeTokenInsufficientSignature, got: %v", err)
	}
}

func TestEnforceResume_RevokedKey_Fails(t *testing.T) {
	now := time.Now().UTC()
	alicePub, alicePriv := keyFromSeed(t, seedOperatorAlice)
	bobPub, bobPriv := keyFromSeed(t, seedOperatorBob)

	raw := ResumeToken{
		SchemaVersion:         FrozenSchemaVersion,
		TokenID:               "rt-revoked-001",
		Algorithm:             ResumeTokenAlgEd25519,
		AgentID:               "agent-llm-classifier",
		Namespace:             "fe-signalloom-agents",
		Audience:              "signalloom-fleet/local",
		GovernanceApprovalRef: "CHG-2026-09-15-0042",
		IssuedAt:              now.Add(-2 * time.Minute).Format(time.RFC3339),
		ExpiresAt:             now.Add(8 * time.Minute).Format(time.RFC3339),
		Nonce:                 base64.StdEncoding.EncodeToString([]byte("sler-p4-3-nonce!")),
		TrustRootID:           refTrustRoot,
		RequiredSignatures:    2,
	}
	token, _ := SignResumeToken(raw, opAlice, alicePriv, now.Add(-2*time.Minute))
	token, _ = SignResumeToken(token, opBob, bobPriv, now.Add(-90*time.Second))

	// Alice's key is marked revoked
	reg := NewStaticOperatorKeyRegistry(
		OperatorKeyEntry{OperatorID: opAlice, KeyID: ComputeKeyID(alicePub), PublicKey: alicePub, Revoked: true},
		OperatorKeyEntry{OperatorID: opBob, KeyID: ComputeKeyID(bobPub), PublicKey: bobPub},
	)

	req := ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "idem-revoked-op",
		AgentID:        token.AgentID,
		Namespace:      token.Namespace,
		Token:          token,
	}
	_, err := EnforceResume(context.Background(), req, reg, dualPolicy(), NewReplayLedger(), nil)
	if !errors.Is(err, ErrResumeTokenRevokedKey) {
		t.Fatalf("expected ErrResumeTokenRevokedKey, got: %v", err)
	}
}

func TestEnforceResume_UnknownKey_Fails(t *testing.T) {
	now := time.Now().UTC()
	_, alicePriv := keyFromSeed(t, seedOperatorAlice)
	bobPub, bobPriv := keyFromSeed(t, seedOperatorBob)

	raw := ResumeToken{
		SchemaVersion:         FrozenSchemaVersion,
		TokenID:               "rt-unknown-001",
		Algorithm:             ResumeTokenAlgEd25519,
		AgentID:               "agent-llm-classifier",
		Namespace:             "fe-signalloom-agents",
		Audience:              "signalloom-fleet/local",
		GovernanceApprovalRef: "CHG-2026-09-15-0042",
		IssuedAt:              now.Add(-2 * time.Minute).Format(time.RFC3339),
		ExpiresAt:             now.Add(8 * time.Minute).Format(time.RFC3339),
		Nonce:                 base64.StdEncoding.EncodeToString([]byte("sler-p4-3-nonce!")),
		TrustRootID:           refTrustRoot,
		RequiredSignatures:    2,
	}
	token, _ := SignResumeToken(raw, opAlice, alicePriv, now.Add(-2*time.Minute))
	token, _ = SignResumeToken(token, opBob, bobPriv, now.Add(-90*time.Second))

	// Registry only knows Bob's key, not Alice's
	reg := NewStaticOperatorKeyRegistry(
		OperatorKeyEntry{OperatorID: opBob, KeyID: ComputeKeyID(bobPub), PublicKey: bobPub},
	)

	req := ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "idem-unknown-op",
		AgentID:        token.AgentID,
		Namespace:      token.Namespace,
		Token:          token,
	}
	_, err := EnforceResume(context.Background(), req, reg, dualPolicy(), NewReplayLedger(), nil)
	if !errors.Is(err, ErrResumeTokenUnknownKey) {
		t.Fatalf("expected ErrResumeTokenUnknownKey, got: %v", err)
	}
}

func TestEnforceResume_PlaneFailure_FailsClosed(t *testing.T) {
	token, reg := liveDualSignedToken(t)
	policy := dualPolicy()
	ledger := NewReplayLedger()

	spire := newCountingRotateSpireClient(OutcomeContained)
	spire.returnErr = errors.New("spire connection refused")
	bao := newRotateBaoServer(http.StatusInternalServerError)
	defer bao.Close()

	client := newResumeFleetClient(t, spire, bao.URL)

	req := ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "idem-fail-closed",
		AgentID:        token.AgentID,
		Namespace:      token.Namespace,
		Token:          token,
	}

	resp, err := EnforceResume(context.Background(), req, reg, policy, ledger, client)
	if err == nil {
		t.Fatal("expected EnforceResume to fail when credential rotation fails")
	}
	if resp.Success {
		t.Errorf("resp.Success must be false on plane failure")
	}
	if resp.CredentialsRotated {
		t.Errorf("resp.CredentialsRotated must be false on plane failure")
	}
}

func TestHandleResume_HTTPEndpoint(t *testing.T) {
	token, reg := liveDualSignedToken(t)
	policy := dualPolicy()
	ledger := NewReplayLedger()

	spire := newCountingRotateSpireClient(OutcomeContained)
	bao := newRotateBaoServer(http.StatusOK)
	defer bao.Close()
	client := newResumeFleetClient(t, spire, bao.URL)

	srv := &server{
		dag:          mustBuildTestDAG(t),
		keyRegistry:  reg,
		resumePolicy: policy,
		replayLedger: ledger,
		enforcement: &fleetClientSelection{
			Kind:      fleetClientKubernetes,
			Client:    client,
			Enforcing: true,
		},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/fleet/resume", srv.handleResume)
	ts := httptest.NewServer(mux)
	defer ts.Close()

	// 1. Success (200 OK)
	reqBody, _ := json.Marshal(ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "http-idem-001",
		AgentID:        token.AgentID,
		Namespace:      token.Namespace,
		Token:          token,
	})
	resp, err := http.Post(ts.URL+"/api/v1/fleet/resume", "application/json", bytes.NewReader(reqBody))
	if err != nil {
		t.Fatalf("POST /api/v1/fleet/resume: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusOK)
	}
	var rResp ResumeResponse
	json.NewDecoder(resp.Body).Decode(&rResp)
	resp.Body.Close()
	if !rResp.Success || !rResp.CredentialsRotated {
		t.Errorf("expected successful response with credentials_rotated=true, got %+v", rResp)
	}

	// 2. Replay with different idempotency key -> 409 Conflict
	replayBody, _ := json.Marshal(ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "http-idem-002",
		AgentID:        token.AgentID,
		Namespace:      token.Namespace,
		Token:          token,
	})
	resp2, err := http.Post(ts.URL+"/api/v1/fleet/resume", "application/json", bytes.NewReader(replayBody))
	if err != nil {
		t.Fatalf("POST replay: %v", err)
	}
	if resp2.StatusCode != http.StatusConflict {
		t.Fatalf("status on replay = %d, want %d (409 Conflict)", resp2.StatusCode, http.StatusConflict)
	}
	resp2.Body.Close()

	// 3. Bad signature / tampered token -> 403 Forbidden
	tamperedToken := token
	tamperedToken.Nonce = base64.StdEncoding.EncodeToString([]byte("tampered-nonce!!"))
	badBody, _ := json.Marshal(ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "http-idem-bad",
		AgentID:        tamperedToken.AgentID,
		Namespace:      tamperedToken.Namespace,
		Token:          tamperedToken,
	})
	resp3, err := http.Post(ts.URL+"/api/v1/fleet/resume", "application/json", bytes.NewReader(badBody))
	if err != nil {
		t.Fatalf("POST bad token: %v", err)
	}
	if resp3.StatusCode != http.StatusForbidden {
		t.Fatalf("status on bad signature = %d, want %d (403 Forbidden)", resp3.StatusCode, http.StatusForbidden)
	}
	resp3.Body.Close()

	// 4. Target mismatch -> 400 Bad Request
	mismatchBody, _ := json.Marshal(ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "http-idem-mismatch",
		AgentID:        "agent-cardvault", // a real DAG agent the token is not bound to
		Namespace:      token.Namespace,
		Token:          token,
	})
	resp4, err := http.Post(ts.URL+"/api/v1/fleet/resume", "application/json", bytes.NewReader(mismatchBody))
	if err != nil {
		t.Fatalf("POST mismatch: %v", err)
	}
	if resp4.StatusCode != http.StatusBadRequest {
		t.Fatalf("status on mismatch = %d, want %d (400 Bad Request)", resp4.StatusCode, http.StatusBadRequest)
	}
	resp4.Body.Close()
}

func TestResume_AttestationLogging(t *testing.T) {
	token, reg := liveDualSignedToken(t)
	policy := dualPolicy()
	ledger := NewReplayLedger()

	var logBuf bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&logBuf, nil))
	oldLogger := slog.Default()
	slog.SetDefault(logger)
	defer slog.SetDefault(oldLogger)

	spire := newCountingRotateSpireClient(OutcomeContained)
	bao := newRotateBaoServer(http.StatusOK)
	defer bao.Close()
	client := newResumeFleetClient(t, spire, bao.URL)

	req := ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "idem-audit-test",
		AgentID:        token.AgentID,
		Namespace:      token.Namespace,
		Token:          token,
	}

	_, err := EnforceResume(context.Background(), req, reg, policy, ledger, client)
	if err != nil {
		t.Fatalf("EnforceResume: %v", err)
	}

	// Parse JSON logs to confirm ResumeDecisionEventName and fields
	output := logBuf.String()
	foundDecision := false
	for _, line := range bytes.Split(logBuf.Bytes(), []byte("\n")) {
		if len(line) == 0 {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal(line, &entry); err == nil {
			if entry["event"] == ResumeDecisionEventName {
				foundDecision = true
				if entry["agent_id"] != token.AgentID {
					t.Errorf("log agent_id = %v, want %s", entry["agent_id"], token.AgentID)
				}
				if entry["token_id"] != token.TokenID {
					t.Errorf("log token_id = %v, want %s", entry["token_id"], token.TokenID)
				}
				if entry["credentials_rotated"] != true {
					t.Errorf("log credentials_rotated = %v, want true", entry["credentials_rotated"])
				}
				if entry["success"] != true {
					t.Errorf("log success = %v, want true", entry["success"])
				}
			}
		}
	}
	if !foundDecision {
		t.Fatalf("did not find %q event in slog output:\n%s", ResumeDecisionEventName, output)
	}
}

func TestKeyRegistry_Discovery(t *testing.T) {
	alicePub, _ := keyFromSeed(t, seedOperatorAlice)
	bobPub, _ := keyFromSeed(t, seedOperatorBob)

	tempDir := t.TempDir()

	// 1. Write an RFC 8032 raw public key file (.pub)
	pubFile := filepath.Join(tempDir, "alice.pub")
	if err := os.WriteFile(pubFile, alicePub, 0644); err != nil {
		t.Fatalf("write pub file: %v", err)
	}

	// 2. Write a JSON key entry file (.json)
	bobEntry := OperatorKeyJSON{
		OperatorID: opBob,
		KeyID:      ComputeKeyID(bobPub),
		PublicKey:  base64.StdEncoding.EncodeToString(bobPub),
	}
	jsonFile := filepath.Join(tempDir, "bob.json")
	bobData, _ := json.Marshal(bobEntry)
	if err := os.WriteFile(jsonFile, bobData, 0644); err != nil {
		t.Fatalf("write json file: %v", err)
	}

	reg, err := LoadOperatorKeyRegistry(tempDir)
	if err != nil {
		t.Fatalf("LoadOperatorKeyRegistry: %v", err)
	}

	// Lookup Alice
	aliceKeyID := ComputeKeyID(alicePub)
	entryA, err := reg.LookupOperatorKey(aliceKeyID)
	if err != nil {
		t.Fatalf("lookup alice: %v", err)
	}
	if !bytes.Equal(entryA.PublicKey, alicePub) {
		t.Errorf("alice public key mismatch")
	}

	// Lookup Bob
	bobKeyID := ComputeKeyID(bobPub)
	entryB, err := reg.LookupOperatorKey(bobKeyID)
	if err != nil {
		t.Fatalf("lookup bob: %v", err)
	}
	if entryB.OperatorID != opBob {
		t.Errorf("bob operator_id = %q, want %q", entryB.OperatorID, opBob)
	}
}
