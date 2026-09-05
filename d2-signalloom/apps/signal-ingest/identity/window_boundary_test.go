package identity

import (
	"context"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestHalfOpenWindowBoundary_AliasDirect(t *testing.T) {
	tFrom := time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)
	tTo := time.Date(2026, 3, 1, 13, 0, 0, 0, time.UTC)

	aliasClosed := AliasRecord{
		ActorID:      "actor-test-1",
		AliasType:    "session",
		AliasValue:   "session-abc",
		EdgeFidelity: model.FidelityStrong,
		ValidFrom:    tFrom,
		ValidTo:      &tTo, // [12:00, 13:00)
	}

	aliasOpen := AliasRecord{
		ActorID:      "actor-test-1",
		AliasType:    "spiffe",
		AliasValue:   "spiffe://cluster.local/ns/test/sa/1",
		EdgeFidelity: model.FidelityDefinitive,
		ValidFrom:    tFrom,
		ValidTo:      nil, // [12:00, infinity)
	}

	tests := []struct {
		name      string
		alias     AliasRecord
		queryTime time.Time
		wantValid bool
	}{
		{
			name:      "1ns before valid_from (closed)",
			alias:     aliasClosed,
			queryTime: tFrom.Add(-1 * time.Nanosecond),
			wantValid: false,
		},
		{
			name:      "exact valid_from (closed) - inclusive boundary",
			alias:     aliasClosed,
			queryTime: tFrom,
			wantValid: true,
		},
		{
			name:      "1ns after valid_from (closed)",
			alias:     aliasClosed,
			queryTime: tFrom.Add(1 * time.Nanosecond),
			wantValid: true,
		},
		{
			name:      "mid-window (closed)",
			alias:     aliasClosed,
			queryTime: tFrom.Add(30 * time.Minute),
			wantValid: true,
		},
		{
			name:      "1ns before valid_to (closed)",
			alias:     aliasClosed,
			queryTime: tTo.Add(-1 * time.Nanosecond),
			wantValid: true,
		},
		{
			name:      "exact valid_to (closed) - exclusive boundary",
			alias:     aliasClosed,
			queryTime: tTo,
			wantValid: false,
		},
		{
			name:      "1ns after valid_to (closed)",
			alias:     aliasClosed,
			queryTime: tTo.Add(1 * time.Nanosecond),
			wantValid: false,
		},
		{
			name:      "exact valid_from (open) - inclusive",
			alias:     aliasOpen,
			queryTime: tFrom,
			wantValid: true,
		},
		{
			name:      "far future (open)",
			alias:     aliasOpen,
			queryTime: tFrom.Add(365 * 24 * time.Hour),
			wantValid: true,
		},
		{
			name:      "1ns before valid_from (open)",
			alias:     aliasOpen,
			queryTime: tFrom.Add(-1 * time.Nanosecond),
			wantValid: false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := tc.alias.IsActiveAt(tc.queryTime)
			if got != tc.wantValid {
				t.Errorf("IsActiveAt(%v) = %v, want %v", tc.queryTime, got, tc.wantValid)
			}
		})
	}
}

func TestHalfOpenWindowBoundary_TransitionUnambiguity(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepository()

	actor := ActorRecord{
		ActorID:   "actor-transition-alice",
		Status:    model.ActorActionable,
		CreatedAt: TimeT0,
	}
	if err := repo.CreateActor(ctx, actor); err != nil {
		t.Fatalf("CreateActor: %v", err)
	}

	// Window 1: [T0, T2) -> alice-v1
	alias1 := AliasRecord{
		ActorID:      actor.ActorID,
		AliasType:    "email",
		AliasValue:   "alice-v1@corp.internal",
		EdgeFidelity: model.FidelityDefinitive,
		ValidFrom:    TimeT0,
		ValidTo:      &TimeT2,
	}
	// Window 2: [T2, nil) -> alice-v2
	alias2 := AliasRecord{
		ActorID:      actor.ActorID,
		AliasType:    "email",
		AliasValue:   "alice-v2@corp.internal",
		EdgeFidelity: model.FidelityDefinitive,
		ValidFrom:    TimeT2,
		ValidTo:      nil,
	}

	if err := repo.AddAlias(ctx, alias1); err != nil {
		t.Fatalf("AddAlias 1: %v", err)
	}
	if err := repo.AddAlias(ctx, alias2); err != nil {
		t.Fatalf("AddAlias 2: %v", err)
	}

	// 1. At 1ns before T2: alice-v1 is active, alice-v2 is inactive
	tBefore := TimeT2.Add(-1 * time.Nanosecond)
	resBefore1, _ := repo.FindAliasesAsOf(ctx, "alice-v1@corp.internal", tBefore)
	resBefore2, _ := repo.FindAliasesAsOf(ctx, "alice-v2@corp.internal", tBefore)
	if len(resBefore1) != 1 {
		t.Errorf("expected alice-v1 to be active at %v", tBefore)
	}
	if len(resBefore2) != 0 {
		t.Errorf("expected alice-v2 to be inactive at %v", tBefore)
	}

	// 2. Exactly at transition boundary T2: alice-v1 is inactive (expired), alice-v2 is active
	resT2_1, _ := repo.FindAliasesAsOf(ctx, "alice-v1@corp.internal", TimeT2)
	resT2_2, _ := repo.FindAliasesAsOf(ctx, "alice-v2@corp.internal", TimeT2)
	if len(resT2_1) != 0 {
		t.Errorf("expected alice-v1 to be inactive (expired) at exact boundary %v", TimeT2)
	}
	if len(resT2_2) != 1 {
		t.Errorf("expected alice-v2 to be active at exact boundary %v", TimeT2)
	}

	// 3. Aliases for actor at T2 returns exactly 1 alias (no overlap)
	actorAliases, err := repo.GetAliasesForActorAsOf(ctx, actor.ActorID, TimeT2)
	if err != nil {
		t.Fatalf("GetAliasesForActorAsOf: %v", err)
	}
	if len(actorAliases) != 1 {
		t.Fatalf("expected exactly 1 active alias at boundary %v, got %d", TimeT2, len(actorAliases))
	}
	if actorAliases[0].AliasValue != "alice-v2@corp.internal" {
		t.Errorf("expected alice-v2 at boundary, got %s", actorAliases[0].AliasValue)
	}
}
