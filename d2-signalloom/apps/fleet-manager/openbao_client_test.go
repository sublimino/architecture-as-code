package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestOpenBaoClient_RevokeLease_Success(t *testing.T) {
	var receivedBody map[string]any
	var receivedToken string
	var receivedPath string

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		receivedPath = r.URL.Path
		receivedToken = r.Header.Get("X-Vault-Token")
		_ = json.NewDecoder(r.Body).Decode(&receivedBody)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	logBuf := &bytes.Buffer{}
	client := NewOpenBaoClient(OpenBaoConfig{
		Address:   server.URL,
		Token:     "s.test-scoped-token-12345",
		LogWriter: logBuf,
	})

	ctx := context.Background()
	req := BaoRevokeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "idem-test-1",
		AgentID:        "agent-cardvault",
		Namespace:      "fe-signalloom-agents",
		LeaseIDs:       []string{"cardvault/creds/agent-cardvault/lease-123"},
		Reason:         "Test containment",
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}

	resp, err := client.RevokeLease(ctx, req)
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}

	if resp.Outcome != OutcomeContained {
		t.Fatalf("expected outcome %q, got %q", OutcomeContained, resp.Outcome)
	}
	if resp.RevokedLeases != 1 {
		t.Fatalf("expected 1 revoked lease, got %d", resp.RevokedLeases)
	}
	if receivedPath != "/v1/sys/leases/revoke" {
		t.Fatalf("expected path /v1/sys/leases/revoke, got %s", receivedPath)
	}
	if receivedToken != "s.test-scoped-token-12345" {
		t.Fatalf("expected X-Vault-Token header, got %s", receivedToken)
	}
	if receivedBody["lease_id"] != "cardvault/creds/agent-cardvault/lease-123" {
		t.Fatalf("expected lease_id in payload, got %v", receivedBody["lease_id"])
	}
}

func TestOpenBaoClient_RevokeLease_Idempotency(t *testing.T) {
	callCount := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		if callCount == 1 {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		// Second call: lease already revoked / not found in OpenBao
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"errors":["lease not found"]}`))
	}))
	defer server.Close()

	client := NewOpenBaoClient(OpenBaoConfig{Address: server.URL, Token: "test-token"})
	ctx := context.Background()
	req := BaoRevokeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "retry-key-abc",
		AgentID:        "agent-cardvault",
		LeaseIDs:       []string{"cardvault/creds/agent-cardvault/lease-already-revoked"},
	}

	// First call
	resp1, err1 := client.RevokeLease(ctx, req)
	if err1 != nil {
		t.Fatalf("call 1 failed: %v", err1)
	}
	if resp1.Outcome != OutcomeContained {
		t.Fatalf("call 1 expected contained, got %s", resp1.Outcome)
	}

	// Second call (idempotent retry)
	resp2, err2 := client.RevokeLease(ctx, req)
	if err2 != nil {
		t.Fatalf("call 2 expected nil error on idempotent retry, got: %v", err2)
	}
	if resp2.Outcome != OutcomeContained {
		t.Fatalf("call 2 expected contained on idempotent retry, got %s", resp2.Outcome)
	}
	if resp2.RevokedLeases != 1 {
		t.Fatalf("call 2 expected 1 revoked lease, got %d", resp2.RevokedLeases)
	}
}

func TestOpenBaoClient_RevokeToken_And_Accessor(t *testing.T) {
	var lastPath string
	var lastBody map[string]any

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		lastPath = r.URL.Path
		_ = json.NewDecoder(r.Body).Decode(&lastBody)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	client := NewOpenBaoClient(OpenBaoConfig{Address: server.URL, Token: "admin-token"})
	ctx := context.Background()

	if err := client.RevokeToken(ctx, "s.agent-compromised-token"); err != nil {
		t.Fatalf("RevokeToken failed: %v", err)
	}
	if lastPath != "/v1/auth/token/revoke" || lastBody["token"] != "s.agent-compromised-token" {
		t.Fatalf("RevokeToken mismatch: path=%s, body=%v", lastPath, lastBody)
	}

	if err := client.RevokeTokenAccessor(ctx, "accessor-12345"); err != nil {
		t.Fatalf("RevokeTokenAccessor failed: %v", err)
	}
	if lastPath != "/v1/auth/token/revoke-accessor" || lastBody["accessor"] != "accessor-12345" {
		t.Fatalf("RevokeTokenAccessor mismatch: path=%s, body=%v", lastPath, lastBody)
	}
}

func TestOpenBaoClient_RenewSelf(t *testing.T) {
	var renewBody map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/auth/token/renew-self" {
			http.NotFound(w, r)
			return
		}
		_ = json.NewDecoder(r.Body).Decode(&renewBody)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"auth":{"client_token":"s.renewed","lease_duration":300}}`))
	}))
	defer server.Close()

	client := NewOpenBaoClient(OpenBaoConfig{Address: server.URL, Token: "s.self-token"})
	ctx := context.Background()

	if err := client.RenewSelf(ctx, "300s"); err != nil {
		t.Fatalf("RenewSelf failed: %v", err)
	}
	if renewBody["increment"] != "300s" {
		t.Fatalf("expected increment=300s, got %v", renewBody["increment"])
	}
}

