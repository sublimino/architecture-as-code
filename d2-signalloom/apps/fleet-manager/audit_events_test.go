package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func testAuditDAG(t *testing.T) (*DAG, *mockFleetClient) {
	t.Helper()
	agents := []Agent{
		{ID: "cardvault", State: StateRunning, Namespace: "default"},
		{ID: "agent-txn-pipeline", State: StateRunning, Namespace: "default", Dependencies: []string{"cardvault"}},
	}
	dag, err := BuildDAG(agents)
	if err != nil {
		t.Fatalf("BuildDAG failed: %v", err)
	}
	client := newMockClient()
	return dag, client
}

func TestAuditRingBuffer_AppendAndEviction(t *testing.T) {
	buf := NewAuditRingBuffer(3)

	for i := 1; i <= 5; i++ {
		buf.Append(AuditEvent{
			EventID:           fmt.Sprintf("evt-%03d", i),
			Timestamp:         time.Now().UTC().Format(time.RFC3339),
			ActionType:        "manual-stun",
			TargetAgentID:     fmt.Sprintf("agent-%d", i),
			AffectedAgents:    []string{fmt.Sprintf("agent-%d", i)},
			DurationMs:        int64(i * 10),
			RiskBefore:        100000.0,
			RiskAfter:         12400.0,
			RiskDelta:         -87600.0,
			Actor:             "admin",
			OperatorSignature: fmt.Sprintf("sig-%d", i),
		})
	}

	if count := buf.Count(); count != 3 {
		t.Fatalf("expected 3 events in buffer, got %d", count)
	}

	events := buf.List(10, "", "")
	if len(events) != 3 {
		t.Fatalf("expected 3 events from List, got %d", len(events))
	}

	// Newest first order
	if events[0].EventID != "evt-005" {
		t.Errorf("expected newest event to be evt-005, got %s", events[0].EventID)
	}
	if events[1].EventID != "evt-004" {
		t.Errorf("expected second event to be evt-004, got %s", events[1].EventID)
	}
	if events[2].EventID != "evt-003" {
		t.Errorf("expected third event to be evt-003, got %s", events[2].EventID)
	}

	// Verify all 13 schema fields on first event
	e := events[0]
	if e.EventID == "" || e.Timestamp == "" || e.ActionType == "" || e.TargetAgentID == "" ||
		len(e.AffectedAgents) == 0 || e.DurationMs == 0 || e.RiskBefore == 0 || e.RiskAfter == 0 ||
		e.RiskDelta == 0 || e.Actor == "" || e.OperatorSignature == "" {
		t.Errorf("one or more required audit fields are empty in event %+v", e)
	}
}

func TestAuditRingBuffer_Filtering(t *testing.T) {
	buf := NewAuditRingBuffer(10)

	buf.Append(AuditEvent{EventID: "e1", ActionType: "manual-stun", TargetAgentID: "cardvault", Actor: "admin"})
	buf.Append(AuditEvent{EventID: "e2", ActionType: "auto-policy-stun", TargetAgentID: "agent-llm-classifier", Actor: "policy-engine"})
	buf.Append(AuditEvent{EventID: "e3", ActionType: "manual-stun", TargetAgentID: "agent-txn-pipeline", Actor: "admin"})
	buf.Append(AuditEvent{EventID: "e4", ActionType: "recover", TargetAgentID: "fleet", Actor: "admin"})

	cardvaultEvents := buf.List(10, "cardvault", "")
	if len(cardvaultEvents) != 1 || cardvaultEvents[0].EventID != "e1" {
		t.Errorf("expected 1 cardvault event, got %d", len(cardvaultEvents))
	}

	stunEvents := buf.List(10, "", "manual-stun")
	if len(stunEvents) != 2 {
		t.Errorf("expected 2 manual-stun events, got %d", len(stunEvents))
	}

	limited := buf.List(2, "", "")
	if len(limited) != 2 {
		t.Errorf("expected 2 events when limit=2, got %d", len(limited))
	}
}

