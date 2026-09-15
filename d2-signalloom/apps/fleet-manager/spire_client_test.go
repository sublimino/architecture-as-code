package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	entryv1 "github.com/spiffe/spire-api-sdk/proto/spire/api/server/entry/v1"
	spiretypes "github.com/spiffe/spire-api-sdk/proto/spire/api/types"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"k8s.io/client-go/kubernetes/fake"
)

// ── Mock SPIRE Entry Server ──────────────────────────────────────────────────

type mockEntryServer struct {
	entryv1.UnimplementedEntryServer
	mu               sync.Mutex
	entries          map[string]*spiretypes.Entry
	deleteHandler    func(ctx context.Context, req *entryv1.BatchDeleteEntryRequest) (*entryv1.BatchDeleteEntryResponse, error)
	listHandler      func(ctx context.Context, req *entryv1.ListEntriesRequest) (*entryv1.ListEntriesResponse, error)
	countHandler     func(ctx context.Context, req *entryv1.CountEntriesRequest) (*entryv1.CountEntriesResponse, error)
	deleteCallCount  atomic.Int32
	listCallCount    atomic.Int32
	batchDeleteDelay time.Duration
}

func newMockEntryServer() *mockEntryServer {
	return &mockEntryServer{
		entries: make(map[string]*spiretypes.Entry),
	}
}

func (m *mockEntryServer) BatchDeleteEntry(ctx context.Context, req *entryv1.BatchDeleteEntryRequest) (*entryv1.BatchDeleteEntryResponse, error) {
	m.deleteCallCount.Add(1)

	if m.batchDeleteDelay > 0 {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(m.batchDeleteDelay):
		}
	}

	if ctx.Err() != nil {
		return nil, ctx.Err()
	}

	if m.deleteHandler != nil {
		return m.deleteHandler(ctx, req)
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	results := make([]*entryv1.BatchDeleteEntryResponse_Result, len(req.Ids))
	for i, id := range req.Ids {
		if _, exists := m.entries[id]; exists {
			delete(m.entries, id)
			results[i] = &entryv1.BatchDeleteEntryResponse_Result{
				Id: id,
				Status: &spiretypes.Status{
					Code:    int32(codes.OK),
					Message: "OK",
				},
			}
		} else {
			// SPIRE returns NotFound status in the result for already-deleted/non-existent entries
			results[i] = &entryv1.BatchDeleteEntryResponse_Result{
				Id: id,
				Status: &spiretypes.Status{
					Code:    int32(codes.NotFound),
					Message: "entry not found",
				},
			}
		}
	}

	return &entryv1.BatchDeleteEntryResponse{
		Results: results,
	}, nil
}