func TestOpenBaoClient_Health(t *testing.T) {
	healthStatus := http.StatusOK
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/sys/health" {
			w.WriteHeader(healthStatus)
			return
		}
		http.NotFound(w, r)
	}))
	defer server.Close()

	client := NewOpenBaoClient(OpenBaoConfig{Address: server.URL})
	ctx := context.Background()

	// 200 OK -> active
	if err := client.Health(ctx); err != nil {
		t.Fatalf("Health expected nil on 200, got %v", err)
	}

	// 429 -> standby active
	healthStatus = http.StatusTooManyRequests
	if err := client.Health(ctx); err != nil {
		t.Fatalf("Health expected nil on 429, got %v", err)
	}

	// 503 -> sealed / error
	healthStatus = http.StatusServiceUnavailable
	if err := client.Health(ctx); err == nil {
		t.Fatal("Health expected error on 503, got nil")
	}
}

func TestOpenBaoClient_CircuitBreaker_TripsAndRecovers(t *testing.T) {
	var attempts int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&attempts, 1)
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"errors":["internal backend error"]}`))
	}))
	defer server.Close()

	simulatedTime := time.Now()
	client := NewOpenBaoClient(OpenBaoConfig{
		Address:            server.URL,
		Token:              "test-token",
		BreakerMaxFailures: 3,
		BreakerCooldown:    5 * time.Second,
	})
	client.now = func() time.Time { return simulatedTime }
	client.breaker.now = func() time.Time { return simulatedTime }

	ctx := context.Background()

	// 3 failing requests to trip breaker
	for i := 1; i <= 3; i++ {
		_, err := client.RevokeAgentCredentials(ctx, "fe-signalloom-agents", "agent-1", fmt.Sprintf("k%d", i))
		if err == nil {
			t.Fatalf("call %d expected error, got nil", i)
		}
	}

	if client.breaker.State() != BreakerOpen {
		t.Fatalf("expected breaker state %q, got %q", BreakerOpen, client.breaker.State())
	}
	if atomic.LoadInt32(&attempts) != 3 {
		t.Fatalf("expected 3 server attempts, got %d", atomic.LoadInt32(&attempts))
	}

	// 4th request: Breaker is OPEN -> must fast-fail without touching HTTP server
	start := time.Now()
	res, err := client.RevokeAgentCredentials(ctx, "fe-signalloom-agents", "agent-1", "k4")
	duration := time.Since(start)

	if err == nil || !errors.Is(err, ErrCircuitBreakerOpen) {
		t.Fatalf("expected ErrCircuitBreakerOpen, got: %v", err)
	}
	if !errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("expected ErrEnforcementUnavailable wrap, got: %v", err)
	}
	if res.Outcome != OutcomeUnavailable {
		t.Fatalf("expected OutcomeUnavailable, got %s", res.Outcome)
	}
	if atomic.LoadInt32(&attempts) != 3 {
		t.Fatalf("expected HTTP attempt count to stay 3, got %d (breaker failed to fast-fail)", atomic.LoadInt32(&attempts))
	}
	if duration > 50*time.Millisecond {
		t.Fatalf("fast-fail was slow (%v)", duration)
	}

	// Advance time past cooldown period -> transitions to Half-Open on next probe
	simulatedTime = simulatedTime.Add(6 * time.Second)

	// In Half-Open, breaker allows probe request
	_, _ = client.RevokeAgentCredentials(ctx, "fe-signalloom-agents", "agent-1", "k5")
	if atomic.LoadInt32(&attempts) != 4 {
		t.Fatalf("expected probe request to reach server (attempts=4), got %d", atomic.LoadInt32(&attempts))
	}
}

func TestOpenBaoClient_CircuitBreaker_StateObservableInLogs(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()

	logBuf := &bytes.Buffer{}
	client := NewOpenBaoClient(OpenBaoConfig{
		Address:            server.URL,
		Token:              "test-token",
		BreakerMaxFailures: 1,
		BreakerCooldown:    10 * time.Second,
		LogWriter:          logBuf,
	})

	ctx := context.Background()
	_, _ = client.RevokeAgentCredentials(ctx, "fe-signalloom-agents", "agent-1", "k1")
	_, _ = client.RevokeAgentCredentials(ctx, "fe-signalloom-agents", "agent-1", "k2")

	lines := strings.Split(strings.TrimSpace(logBuf.String()), "\n")
	if len(lines) < 2 {
		t.Fatalf("expected at least 2 log lines, got %d", len(lines))
	}

	var entry1, entry2 RevokeAuditLogEntry
	_ = json.Unmarshal([]byte(lines[0]), &entry1)
	_ = json.Unmarshal([]byte(lines[1]), &entry2)

	if entry1.CircuitBreakerState != string(BreakerClosed) {
		t.Fatalf("expected entry 1 cb_state %q, got %q", BreakerClosed, entry1.CircuitBreakerState)
	}
	if entry2.CircuitBreakerState != string(BreakerOpen) {
		t.Fatalf("expected entry 2 cb_state %q, got %q", BreakerOpen, entry2.CircuitBreakerState)
	}
}

func TestOpenBaoClient_ContextCancellation(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(500 * time.Millisecond)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	client := NewOpenBaoClient(OpenBaoConfig{Address: server.URL, Token: "test-token"})
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // Cancel immediately

	_, err := client.RevokeAgentCredentials(ctx, "fe-signalloom-agents", "agent-1", "k-cancel")
	if err == nil {
		t.Fatal("expected error on cancelled context, got nil")
	}
	if !errors.Is(err, context.Canceled) && !strings.Contains(err.Error(), "context canceled") {
		t.Fatalf("expected context.Canceled in error, got %v", err)
	}
}

func TestOpenBaoClient_FailureInjection_UnavailableOutcome(t *testing.T) {
	// Connect to non-existent endpoint
	client := NewOpenBaoClient(OpenBaoConfig{
		Address: "http://127.0.0.1:59999",
		Token:   "test-token",
		Timeout: 100 * time.Millisecond,
	})

	ctx := context.Background()
	res, err := client.RevokeAgentCredentials(ctx, "fe-signalloom-agents", "agent-monitor", "fail-inject")
	if err == nil {
		t.Fatal("expected error when OpenBao is unreachable, got nil")
	}
	if !errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("expected ErrEnforcementUnavailable, got: %v", err)
	}
	if res.Outcome != OutcomeUnavailable {
		t.Fatalf("expected OutcomeUnavailable, got %q", res.Outcome)
	}
	if res.Details["worst_case_residual_ms"] != DefaultWorstCaseResidualMs {
		t.Fatalf("expected worst_case_residual_ms in details, got %v", res.Details["worst_case_residual_ms"])
	}
}

func TestOpenBaoClient_PermissionDenied_ReturnsDenied(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"errors":["permission denied: path sys/leases/revoke requires update capability"]}`))
	}))
	defer server.Close()

	client := NewOpenBaoClient(OpenBaoConfig{Address: server.URL, Token: "unprivileged-token"})
	ctx := context.Background()

	res, err := client.RevokeAgentCredentials(ctx, "fe-signalloom-agents", "agent-1", "k-denied")
	if err == nil {
		t.Fatal("expected error on 403 Forbidden, got nil")
	}
	if !errors.Is(err, ErrEnforcementDenied) {
		t.Fatalf("expected ErrEnforcementDenied, got: %v", err)
	}
	if res.Outcome != OutcomeUnavailable {
		t.Fatalf("expected OutcomeUnavailable on permission denied, got %s", res.Outcome)
	}
}

