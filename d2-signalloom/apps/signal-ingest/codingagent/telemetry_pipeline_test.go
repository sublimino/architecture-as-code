// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package codingagent_test

import (
	"context"
	"errors"
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/codingagent"
)

func makeTestEvent(sessionID, taskID string, elapsed, step uint64, ts string) *codingagent.CodingAgentTelemetry {
	return &codingagent.CodingAgentTelemetry{
		SchemaVersion: "1.0.0",
		Harness:       codingagent.HarnessClaude,
		SessionID:     sessionID,
		Timestamp:     ts,
		Process: codingagent.ProcessInfo{
			PID:      1234,
			PPID:     1,
			Comm:     "claude",
			RSSBytes: 104857600,
			CPUTicks: 450,
		},
		Kanban: codingagent.KanbanInfo{
			TaskID:    taskID,
			Shortcode: "SLCD",
			Role:      "implementation",
			ElapsedS:  elapsed,
		},
		Metrics: codingagent.MetricsInfo{
			StepCount: step,
			TokensIn:  100000,
			TokensOut: 2500,
			ToolCounts: codingagent.ToolCounts{
				ViewFile:    4,
				WriteToFile: 1,
				RunCommand:  2,
			},
		},
		Network: codingagent.NetworkInfo{
			InferenceEndpoint: "api.anthropic.com",
			EgressBytes:       35000,
		},
	}
}

// TestTelemetryStore_DeduplicationKeying proves deduplication keys on session_id and
// monotonic sequence/anchor, NOT wall-clock timestamp alone.
func TestTelemetryStore_DeduplicationKeying(t *testing.T) {
	store := codingagent.NewMemoryStore()
	ctx := context.Background()
	tenantID := "tenant-alpha"
	subject := "spiffe://cluster.local/ns/prod/sa/sensor"

	sessionID := "7b3835c06f46f2ddca90bc84566f21bed867aca811958afb080968a302bbd97e"
	nowStr := time.Now().UTC().Format(time.RFC3339)

	ev1 := makeTestEvent(sessionID, "TASK-1", 10, 1, nowStr)

	// Ingest first time
	res1, err := store.Ingest(ctx, tenantID, subject, ev1)
	if err != nil {
		t.Fatalf("first ingest failed: %v", err)
	}
	if res1.Duplicate {
		t.Errorf("first ingest was incorrectly flagged as duplicate")
	}

	// Ingest identical second time (same session_id, same task, same elapsed_s, same step_count)
	res2, err := store.Ingest(ctx, tenantID, subject, ev1)
	if err != nil {
		t.Fatalf("second ingest failed: %v", err)
	}
	if !res2.Duplicate {
		t.Errorf("second identical ingest was NOT flagged as duplicate")
	}

	// Ingest event with same session_id and same wall-clock timestamp, but advanced step_count (next progress step)
	ev2 := makeTestEvent(sessionID, "TASK-1", 15, 2, nowStr)
	res3, err := store.Ingest(ctx, tenantID, subject, ev2)
	if err != nil {
		t.Fatalf("third ingest failed: %v", err)
	}
	if res3.Duplicate {
		t.Errorf("third ingest with advanced step_count was incorrectly flagged as duplicate (wall-clock collision)")
	}

	records, err := store.Query(ctx, tenantID, codingagent.AggregateFilter{})
	if err != nil {
		t.Fatalf("query failed: %v", err)
	}
	if len(records) != 2 {
		t.Fatalf("expected 2 distinct records in store, got %d", len(records))
	}
}