func (m *mockEntryServer) ListEntries(ctx context.Context, req *entryv1.ListEntriesRequest) (*entryv1.ListEntriesResponse, error) {
	m.listCallCount.Add(1)

	if ctx.Err() != nil {
		return nil, ctx.Err()
	}

	if m.listHandler != nil {
		return m.listHandler(ctx, req)
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	var matching []*spiretypes.Entry
	filter := req.GetFilter()

	for _, entry := range m.entries {
		if filter != nil && filter.BySpiffeId != nil {
			if entry.SpiffeId != nil &&
				entry.SpiffeId.TrustDomain == filter.BySpiffeId.TrustDomain &&
				entry.SpiffeId.Path == filter.BySpiffeId.Path {
				matching = append(matching, entry)
			}
		} else {
			matching = append(matching, entry)
		}
	}

	return &entryv1.ListEntriesResponse{
		Entries: matching,
	}, nil
}

func (m *mockEntryServer) CountEntries(ctx context.Context, req *entryv1.CountEntriesRequest) (*entryv1.CountEntriesResponse, error) {
	if m.countHandler != nil {
		return m.countHandler(ctx, req)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return &entryv1.CountEntriesResponse{
		Count: int32(len(m.entries)),
	}, nil
}

// startTestGRPCServer starts an in-process gRPC server with the mock SPIRE Entry service.
func startTestGRPCServer(t *testing.T, srv *mockEntryServer) (*grpcSpireClient, func()) {
	t.Helper()

	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("failed to listen on local port: %v", err)
	}

	s := grpc.NewServer()
	entryv1.RegisterEntryServer(s, srv)

	go func() {
		_ = s.Serve(lis)
	}()

	client, err := NewGRPCSpireClient(lis.Addr().String())
	if err != nil {
		s.Stop()
		_ = lis.Close()
		t.Fatalf("failed to create grpc spire client: %v", err)
	}

	cleanup := func() {
		_ = client.Close()
		s.Stop()
		_ = lis.Close()
	}

	return client, cleanup
}

// ── Tests ────────────────────────────────────────────────────────────────────

func TestSpireClient_DeleteEntry_Success(t *testing.T) {
	srv := newMockEntryServer()
	srv.entries["entry-uuid-1"] = &spiretypes.Entry{
		Id: "entry-uuid-1",
		SpiffeId: &spiretypes.SPIFFEID{
			TrustDomain: "signalloom.demo",
			Path:        "/ns/fe-signalloom-agents/sa/cardvault-agent",
		},
	}

	client, cleanup := startTestGRPCServer(t, srv)
	defer cleanup()

	ctx := context.Background()
	result, err := client.DeleteEntry(ctx, "entry-uuid-1")
	if err != nil {
		t.Fatalf("DeleteEntry failed: %v", err)
	}

	if result.Outcome != OutcomeContained {
		t.Fatalf("expected outcome %q, got %q", OutcomeContained, result.Outcome)
	}
	if result.StatusCode != 0 {
		t.Fatalf("expected status code 0, got %d", result.StatusCode)
	}
	if result.Idempotent {
		t.Fatal("first deletion should not be marked idempotent")
	}
	if result.EntryID != "entry-uuid-1" {
		t.Fatalf("expected entry ID 'entry-uuid-1', got %q", result.EntryID)
	}
}

func TestSpireClient_DeleteEntry_IdempotentNotFound(t *testing.T) {
	srv := newMockEntryServer()
	// Server has no entries registered

	client, cleanup := startTestGRPCServer(t, srv)
	defer cleanup()

	ctx := context.Background()
	// Deleting a non-existent or already-deleted entry
	result, err := client.DeleteEntry(ctx, "already-deleted-uuid")
	if err != nil {
		t.Fatalf("idempotent delete should not return error, got: %v", err)
	}

	if result.Outcome != OutcomeContained {
		t.Fatalf("expected outcome %q for already-deleted entry, got %q", OutcomeContained, result.Outcome)
	}
	if !result.Idempotent {
		t.Fatal("expected idempotent flag to be true for already-deleted entry")
	}
	if result.StatusCode != int32(codes.NotFound) {
		t.Fatalf("expected status code %d (NotFound), got %d", codes.NotFound, result.StatusCode)
	}
}

func TestSpireClient_BatchDeleteEntries_MixedOutcomes(t *testing.T) {
	srv := newMockEntryServer()
	srv.entries["entry-1"] = &spiretypes.Entry{Id: "entry-1"}
	// entry-2 is absent (NotFound)

	srv.deleteHandler = func(ctx context.Context, req *entryv1.BatchDeleteEntryRequest) (*entryv1.BatchDeleteEntryResponse, error) {
		results := make([]*entryv1.BatchDeleteEntryResponse_Result, len(req.Ids))
		for i, id := range req.Ids {
			switch id {
			case "entry-1":
				results[i] = &entryv1.BatchDeleteEntryResponse_Result{
					Id:     id,
					Status: &spiretypes.Status{Code: int32(codes.OK), Message: "OK"},
				}
			case "entry-2":
				results[i] = &entryv1.BatchDeleteEntryResponse_Result{
					Id:     id,
					Status: &spiretypes.Status{Code: int32(codes.NotFound), Message: "entry not found"},
				}
			case "entry-3":
				results[i] = &entryv1.BatchDeleteEntryResponse_Result{
					Id:     id,
					Status: &spiretypes.Status{Code: int32(codes.InvalidArgument), Message: "malformed entry ID"},
				}
			}
		}
		return &entryv1.BatchDeleteEntryResponse{Results: results}, nil
	}

	client, cleanup := startTestGRPCServer(t, srv)
	defer cleanup()

	ctx := context.Background()
	results, err := client.BatchDeleteEntries(ctx, []string{"entry-1", "entry-2", "entry-3"})
	if err == nil {
		t.Fatal("expected error due to entry-3 invalid argument failure")
	}
	if !errors.Is(err, ErrSpireInvalidEntry) {
		t.Fatalf("expected ErrSpireInvalidEntry, got: %v", err)
	}

	if len(results) != 3 {
		t.Fatalf("expected 3 results, got %d", len(results))
	}

	// entry-1: contained, not idempotent
	if results[0].Outcome != OutcomeContained || results[0].Idempotent {
		t.Errorf("entry-1 unexpected result: %+v", results[0])
	}
	// entry-2: contained, idempotent
	if results[1].Outcome != OutcomeContained || !results[1].Idempotent {
		t.Errorf("entry-2 unexpected result: %+v", results[1])
	}
	// entry-3: unavailable, invalid argument
	if results[2].Outcome != OutcomeUnavailable || results[2].StatusCode != int32(codes.InvalidArgument) {
		t.Errorf("entry-3 unexpected result: %+v", results[2])
	}
}

func TestSpireClient_StatusMapping_AllGRPCCodes(t *testing.T) {
	testCases := []struct {
		code           codes.Code
		msg            string
		wantOutcome    PlaneOutcome
		wantErrorIs    error
		wantIdempotent bool
	}{
		{
			code:           codes.OK,
			msg:            "OK",
			wantOutcome:    OutcomeContained,
			wantErrorIs:    nil,
			wantIdempotent: false,
		},
		{
			code:           codes.NotFound,
			msg:            "entry not found",
			wantOutcome:    OutcomeContained,
			wantErrorIs:    nil,
			wantIdempotent: true,
		},
		{
			code:           codes.InvalidArgument,
			msg:            "invalid entry ID format",
			wantOutcome:    OutcomeUnavailable,
			wantErrorIs:    ErrSpireInvalidEntry,
			wantIdempotent: false,
		},
		{
			code:           codes.PermissionDenied,
			msg:            "caller lacks entry:delete permission",
			wantOutcome:    OutcomeUnavailable,
			wantErrorIs:    ErrEnforcementDenied,
			wantIdempotent: false,
		},
		{
			code:           codes.Unauthenticated,
			msg:            "missing x509-svid",
			wantOutcome:    OutcomeUnavailable,
			wantErrorIs:    ErrEnforcementDenied,
			wantIdempotent: false,
		},
		{
			code:           codes.Unavailable,
			msg:            "spire-server connection refused",
			wantOutcome:    OutcomeUnavailable,
			wantErrorIs:    ErrEnforcementUnavailable,
			wantIdempotent: false,
		},
		{
			code:           codes.DeadlineExceeded,
			msg:            "context deadline exceeded",
			wantOutcome:    OutcomeUnavailable,
			wantErrorIs:    ErrEnforcementUnavailable,
			wantIdempotent: false,
		},
		{
			code:           codes.Internal,
			msg:            "sqlite datastore disk full",
			wantOutcome:    OutcomeUnavailable,
			wantErrorIs:    ErrEnforcementUnavailable,
			wantIdempotent: false,
		},
		{
			code:           codes.ResourceExhausted,
			msg:            "rate limit exceeded",
			wantOutcome:    OutcomeUnavailable,
			wantErrorIs:    ErrEnforcementUnavailable,
			wantIdempotent: false,
		},
	}

	for _, tc := range testCases {
		t.Run(tc.code.String(), func(t *testing.T) {
			outcome, err, isIdempotent := MapGRPCStatusToOutcome(tc.code, tc.msg, nil)

			if outcome != tc.wantOutcome {
				t.Errorf("code %v: expected outcome %q, got %q", tc.code, tc.wantOutcome, outcome)
			}
			if isIdempotent != tc.wantIdempotent {
				t.Errorf("code %v: expected idempotent %v, got %v", tc.code, tc.wantIdempotent, isIdempotent)
			}
			if tc.wantErrorIs != nil {
				if err == nil || !errors.Is(err, tc.wantErrorIs) {
					t.Errorf("code %v: expected error wrapping %v, got %v", tc.code, tc.wantErrorIs, err)
				}
			} else if err != nil {
				t.Errorf("code %v: expected nil error, got %v", tc.code, err)
			}
		})
	}
}

func TestSpireClient_ContextCancellationAndDeadlinePropagation(t *testing.T) {
	srv := newMockEntryServer()
	srv.batchDeleteDelay = 500 * time.Millisecond // Slow server

	client, cleanup := startTestGRPCServer(t, srv)
	defer cleanup()

	// Short timeout bounding the call
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err := client.DeleteEntry(ctx, "entry-timeout-test")
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("expected deadline exceeded error, got nil")
	}
	if !errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("expected ErrEnforcementUnavailable on timeout, got: %v", err)
	}

	// Must fail fast without hanging
	if elapsed > 200*time.Millisecond {
		t.Fatalf("call took %v, failed to respect context deadline", elapsed)
	}
}