func TestOpenBaoClient_StructuredLogFormat_MatchesAttestationSchema(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	logBuf := &bytes.Buffer{}
	client := NewOpenBaoClient(OpenBaoConfig{
		Address:   server.URL,
		Token:     "test-token",
		LogWriter: logBuf,
	})

	ctx := context.Background()
	_, err := client.RevokeAgentCredentials(ctx, "fe-signalloom-agents", "agent-cardvault", "idem-attest-1")
	if err != nil {
		t.Fatalf("revoke failed: %v", err)
	}

	var entry RevokeAuditLogEntry
	if err := json.Unmarshal(bytes.TrimSpace(logBuf.Bytes()), &entry); err != nil {
		t.Fatalf("failed to unmarshal structured log: %v", err)
	}

	if entry.Event != "bao_revoke_attempt" {
		t.Fatalf("expected event 'bao_revoke_attempt', got %q", entry.Event)
	}
	if entry.AgentID != "agent-cardvault" {
		t.Fatalf("expected agent_id 'agent-cardvault', got %q", entry.AgentID)
	}
	if entry.Namespace != "fe-signalloom-agents" {
		t.Fatalf("expected namespace 'fe-signalloom-agents', got %q", entry.Namespace)
	}
	if entry.IdempotencyKey != "idem-attest-1" {
		t.Fatalf("expected idempotency_key 'idem-attest-1', got %q", entry.IdempotencyKey)
	}
	if entry.Outcome != OutcomeContained {
		t.Fatalf("expected outcome 'contained', got %q", entry.Outcome)
	}
	if entry.CircuitBreakerState != string(BreakerClosed) {
		t.Fatalf("expected breaker_state 'closed', got %q", entry.CircuitBreakerState)
	}
	if entry.WorstCaseResidualMs != DefaultWorstCaseResidualMs {
		t.Fatalf("expected worst_case_residual_ms 300000, got %d", entry.WorstCaseResidualMs)
	}
	if entry.Timestamp == "" {
		t.Fatal("expected non-empty timestamp")
	}
}

