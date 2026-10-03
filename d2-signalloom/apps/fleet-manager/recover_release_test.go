package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// A containment release (the gitops resume and the running-state write) is
// the operator's decision and must land even when credential restore cannot
// (SPIRE unreachable, Bao 403 with its breaker open). Live, 2026-10-03: every
// recover ended from=stunned to=stunned outcome=unavailable and kusari stayed
// frozen.

// hangingRestoreClient's credential restore hangs until its context ends, as a
// SPIRE dial or a Bao call with no deadline of its own does. Its state write
// fails exactly as a real API call does on a dead context.
type hangingRestoreClient struct {
	*mockFleetClient
	restoreCtxErr chan error
}

func (c *hangingRestoreClient) RestoreCredentials(ctx context.Context, agentID string) error {
	<-ctx.Done()
	c.restoreCtxErr <- ctx.Err()
	return ctx.Err()
}

func (c *hangingRestoreClient) SetPodState(ctx context.Context, ns, agentID, state string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return c.mockFleetClient.SetPodState(ctx, ns, agentID, state)
}

func newHangingServer(t *testing.T) (*server, *hangingRestoreClient) {
	t.Helper()
	dag := mustBuildTestDAG(t)
	client := &hangingRestoreClient{mockFleetClient: newMockClient(), restoreCtxErr: make(chan error, 4)}
	orch := NewCascadeOrchestrator(dag, client, 0)
	orch.credentialStepTimeout = 50 * time.Millisecond
	s := &server{dag: dag, orchestrator: orch, callerKeys: testCallerKeys(t)}
	return s, client
}

func TestAHangingCredentialRestoreCannotBlockTheRelease(t *testing.T) {
	s, client := newHangingServer(t)
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- call(t, s.routes(), http.MethodPost, "/api/v1/fleet/recover", `{"agent_ids":["agent-cardvault"]}`, "Bearer "+operatorKey)
	}()
	var w *httptest.ResponseRecorder
	select {
	case w = <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("recover never returned: a hanging credential restore held the release hostage")
	}
	if w.Code != http.StatusMultiStatus {
		t.Fatalf("status %d, want 207 (released, credentials not restored): %s", w.Code, w.Body.String())
	}
	if got := client.states["agent-cardvault"]; got != StateRunning {
		t.Fatalf("pod state = %q, want %q: the release did not land", got, StateRunning)
	}
	if !strings.Contains(w.Body.String(), `"credential":{"attempted":true,"succeeded":false`) {
		t.Fatalf("the failed credential restore is not reported: %s", w.Body.String())
	}
}

func TestACallerHangingUpCannotAbortTheRelease(t *testing.T) {
	s, client := newHangingServer(t)
	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/recover", strings.NewReader(`{"agent_ids":["agent-cardvault"]}`)).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	go func() { <-client.restoreCtxErr; client.restoreCtxErr <- nil }() // keep the channel draining
	cancel()                                                            // the client (curl --max-time, a dropped port-forward) gives up
	w := httptest.NewRecorder()
	s.routes().ServeHTTP(w, req)
	if got := client.states["agent-cardvault"]; got != StateRunning {
		t.Fatalf("pod state = %q after the caller hung up: the release rode the request context", got)
	}
}

// ctxCheckingClient fails its state write on a dead context, like a real API call.
type ctxCheckingClient struct{ *mockFleetClient }

func (c *ctxCheckingClient) SetPodState(ctx context.Context, ns, agentID, state string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return c.mockFleetClient.SetPodState(ctx, ns, agentID, state)
}

// The same holds for a stun: a containment aborted half-way because the
// sentinel's or the dashboard's connection dropped is a pod revoked but never
// marked stunned.
func TestACallerHangingUpCannotAbortAStun(t *testing.T) {
	dag := mustBuildTestDAG(t)
	client := &ctxCheckingClient{newMockClient()}
	s := &server{dag: dag, orchestrator: NewCascadeOrchestrator(dag, client, 0), callerKeys: testCallerKeys(t)}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/agent-cardvault",
		strings.NewReader(`{"reason":"signalloom-warden detection: sys_enter_openat /etc/passwd"}`)).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+sentinelKey)
	s.routes().ServeHTTP(httptest.NewRecorder(), req)
	if got := client.states["agent-cardvault"]; got != StateStunned {
		t.Fatalf("pod state = %q after the caller hung up: the stun rode the request context", got)
	}
}