func TestSpireClient_AddressConfigurationFromEnv(t *testing.T) {
	// Test default fallback
	_ = os.Unsetenv("SPIRE_SERVER_ADDR")
	_ = os.Unsetenv("SPIRE_ADDR")
	_ = os.Unsetenv("SPIRE_SERVER_SOCKET")
	_ = os.Unsetenv("SPIRE_SOCKET")

	if addr := ResolveSpireAddress(); addr != DefaultSpireServerAddr {
		t.Fatalf("expected default %q, got %q", DefaultSpireServerAddr, addr)
	}

	// Test SPIRE_ADDR
	_ = os.Setenv("SPIRE_ADDR", "custom-spire.inf-bao.svc.cluster.local:8081")
	if addr := ResolveSpireAddress(); addr != "custom-spire.inf-bao.svc.cluster.local:8081" {
		t.Fatalf("expected SPIRE_ADDR override, got %q", addr)
	}

	// Test SPIRE_SERVER_ADDR takes precedence
	_ = os.Setenv("SPIRE_SERVER_ADDR", "priority-spire:8081")
	if addr := ResolveSpireAddress(); addr != "priority-spire:8081" {
		t.Fatalf("expected SPIRE_SERVER_ADDR priority, got %q", addr)
	}

	// Test unix socket path
	_ = os.Setenv("SPIRE_SERVER_SOCKET", "/run/spire/sockets/agent.sock")
	_ = os.Unsetenv("SPIRE_SERVER_ADDR")
	_ = os.Unsetenv("SPIRE_ADDR")
	if addr := ResolveSpireAddress(); addr != "/run/spire/sockets/agent.sock" {
		t.Fatalf("expected socket path, got %q", addr)
	}

	// Clean up
	_ = os.Unsetenv("SPIRE_SERVER_SOCKET")
}

