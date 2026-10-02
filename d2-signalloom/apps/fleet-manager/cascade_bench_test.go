package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"testing"
)

// Cascade wall-time benchmarks for SLER-P1-5.
//
// The mission's out-of-scope rule forbids "claiming a latency figure not
// measured at the stated fleet size", so every benchmark here names its fleet
// size in the benchmark name and builds that fleet explicitly. A figure with no
// fleet size attached is not a measurement, it is a number.
//
// This file deliberately uses only the pre-existing orchestrator API
// (NewCascadeOrchestrator / Stun / Recover), so it compiles and runs unchanged
// against both the pre-fix and post-fix cascade. That is what makes the
// before/after comparison in docs/signalloom/sler-p1-5-proof.md a comparison of
// the same measurement rather than of two different ones.
//
// stepDelay is 0 throughout. The production default is 200ms per agent purely
// for visual effect in the demo, and it would swamp the orchestration cost this
// benchmark exists to measure by three orders of magnitude.

// quietLogs silences the orchestrator's per-agent slog lines for the duration
// of a benchmark. The cascade emits one INFO line per target; writing 256 of
// them per iteration into the test harness's captured pipe measures the pipe,
// not the orchestrator. Applied identically to the pre-fix and post-fix runs,
// so the before/after comparison is unaffected by it.
func quietLogs(b *testing.B) {
	b.Helper()
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(io.Discard, nil)))
	b.Cleanup(func() { slog.SetDefault(prev) })
}

// benchFleetDAG builds a star-shaped fleet of exactly n agents: one root that
// every other agent depends on. Stunning the root therefore cascades to all n.
func benchFleetDAG(tb testing.TB, n int) *DAG {
	tb.Helper()
	if n < 1 {
		tb.Fatalf("fleet size must be >= 1, got %d", n)
	}

	agents := make([]Agent, 0, n)
	agents = append(agents, Agent{
		ID:        "agent-root",
		Type:      "data-vault",
		Namespace: "fe-signalloom-agents",
		State:     StateRunning,
	})
	for i := 1; i < n; i++ {
		agents = append(agents, Agent{
			ID:           fmt.Sprintf("agent-%03d", i),
			Type:         "service",
			Namespace:    "fe-signalloom-agents",
			State:        StateRunning,
			Dependencies: []string{"agent-root"},
		})
	}

	dag, err := BuildDAG(agents)
	if err != nil {
		tb.Fatalf("build bench DAG of size %d: %v", n, err)
	}
	return dag
}

func benchmarkStunAtFleetSize(b *testing.B, n int) {
	quietLogs(b)
	dag := benchFleetDAG(b, n)
	orch := NewCascadeOrchestrator(dag, newMockClient(), 0)
	ctx := context.Background()

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := orch.Stun(ctx, "agent-root", ""); err != nil {
			b.Fatalf("stun: %v", err)
		}
	}
}

// BenchmarkStunCascade_Fleet5 measures the demo fleet size shipped in
// fleet.yaml (5 agents).
func BenchmarkStunCascade_Fleet5(b *testing.B) { benchmarkStunAtFleetSize(b, 5) }

// BenchmarkStunCascade_Fleet64 measures a scale point an order of magnitude
// above the demo fleet, so a per-target regression has room to express itself.
func BenchmarkStunCascade_Fleet64(b *testing.B) { benchmarkStunAtFleetSize(b, 64) }

// BenchmarkStunCascade_Fleet256 is the largest fleet size measured for this
// mission. Any per-target cost added by the honesty fix is most visible here.
func BenchmarkStunCascade_Fleet256(b *testing.B) { benchmarkStunAtFleetSize(b, 256) }

func benchmarkRecoverAtFleetSize(b *testing.B, n int) {
	quietLogs(b)
	dag := benchFleetDAG(b, n)
	orch := NewCascadeOrchestrator(dag, newMockClient(), 0)
	ctx := context.Background()

	ids := make([]string, 0, n)
	for _, a := range dag.AllAgents() {
		ids = append(ids, a.ID)
	}

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := orch.Recover(ctx, ids); err != nil {
			b.Fatalf("recover: %v", err)
		}
	}
}

// BenchmarkRecoverCascade_Fleet64 covers the mirror-image operation, which this
// card also changes.
func BenchmarkRecoverCascade_Fleet64(b *testing.B) { benchmarkRecoverAtFleetSize(b, 64) }