// TestTelemetryStore_ClockSkewCalculation asserts server-observed clock skew is computed
// and stored alongside the record without modifying the original event timestamp.
func TestTelemetryStore_ClockSkewCalculation(t *testing.T) {
	store := codingagent.NewMemoryStore()
	ctx := context.Background()
	tenantID := "tenant-skew"
	subject := "spiffe://cluster.local/ns/prod/sa/sensor"

	sessionID := "7b3835c06f46f2ddca90bc84566f21bed867aca811958afb080968a302bbd97e"

	// Client timestamp deliberately set 5 seconds in the past (5000ms clock skew)
	clientPastTime := time.Now().UTC().Add(-5 * time.Second)
	clientPastStr := clientPastTime.Format(time.RFC3339Nano)

	ev := makeTestEvent(sessionID, "TASK-1", 10, 1, clientPastStr)

	res, err := store.Ingest(ctx, tenantID, subject, ev)
	if err != nil {
		t.Fatalf("ingest failed: %v", err)
	}

	// Clock skew should be approximately +5000ms
	if res.ClockSkewMs < 4500 || res.ClockSkewMs > 5500 {
		t.Errorf("expected clock skew ~5000ms, got %.2f ms", res.ClockSkewMs)
	}

	records, err := store.Query(ctx, tenantID, codingagent.AggregateFilter{})
	if err != nil {
		t.Fatalf("query failed: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("expected 1 record, got %d", len(records))
	}

	// Verify original timestamp was NOT modified/corrected
	if records[0].Event.Timestamp != clientPastStr {
		t.Errorf("original timestamp was silently altered: got %q, want %q",
			records[0].Event.Timestamp, clientPastStr)
	}
	// Verify server ObservedAt is present and newer than client timestamp
	if records[0].ObservedAt.Before(clientPastTime) {
		t.Errorf("observed_at is before client timestamp")
	}
}

// TestTelemetryStore_KAnonymityGroupSize asserts aggregates are refused for small groups (k < 5).
func TestTelemetryStore_KAnonymityGroupSize(t *testing.T) {
	store := codingagent.NewMemoryStore()
	ctx := context.Background()
	tenantID := "tenant-k-anon"
	subject := "spiffe://cluster.local/ns/prod/sa/sensor"

	now := time.Now().UTC()

	// Ingest 4 sessions (< k=5)
	for i := 1; i <= 4; i++ {
		sess := fmt.Sprintf("%064x", i)
		ev := makeTestEvent(sess, fmt.Sprintf("TASK-%d", i), 10, 1, now.Format(time.RFC3339))
		if _, err := store.Ingest(ctx, tenantID, subject, ev); err != nil {
			t.Fatalf("ingest %d failed: %v", i, err)
		}
	}

	// Aggregate with 4 sessions -> must return ErrGroupSizeBelowAnonymityFloor
	_, err := store.Aggregate(ctx, tenantID, codingagent.AggregateFilter{})
	if err == nil {
		t.Fatal("expected aggregate to fail with ErrGroupSizeBelowAnonymityFloor for cohort of 4")
	}
	if !errors.Is(err, codingagent.ErrGroupSizeBelowAnonymityFloor) {
		t.Fatalf("expected ErrGroupSizeBelowAnonymityFloor, got: %v", err)
	}

	// Add 5th session to meet k=5
	sess5 := fmt.Sprintf("%064x", 5)
	ev5 := makeTestEvent(sess5, "TASK-5", 10, 1, now.Format(time.RFC3339))
	if _, err := store.Ingest(ctx, tenantID, subject, ev5); err != nil {
		t.Fatalf("ingest 5 failed: %v", err)
	}

	// Aggregate with 5 sessions -> must succeed
	agg, err := store.Aggregate(ctx, tenantID, codingagent.AggregateFilter{})
	if err != nil {
		t.Fatalf("expected aggregate to succeed for cohort of 5, got: %v", err)
	}
	if agg.GroupSize != 5 {
		t.Errorf("expected group_size == 5, got %d", agg.GroupSize)
	}
	if agg.TotalEvents != 5 {
		t.Errorf("expected total_events == 5, got %d", agg.TotalEvents)
	}
}

// TestTelemetryStore_CrossWorkstationOrderingUncertainty tests skew-bounded uncertainty.
func TestTelemetryStore_CrossWorkstationOrderingUncertainty(t *testing.T) {
	store := codingagent.NewMemoryStore()
	ctx := context.Background()
	tenantID := "tenant-order"
	subject := "spiffe://cluster.local/ns/prod/sa/sensor"

	baseTime := time.Now().UTC()

	// Workstation 1: skew = +600ms
	sess1 := fmt.Sprintf("%064x", 11)
	ev1 := makeTestEvent(sess1, "TASK-1", 5, 1, baseTime.Add(-600*time.Millisecond).Format(time.RFC3339Nano))
	res1, _ := store.Ingest(ctx, tenantID, subject, ev1)

	// Workstation 2: skew = -400ms, event timestamp is 300ms after Workstation 1
	sess2 := fmt.Sprintf("%064x", 22)
	ev2 := makeTestEvent(sess2, "TASK-2", 5, 1, baseTime.Add(-300*time.Millisecond).Format(time.RFC3339Nano))
	res2, _ := store.Ingest(ctx, tenantID, subject, ev2)

	rec1 := &codingagent.StoredRecord{Event: *ev1, ClockSkewMs: res1.ClockSkewMs}
	rec2 := &codingagent.StoredRecord{Event: *ev2, ClockSkewMs: res2.ClockSkewMs}

	// Ordering between 1 and 2 (delta 300ms vs maxSkew 600ms) -> UNCERTAIN
	ord12, err := store.ResolveOrdering(ctx, tenantID, rec1, rec2)
	if err != nil {
		t.Fatalf("resolve ordering failed: %v", err)
	}
	if ord12.Verdict != codingagent.OrderingUncertain {
		t.Errorf("expected uncertain verdict, got %s", ord12.Verdict)
	}
	if ord12.Confidence != codingagent.ConfidenceSkewBounded {
		t.Errorf("expected skew_bounded confidence, got %s", ord12.Confidence)
	}
	if ord12.SkewBoundMs < 500 {
		t.Errorf("expected skew bound >= 500ms, got %.2f", ord12.SkewBoundMs)
	}

	// Workstation 3: event timestamp is 10 seconds after Workstation 1 (delta 10000ms >> maxSkew 600ms)
	sess3 := fmt.Sprintf("%064x", 33)
	ev3 := makeTestEvent(sess3, "TASK-3", 5, 1, baseTime.Add(10*time.Second).Format(time.RFC3339Nano))
	res3, _ := store.Ingest(ctx, tenantID, subject, ev3)
	rec3 := &codingagent.StoredRecord{Event: *ev3, ClockSkewMs: res3.ClockSkewMs}

	// Ordering between 1 and 3 -> DEFINITE
	ord13, err := store.ResolveOrdering(ctx, tenantID, rec1, rec3)
	if err != nil {
		t.Fatalf("resolve ordering failed: %v", err)
	}
	if ord13.Verdict != codingagent.OrderingDefinite {
		t.Errorf("expected definite verdict, got %s", ord13.Verdict)
	}
	if ord13.Confidence != codingagent.ConfidenceSkewExceeded {
		t.Errorf("expected skew_exceeded confidence, got %s", ord13.Confidence)
	}
	if math.Abs(ord13.TimeDeltaMs-10600) > 100 {
		t.Errorf("expected time delta ~10600ms, got %.2f", ord13.TimeDeltaMs)
	}
}