func TestSpireClient_FormatDialTarget(t *testing.T) {
	cases := []struct {
		input      string
		wantTarget string
	}{
		{"unix:///tmp/spire.sock", "unix:///tmp/spire.sock"},
		{"/run/spire/sockets/agent.sock", "unix:///run/spire/sockets/agent.sock"},
		{"tcp://spire-server:8081", "spire-server:8081"},
		{"spire-server.inf-bao.svc.cluster.local:8081", "spire-server.inf-bao.svc.cluster.local:8081"},
		{"127.0.0.1:8081", "127.0.0.1:8081"},
	}

	for _, tc := range cases {
		target, _ := formatDialTarget(tc.input)
		if target != tc.wantTarget {
			t.Errorf("formatDialTarget(%q): expected %q, got %q", tc.input, tc.wantTarget, target)
		}
	}
}

func TestSpireClient_ParseSPIFFEID(t *testing.T) {
	cases := []struct {
		input       string
		wantDomain  string
		wantPath    string
		expectError bool
	}{
		{
			input:      "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent",
			wantDomain: "signalloom.demo",
			wantPath:   "/ns/fe-signalloom-agents/sa/cardvault-agent",
		},
		{
			input:      "spiffe://signalloom.demo/platform/signalloom/tenant/acme/agent/planner",
			wantDomain: "signalloom.demo",
			wantPath:   "/platform/signalloom/tenant/acme/agent/planner",
		},
		{
			input:       "https://example.com/not-spiffe",
			expectError: true,
		},
		{
			input:       "spiffe:///missing-trust-domain",
			expectError: true,
		},
	}

	for _, tc := range cases {
		res, err := ParseSPIFFEID(tc.input)
		if tc.expectError {
			if err == nil {
				t.Errorf("ParseSPIFFEID(%q): expected error, got nil", tc.input)
			}
			continue
		}
		if err != nil {
			t.Errorf("ParseSPIFFEID(%q): unexpected error: %v", tc.input, err)
			continue
		}
		if res.TrustDomain != tc.wantDomain || res.Path != tc.wantPath {
			t.Errorf("ParseSPIFFEID(%q): got domain=%q path=%q, want domain=%q path=%q",
				tc.input, res.TrustDomain, res.Path, tc.wantDomain, tc.wantPath)
		}
	}
}