func TestOpenBaoClient_AuditLogAgreement(t *testing.T) {
	// Simulate OpenBao server audit logging
	var serverAuditLog []map[string]any
	var mu sync.Mutex

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var reqData map[string]any
		_ = json.NewDecoder(r.Body).Decode(&reqData)

		mu.Lock()
		serverAuditLog = append(serverAuditLog, map[string]any{
			"type": "request",
			"path": strings.TrimPrefix(r.URL.Path, "/v1/"),
			"data": reqData,
			"auth": map[string]any{"token": r.Header.Get("X-Vault-Token")},
		})
		mu.Unlock()

		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	logBuf := &bytes.Buffer{}
	client := NewOpenBaoClient(OpenBaoConfig{
		Address:   server.URL,
		Token:     "audit-scoped-token",
		LogWriter: logBuf,
	})

	ctx := context.Background()
	targetAgent := "agent-processor"
	_, err := client.RevokeAgentCredentials(ctx, "fe-signalloom-agents", targetAgent, "audit-key-1")
	if err != nil {
		t.Fatalf("revoke failed: %v", err)
	}

	// Parse client log entry
	var clientLog RevokeAuditLogEntry
	if err := json.Unmarshal(bytes.TrimSpace(logBuf.Bytes()), &clientLog); err != nil {
		t.Fatalf("failed to decode client log: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(serverAuditLog) != 1 {
		t.Fatalf("expected 1 server audit entry, got %d", len(serverAuditLog))
	}

	srvEntry := serverAuditLog[0]
	if srvEntry["path"] != "sys/leases/revoke" {
		t.Fatalf("expected path 'sys/leases/revoke', got %v", srvEntry["path"])
	}

	dataMap, _ := srvEntry["data"].(map[string]any)
	expectedLease := fmt.Sprintf("cardvault/creds/%s", targetAgent)
	if dataMap["lease_id"] != expectedLease {
		t.Fatalf("server audit log lease_id %v does not match expected %s", dataMap["lease_id"], expectedLease)
	}
	if clientLog.AgentID != targetAgent {
		t.Fatalf("client log agent_id %s does not match %s", clientLog.AgentID, targetAgent)
	}
}

func TestOpenBaoClient_PostRevokeAuthRejection(t *testing.T) {
	// Simulate OpenBao state: active leases vs revoked leases
	var activeLeases = map[string]bool{
		"cardvault/creds/agent-cardvault/lease-active": true,
	}
	var mu sync.Mutex

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()

		if r.URL.Path == "/v1/sys/leases/revoke" {
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			leaseID, _ := body["lease_id"].(string)
			delete(activeLeases, leaseID)
			w.WriteHeader(http.StatusNoContent)
			return
		}

		if r.URL.Path == "/v1/sys/leases/lookup" {
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			leaseID, _ := body["lease_id"].(string)
			if activeLeases[leaseID] {
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte(`{"data":{"id":"` + leaseID + `","ttl":300}}`))
			} else {
				w.WriteHeader(http.StatusNotFound)
				_, _ = w.Write([]byte(`{"errors":["lease not found or revoked"]}`))
			}
			return
		}

		http.NotFound(w, r)
	}))
	defer server.Close()

	client := NewOpenBaoClient(OpenBaoConfig{Address: server.URL, Token: "test-token"})
	ctx := context.Background()

	targetLease := "cardvault/creds/agent-cardvault/lease-active"

	// 1. Verify lease is active initially
	lookupReq, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/sys/leases/lookup", strings.NewReader(`{"lease_id":"`+targetLease+`"}`))
	lookupResp1, err := http.DefaultClient.Do(lookupReq)
	if err != nil || lookupResp1.StatusCode != http.StatusOK {
		t.Fatalf("initial lookup failed: code=%v, err=%v", lookupResp1.StatusCode, err)
	}

	// 2. Perform active revocation
	req := BaoRevokeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "revoke-auth-test",
		AgentID:        "agent-cardvault",
		LeaseIDs:       []string{targetLease},
	}
	resp, err := client.RevokeLease(ctx, req)
	if err != nil || resp.Outcome != OutcomeContained {
		t.Fatalf("revocation failed: resp=%v, err=%v", resp, err)
	}

	// 3. Verify post-revoke authentication/lookup attempt fails (guaranteed denial)
	lookupReq2, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/sys/leases/lookup", strings.NewReader(`{"lease_id":"`+targetLease+`"}`))
	lookupResp2, err := http.DefaultClient.Do(lookupReq2)
	if err != nil {
		t.Fatalf("post-revoke lookup request error: %v", err)
	}
	if lookupResp2.StatusCode != http.StatusNotFound {
		t.Fatalf("expected post-revoke lookup to fail with 404 Not Found, got %d", lookupResp2.StatusCode)
	}
}