func TestAuditRingBuffer_SSEBroadcasting(t *testing.T) {
	buf := NewAuditRingBuffer(10)
	sub := buf.Subscribe()
	defer buf.Unsubscribe(sub)

	evt := AuditEvent{
		EventID:       "evt-broadcast-1",
		ActionType:    "auto-policy-stun",
		TargetAgentID: "cardvault",
		Actor:         "policy-engine",
	}
	buf.Append(evt)

	select {
	case received := <-sub:
		if received.EventID != "evt-broadcast-1" {
			t.Errorf("expected event evt-broadcast-1, got %s", received.EventID)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("timed out waiting for subscriber notification")
	}
}

func TestHandleAuditEvents_HTTPContract(t *testing.T) {
	dag, client := testAuditDAG(t)
	s := &server{
		dag:          dag,
		orchestrator: NewCascadeOrchestrator(dag, client, 0),
		auditBuffer:  NewAuditRingBuffer(10),
	}

	s.auditBuffer.Append(AuditEvent{
		EventID:       "evt-test-1",
		ActionType:    "manual-stun",
		TargetAgentID: "cardvault",
		Actor:         "admin",
	})
	s.auditBuffer.Append(AuditEvent{
		EventID:       "evt-test-2",
		ActionType:    "recover",
		TargetAgentID: "fleet",
		Actor:         "admin",
	})

	// 1. GET /api/v1/fleet/audit/events
	req := httptest.NewRequest(http.MethodGet, "/api/v1/fleet/audit/events", nil)
	rr := httptest.NewRecorder()
	s.handleAuditEvents(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d: %s", rr.Code, rr.Body.String())
	}

	var resp struct {
		Events []AuditEvent `json:"events"`
		Count  int          `json:"count"`
		Total  int          `json:"total"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	if resp.Count != 2 || resp.Total != 2 {
		t.Errorf("expected count=2, total=2, got count=%d, total=%d", resp.Count, resp.Total)
	}

	// 2. Filter by agent: ?agent=cardvault
	reqFilter := httptest.NewRequest(http.MethodGet, "/api/v1/fleet/audit/events?agent=cardvault", nil)
	rrFilter := httptest.NewRecorder()
	s.handleAuditEvents(rrFilter, reqFilter)

	if err := json.Unmarshal(rrFilter.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode filter response: %v", err)
	}
	if resp.Count != 1 || resp.Events[0].TargetAgentID != "cardvault" {
		t.Errorf("expected 1 cardvault event, got %d", resp.Count)
	}

	// 3. Method not allowed
	reqPost := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/audit/events", nil)
	rrPost := httptest.NewRecorder()
	s.handleAuditEvents(rrPost, reqPost)
	if rrPost.Code != http.StatusMethodNotAllowed {
		t.Errorf("expected 405 Method Not Allowed, got %d", rrPost.Code)
	}
	if allow := rrPost.Header().Get("Allow"); allow != "GET, HEAD" {
		t.Errorf("expected Allow: GET, HEAD, got %q", allow)
	}

	// 4. HEAD support
	reqHead := httptest.NewRequest(http.MethodHead, "/api/v1/fleet/audit/events", nil)
	rrHead := httptest.NewRecorder()
	s.handleAuditEvents(rrHead, reqHead)
	if rrHead.Code != http.StatusOK {
		t.Errorf("expected 200 OK on HEAD, got %d", rrHead.Code)
	}
	if rrHead.Body.Len() != 0 {
		t.Errorf("expected empty body on HEAD, got %d bytes", rrHead.Body.Len())
	}

	// 5. Stream method not allowed
	reqStreamPost := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/audit/stream", nil)
	rrStreamPost := httptest.NewRecorder()
	s.handleAuditStream(rrStreamPost, reqStreamPost)
	if rrStreamPost.Code != http.StatusMethodNotAllowed {
		t.Errorf("expected 405 Method Not Allowed on stream POST, got %d", rrStreamPost.Code)
	}
	if allow := rrStreamPost.Header().Get("Allow"); allow != "GET, HEAD" {
		t.Errorf("expected Allow: GET, HEAD on stream, got %q", allow)
	}

	// 6. Stream HEAD support
	reqStreamHead := httptest.NewRequest(http.MethodHead, "/api/v1/fleet/audit/stream", nil)
	rrStreamHead := httptest.NewRecorder()
	s.handleAuditStream(rrStreamHead, reqStreamHead)
	if rrStreamHead.Code != http.StatusOK {
		t.Errorf("expected 200 OK on stream HEAD, got %d", rrStreamHead.Code)
	}
	if ct := rrStreamHead.Header().Get("Content-Type"); ct != "text/event-stream" {
		t.Errorf("expected Content-Type text/event-stream, got %q", ct)
	}
	if rrStreamHead.Body.Len() != 0 {
		t.Errorf("expected empty body on stream HEAD, got %d bytes", rrStreamHead.Body.Len())
	}
}

func TestHandleAuditStream_SSEStreaming(t *testing.T) {
	dag, client := testAuditDAG(t)
	s := &server{
		dag:          dag,
		orchestrator: NewCascadeOrchestrator(dag, client, 0),
		auditBuffer:  NewAuditRingBuffer(10),
	}

	ts := httptest.NewServer(s.routes())
	defer ts.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ts.URL+"/api/v1/fleet/audit/stream", nil)
	if err != nil {
		t.Fatalf("failed to create request: %v", err)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("failed to open SSE stream: %v", err)
	}
	defer resp.Body.Close()

	if resp.Header.Get("Content-Type") != "text/event-stream" {
		t.Errorf("expected Content-Type text/event-stream, got %q", resp.Header.Get("Content-Type"))
	}

	reader := bufio.NewReader(resp.Body)
	// Read initial comment: ": connected\n\n"
	line, err := reader.ReadString(10)
	if err != nil {
		t.Fatalf("failed to read initial comment: %v", err)
	}
	if !strings.Contains(line, ": connected") {
		t.Errorf("expected initial comment : connected, got %q", line)
	}

	// Emit an audit event to buffer
	s.auditBuffer.Append(AuditEvent{
		EventID:        "evt-stream-1",
		ActionType:     "auto-policy-stun",
		PolicyName:     "High-Risk Carried GBP Auto-Containment",
		TargetAgentID:  "cardvault",
		AffectedAgents: []string{"cardvault", "agent-txn-pipeline"},
		DurationMs:     42,
		RiskBefore:     847000.0,
		RiskAfter:      12400.0,
		RiskDelta:      -834600.0,
		Actor:          "policy-engine",
	})

	// Read lines until event: audit and data payload are found
	foundEvent := false
	foundData := false
	for i := 0; i < 10; i++ {
		line, err := reader.ReadString(10)
		if err != nil {
			break
		}
		if strings.HasPrefix(line, "event: audit") {
			foundEvent = true
		}
		if strings.HasPrefix(line, "data: ") && strings.Contains(line, "evt-stream-1") {
			foundData = true
			break
		}
	}
	if !foundEvent {
		t.Error("expected to receive event: audit")
	}
	if !foundData {
		t.Error("expected to receive data containing evt-stream-1")
	}
}

func TestPolicyEngine_AuditEmission(t *testing.T) {
	dag, client := testAuditDAG(t)
	orch := NewCascadeOrchestrator(dag, client, 0)
	auditBuf := NewAuditRingBuffer(10)

	engine := NewPolicyEngine(dag, orch, nil)
	engine.SetAuditBuffer(auditBuf)

	input := PolicyEvaluationInput{
		CarriedGBP: 650000.0,
		DryRun:     false,
	}

	res, err := engine.Evaluate(context.Background(), input)
	if err != nil {
		t.Fatalf("Evaluate failed: %v", err)
	}
	if !res.Triggered {
		t.Fatal("expected policy to trigger")
	}

	events := auditBuf.List(10, "", "")
	if len(events) == 0 {
		t.Fatal("expected at least 1 audit event emitted")
	}

	evt := events[0]
	if evt.ActionType != "auto-policy-stun" {
		t.Errorf("expected actionType auto-policy-stun, got %s", evt.ActionType)
	}
	if evt.Actor != "policy-engine" {
		t.Errorf("expected actor policy-engine, got %s", evt.Actor)
	}
	if evt.TargetAgentID != "cardvault" {
		t.Errorf("expected targetAgentId cardvault, got %s", evt.TargetAgentID)
	}
	if evt.RiskBefore != 650000.0 {
		t.Errorf("expected riskBefore 650000.0, got %f", evt.RiskBefore)
	}
}

func TestHandleStunAndRecover_AuditEmission(t *testing.T) {
	dag, client := testAuditDAG(t)
	s := &server{
		dag:          dag,
		orchestrator: NewCascadeOrchestrator(dag, client, 0),
		auditBuffer:  NewAuditRingBuffer(10),
	}

	// 1. Manual Stun
	stunReq := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/cardvault", strings.NewReader(`{"reason": "testing manual stun audit"}`))
	stunReq.Header.Set("Content-Type", "application/json")
	stunReq.Header.Set("X-User-Role", "admin")
	stunRR := httptest.NewRecorder()
	s.handleStun(stunRR, stunReq)

	if stunRR.Code != http.StatusOK {
		t.Fatalf("expected 200 OK on stun, got %d: %s", stunRR.Code, stunRR.Body.String())
	}

	events := s.auditBuffer.List(10, "", "manual-stun")
	if len(events) == 0 {
		t.Fatal("expected manual-stun audit event emitted")
	}
	if events[0].TargetAgentID != "cardvault" {
		t.Errorf("expected targetAgentId cardvault, got %s", events[0].TargetAgentID)
	}

	// 2. Recover
	recoverReq := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/recover", bytes.NewBufferString(`{"agent_ids": ["cardvault"], "mode": "replace"}`))
	recoverReq.Header.Set("Content-Type", "application/json")
	recoverReq.Header.Set("X-User-Role", "admin")
	recoverRR := httptest.NewRecorder()
	s.handleRecover(recoverRR, recoverReq)

	if recoverRR.Code != http.StatusOK {
		t.Fatalf("expected 200 OK on recover, got %d: %s", recoverRR.Code, recoverRR.Body.String())
	}

	recoverEvents := s.auditBuffer.List(10, "", "recover")
	if len(recoverEvents) == 0 {
		t.Fatal("expected recover audit event emitted")
	}
	if recoverEvents[0].ActionType != "recover" {
		t.Errorf("expected actionType recover, got %s", recoverEvents[0].ActionType)
	}
}