func TestSpireClient_EvictAgent_WithSPIFFEIDLookup(t *testing.T) {
	srv := newMockEntryServer()
	spiffeID := "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent"

	srv.entries["eid-101"] = &spiretypes.Entry{
		Id: "eid-101",
		SpiffeId: &spiretypes.SPIFFEID{
			TrustDomain: "signalloom.demo",
			Path:        "/ns/fe-signalloom-agents/sa/cardvault-agent",
		},
	}
	srv.entries["eid-102"] = &spiretypes.Entry{
		Id: "eid-102",
		SpiffeId: &spiretypes.SPIFFEID{
			TrustDomain: "signalloom.demo",
			Path:        "/ns/fe-signalloom-agents/sa/cardvault-agent",
		},
	}

	client, cleanup := startTestGRPCServer(t, srv)
	defer cleanup()

	ctx := context.Background()
	req := SpireEvictionRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: "idemp-key-123",
		AgentID:        "cardvault-agent",
		SPIFFEID:       spiffeID,
		Reason:         "containment cascade",
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}

	resp, err := client.EvictAgent(ctx, req)
	if err != nil {
		t.Fatalf("EvictAgent failed: %v", err)
	}

	if resp.Outcome != OutcomeContained {
		t.Fatalf("expected OutcomeContained, got %q", resp.Outcome)
	}
	if resp.EntriesEvicted != 2 {
		t.Fatalf("expected 2 entries evicted, got %d", resp.EntriesEvicted)
	}

	// Verify entries were deleted from server
	if len(srv.entries) != 0 {
		t.Fatalf("expected 0 remaining entries on server, got %d", len(srv.entries))
	}

	// Second eviction call (retry) should be an idempotent pass with 0 entries found
	retryResp, retryErr := client.EvictAgent(ctx, req)
	if retryErr != nil {
		t.Fatalf("retry EvictAgent should succeed idempotently, got: %v", retryErr)
	}
	if retryResp.Outcome != OutcomeContained {
		t.Fatalf("expected OutcomeContained on retry, got %q", retryResp.Outcome)
	}
	if retryResp.EntriesEvicted != 0 {
		t.Fatalf("expected 0 entries evicted on retry, got %d", retryResp.EntriesEvicted)
	}
}

func TestSpireClient_StructuredLoggingOutput(t *testing.T) {
	var buf bytes.Buffer
	handler := slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelInfo})
	oldLogger := slog.Default()
	slog.SetDefault(slog.New(handler))
	defer slog.SetDefault(oldLogger)

	srv := newMockEntryServer()
	srv.entries["log-entry-1"] = &spiretypes.Entry{Id: "log-entry-1"}

	client, cleanup := startTestGRPCServer(t, srv)
	defer cleanup()

	ctx := context.Background()
	_, _ = client.DeleteEntry(ctx, "log-entry-1")

	logOutput := buf.String()
	if !strings.Contains(logOutput, "spire entry deletion") {
		t.Fatalf("expected 'spire entry deletion' in logs, got: %s", logOutput)
	}
	if !strings.Contains(logOutput, "log-entry-1") {
		t.Fatalf("expected entry ID in logs, got: %s", logOutput)
	}
	if !strings.Contains(logOutput, `"grpc_code":0`) {
		t.Fatalf("expected grpc_code:0 in logs, got: %s", logOutput)
	}
	if !strings.Contains(logOutput, `"outcome":"contained"`) {
		t.Fatalf("expected outcome:contained in logs, got: %s", logOutput)
	}
}