func TestOpenBaoClient_LatencyDistribution_Benchmark10x(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Simulate OpenBao internal storage deletion delay (5-15ms)
		time.Sleep(10 * time.Millisecond)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	client := NewOpenBaoClient(OpenBaoConfig{
		Address: server.URL,
		Token:   "benchmark-token",
	})
	ctx := context.Background()

	const iterations = 10
	durations := make([]time.Duration, iterations)

	for i := 0; i < iterations; i++ {
		start := time.Now()
		req := BaoRevokeRequest{
			SchemaVersion:  FrozenSchemaVersion,
			IdempotencyKey: fmt.Sprintf("bench-key-%d", i),
			AgentID:        fmt.Sprintf("agent-bench-%d", i),
			LeaseIDs:       []string{fmt.Sprintf("cardvault/creds/agent-bench-%d/lease-%d", i, i)},
		}
		resp, err := client.RevokeLease(ctx, req)
		durations[i] = time.Since(start)

		if err != nil || resp.Outcome != OutcomeContained {
			t.Fatalf("iteration %d failed: err=%v, resp=%v", i, err, resp)
		}
	}

	sort.Slice(durations, func(i, j int) bool { return durations[i] < durations[j] })

	min := durations[0]
	max := durations[iterations-1]
	p50 := durations[iterations/2]
	p90 := durations[int(math.Floor(float64(iterations)*0.90))]
	p99 := durations[iterations-1]

	var total time.Duration
	for _, d := range durations {
		total += d
	}
	mean := total / time.Duration(iterations)

	t.Logf("10x OpenBao Revocation Latency Distribution:")
	t.Logf("  Min:  %v", min)
	t.Logf("  P50:  %v", p50)
	t.Logf("  P90:  %v", p90)
	t.Logf("  P99:  %v", p99)
	t.Logf("  Max:  %v", max)
	t.Logf("  Mean: %v", mean)

	// Invariant: Guaranteed denial must beat 2000ms SLA and 300s baseline
	if p99 > 2000*time.Millisecond {
		t.Fatalf("p99 latency %v exceeded 2000ms SLA", p99)
	}
}

func TestOpenBaoClient_AutoRenew(t *testing.T) {
	var renewCount int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/auth/token/renew-self" {
			atomic.AddInt32(&renewCount, 1)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"auth":{"client_token":"s.token"}}`))
			return
		}
		http.NotFound(w, r)
	}))
	defer server.Close()

	client := NewOpenBaoClient(OpenBaoConfig{
		Address: server.URL,
		Token:   "s.auto-renew-token",
	})

	ctx, cancel := context.WithCancel(context.Background())
	client.StartAutoRenew(ctx, 20*time.Millisecond)

	time.Sleep(75 * time.Millisecond)
	cancel()
	time.Sleep(30 * time.Millisecond)

	count := atomic.LoadInt32(&renewCount)
	if count < 2 {
		t.Fatalf("expected at least 2 renewals, got %d", count)
	}
}