func TestSpireClient_ConcurrentBatchLoad(t *testing.T) {
	srv := newMockEntryServer()
	const numEntries = 50
	for i := 0; i < numEntries; i++ {
		id := fmt.Sprintf("entry-load-%d", i)
		srv.entries[id] = &spiretypes.Entry{Id: id}
	}

	client, cleanup := startTestGRPCServer(t, srv)
	defer cleanup()

	var wg sync.WaitGroup
	errCh := make(chan error, numEntries)
	start := time.Now()

	for i := 0; i < numEntries; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			id := fmt.Sprintf("entry-load-%d", idx)
			res, err := client.DeleteEntry(context.Background(), id)
			if err != nil {
				errCh <- fmt.Errorf("entry %s failed: %w", id, err)
				return
			}
			if res.Outcome != OutcomeContained {
				errCh <- fmt.Errorf("entry %s outcome %q", id, res.Outcome)
			}
		}(i)
	}

	wg.Wait()
	close(errCh)
	elapsed := time.Since(start)

	for err := range errCh {
		t.Errorf("concurrent error: %v", err)
	}

	if len(srv.entries) != 0 {
		t.Fatalf("expected all entries deleted, %d remain", len(srv.entries))
	}

	t.Logf("Deleted %d entries concurrently across goroutines in %v", numEntries, elapsed)
}

func TestSpireClient_SVIDRejectionWindow_EmpiricalSimulation(t *testing.T) {
	// Empirical model test:
	// Simulates the SVID cache residual window post-eviction.
	// 1. A workload fetches an SVID at T0 with validity TTL=300s (JWT) or 3600s (X509).
	// 2. SPIRE entry eviction occurs at T1 (latency < 50ms).
	// 3. Workload holds SVID in memory: presenting cached SVID succeeds until T0 + TTL.
	// 4. Once TTL elapses (or when refreshed from SPIRE Agent socket after entry deletion),
	//    re-attestation / new token issuance fails with 'entry not found'.

	type SVIDToken struct {
		Subject   string
		IssuedAt  time.Time
		ExpiresAt time.Time
	}

	// Simulate workload SVID acquisition
	t0 := time.Now()
	jwtTTL := 300 * time.Second
	token := SVIDToken{
		Subject:   "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent",
		IssuedAt:  t0,
		ExpiresAt: t0.Add(jwtTTL),
	}

	// Verify token is valid initially
	validateToken := func(tok SVIDToken, at time.Time) error {
		if at.After(tok.ExpiresAt) {
			return errors.New("token expired")
		}
		return nil
	}

	if err := validateToken(token, t0.Add(10*time.Second)); err != nil {
		t.Fatalf("cached SVID should be accepted within residual window: %v", err)
	}

	// Simulated entry eviction
	entryDeleted := true

	// Workload re-fetch from SPIRE agent Workload API after entry deletion
	fetchNewSVID := func() (*SVIDToken, error) {
		if entryDeleted {
			return nil, errors.New("no identity issued: entry not found on spire server")
		}
		now := time.Now()
		return &SVIDToken{
			Subject:   "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent",
			IssuedAt:  now,
			ExpiresAt: now.Add(jwtTTL),
		}, nil
	}

	// Re-fetch fails immediately post-eviction
	_, err := fetchNewSVID()
	if err == nil {
		t.Fatal("expected Workload API fetch to fail post-eviction")
	}

	// Presentation of cached token succeeds before TTL expires
	if err := validateToken(token, t0.Add(299*time.Second)); err != nil {
		t.Fatalf("cached token must remain accepted before 300s residual: %v", err)
	}

	// Presentation of cached token fails after TTL expires
	if err := validateToken(token, t0.Add(301*time.Second)); err == nil {
		t.Fatal("cached token must be rejected after 300s residual elapses")
	}
}

func TestK8sFleetClient_RevokeCredentials_WithSpireClient(t *testing.T) {
	srv := newMockEntryServer()
	srv.entries["mon-1"] = &spiretypes.Entry{
		Id: "mon-1",
		SpiffeId: &spiretypes.SPIFFEID{
			TrustDomain: "signalloom.demo",
			Path:        "/ns/fe-signalloom-agents/sa/agent-monitor",
		},
	}

	spireCl, cleanup := startTestGRPCServer(t, srv)
	defer cleanup()

	pod := agentPod("agent-monitor", "active", nil)
	cs := fake.NewSimpleClientset(pod)
	client := newK8sFleetClientWithSpire(cs, testNamespace, spireCl)

	ctx := context.Background()

	// Revoke credentials invokes SPIRE eviction
	if err := client.RevokeCredentials(ctx, "agent-monitor"); err != nil {
		t.Fatalf("RevokeCredentials failed: %v", err)
	}

	if len(srv.entries) != 0 {
		t.Fatalf("expected SPIRE entry to be deleted, %d remain", len(srv.entries))
	}

	// Degraded registry should not mark PlaneSpire degraded on success
	if client.degraded.isDegradedOnPlane(PlaneSpire, testNamespace, "agent-monitor") {
		t.Fatal("successful SPIRE revocation should not leave PlaneSpire degraded")
	}
}

func TestK8sFleetClient_RevokeCredentials_SpireUnavailableMarksDegraded(t *testing.T) {
	srv := newMockEntryServer()
	srv.entries["mon-1"] = &spiretypes.Entry{
		Id: "mon-1",
		SpiffeId: &spiretypes.SPIFFEID{
			TrustDomain: "signalloom.demo",
			Path:        "/ns/fe-signalloom-agents/sa/agent-monitor",
		},
	}
	srv.deleteHandler = func(ctx context.Context, req *entryv1.BatchDeleteEntryRequest) (*entryv1.BatchDeleteEntryResponse, error) {
		return nil, status.Error(codes.Unavailable, "spire server down")
	}

	spireCl, cleanup := startTestGRPCServer(t, srv)
	defer cleanup()

	pod := agentPod("agent-monitor", "active", nil)
	cs := fake.NewSimpleClientset(pod)
	client := newK8sFleetClientWithSpire(cs, testNamespace, spireCl)

	ctx := context.Background()
	err := client.RevokeCredentials(ctx, "agent-monitor")
	if err == nil {
		t.Fatal("expected error when SPIRE server is unavailable")
	}
	if !errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("expected ErrEnforcementUnavailable, got %v", err)
	}

	if !client.degraded.isDegradedOnPlane(PlaneSpire, testNamespace, "agent-monitor") {
		t.Fatal("expected PlaneSpire to be marked degraded when SPIRE call fails")
	}
}

func TestK8sFleetClient_Health_ChecksSpire(t *testing.T) {
	srv := newMockEntryServer()
	spireCl, cleanup := startTestGRPCServer(t, srv)
	defer cleanup()

	pod := agentPod("agent-monitor", "active", nil)
	cs := fake.NewSimpleClientset(pod)
	client := newK8sFleetClientWithSpire(cs, testNamespace, spireCl)

	if err := client.Health(context.Background()); err != nil {
		t.Fatalf("Health check should pass: %v", err)
	}

	// Inject CountEntries error on SPIRE server
	srv.countHandler = func(ctx context.Context, req *entryv1.CountEntriesRequest) (*entryv1.CountEntriesResponse, error) {
		return nil, status.Error(codes.Unavailable, "spire unhealthy")
	}

	err := client.Health(context.Background())
	if err == nil {
		t.Fatal("Health check should fail when SPIRE probe fails")
	}
	if !errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("expected ErrEnforcementUnavailable, got: %v", err)
	}
}
