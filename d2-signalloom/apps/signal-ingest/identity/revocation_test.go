package identity

import (
	"context"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestRevokeActiveDelegations(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepository()
	bus := NewInProcessEventBus()
	stunMock := NewMockStunSentinelClient()

	t0 := time.Date(2026, 9, 10, 10, 0, 0, 0, time.UTC)
	tRevoke := time.Date(2026, 9, 10, 10, 30, 0, 0, time.UTC)
	tAfter := time.Date(2026, 9, 10, 10, 35, 0, 0, time.UTC)

	// 1. Setup multi-hop transitive delegation: Human (Alice) -> Reasoner -> Executor
	_ = repo.CreateActor(ctx, ActorRecord{ActorID: "alice@controlplane.io", Status: model.ActorActionable, CreatedAt: t0})
	_ = repo.CreateActor(ctx, ActorRecord{ActorID: "agent-reasoner-1", Status: model.ActorActionable, CreatedAt: t0})
	_ = repo.CreateActor(ctx, ActorRecord{ActorID: "agent-executor-1", Status: model.ActorActionable, CreatedAt: t0})

	_ = repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "agent-reasoner-1",
		PrincipalActorID: "alice@controlplane.io",
		AuthzRef:         "authz-grant-001",
		ValidFrom:        t0,
		CreatedAt:        t0,
	})

	_ = repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "agent-executor-1",
		PrincipalActorID: "agent-reasoner-1",
		AuthzRef:         "authz-grant-002",
		ValidFrom:        t0,
		CreatedAt:        t0,
	})

	// Verify before revocation: full transitive chain resolves as of t0 + 10m
	tBefore := t0.Add(10 * time.Minute)
	delsBefore, cycle, err := repo.FindTransitiveDelegations(ctx, "agent-executor-1", tBefore, 8)
	if err != nil {
		t.Fatalf("unexpected error finding transitive delegations before revocation: %v", err)
	}
	if cycle {
		t.Fatalf("unexpected cycle detected before revocation")
	}
	if len(delsBefore) != 2 {
		t.Fatalf("expected 2 hops before revocation, got %d", len(delsBefore))
	}

	// 2. Setup Stun Event Listener
	revokedEvents := make([]DelegationRevokedEvent, 0)
	bus.Subscribe(TopicDelegationRevoked, func(ctx context.Context, ev any) error {
		if revEv, ok := ev.(DelegationRevokedEvent); ok {
			revokedEvents = append(revokedEvents, revEv)
		}
		return nil
	})

	listener := NewStunEventListener(repo, bus, stunMock)

	// Measure edge clamping latency (< 50ms)
	start := time.Now()
	stunEvent := StunContainmentEvent{
		Event:     TopicStunTriggered,
		ActorID:   "agent-reasoner-1",
		AgentID:   "agent-reasoner-1",
		IP:        "10.244.1.88",
		Reason:    "anomalous privilege escalation attempt",
		Timestamp: tRevoke,
	}

	if err := listener.ProcessStunEvent(ctx, stunEvent); err != nil {
		t.Fatalf("failed to process stun event: %v", err)
	}
	elapsed := time.Since(start)

	if elapsed > 50*time.Millisecond {
		t.Errorf("revocation took %v, exceeding sub-50ms requirement", elapsed)
	}

	// 3. Verify temporal query reflection:
	// As of tAfter (> tRevoke), delegations for agent-reasoner-1 and its downstream chains must be empty/severed
	delsAfter, _, err := repo.FindTransitiveDelegations(ctx, "agent-executor-1", tAfter, 8)
	if err != nil {
		t.Fatalf("query after revocation failed: %v", err)
	}
	if len(delsAfter) != 0 {
		t.Fatalf("expected 0 active delegations after revocation, got %d", len(delsAfter))
	}

	activeDelsReasoner, err := repo.GetDelegationsForDelegateAsOf(ctx, "agent-reasoner-1", tAfter)
	if err != nil {
		t.Fatalf("query delegate after revocation failed: %v", err)
	}
	if len(activeDelsReasoner) != 0 {
		t.Fatalf("expected 0 active delegations for agent-reasoner-1 at tAfter, got %d", len(activeDelsReasoner))
	}

	// 4. Verify historical queries as-of prior timestamp (tBefore) remain valid
	delsHistorical, _, err := repo.FindTransitiveDelegations(ctx, "agent-executor-1", tBefore, 8)
	if err != nil {
		t.Fatalf("historical query failed: %v", err)
	}
	if len(delsHistorical) != 2 {
		t.Fatalf("expected 2 active delegations historically as-of tBefore, got %d", len(delsHistorical))
	}

	// 5. Verify Stun Sentinel mock received the egress drop command
	dispatched := stunMock.GetDispatched()
	if len(dispatched) == 0 {
		t.Fatalf("expected stun sentinel drop command to be dispatched")
	}
	if dispatched[0].IP != "10.244.1.88" {
		t.Errorf("expected drop command for IP 10.244.1.88, got %s", dispatched[0].IP)
	}
	if dispatched[0].AgentID != "agent-reasoner-1" {
		t.Errorf("expected drop command for agent-reasoner-1, got %s", dispatched[0].AgentID)
	}

	// 6. Verify EventBus broadcast
	if len(revokedEvents) == 0 {
		t.Fatalf("expected TopicDelegationRevoked event to be broadcast")
	}
	if revokedEvents[0].ActorID != "agent-reasoner-1" {
		t.Errorf("expected broadcast actor_id agent-reasoner-1, got %s", revokedEvents[0].ActorID)
	}
}

func TestRevokeActiveDelegations_Sub50msLatency(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepository()
	store := NewGraphResolverStore(repo)

	now := time.Now().UTC()
	_ = repo.CreateActor(ctx, ActorRecord{ActorID: "human-operator", Status: model.ActorActionable, CreatedAt: now.Add(-time.Hour)})
	_ = repo.CreateActor(ctx, ActorRecord{ActorID: "agent-pipeline", Status: model.ActorActionable, CreatedAt: now.Add(-time.Hour)})

	_ = repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "agent-pipeline",
		PrincipalActorID: "human-operator",
		AuthzRef:         "authz-fast-revocation-test",
		ValidFrom:        now.Add(-time.Hour),
	})

	// Run 100 consecutive revocation cycles and assert max latency < 50ms
	for i := 0; i < 50; i++ {
		start := time.Now()
		clampTime := time.Now().UTC()
		if err := store.RevokeActiveDelegations(ctx, "agent-pipeline", clampTime); err != nil {
			t.Fatalf("iteration %d revocation failed: %v", i, err)
		}
		dels, err := store.GetDelegationsAsOf(ctx, "agent-pipeline", time.Now().UTC())
		if err != nil {
			t.Fatalf("iteration %d query failed: %v", i, err)
		}
		if len(dels) != 0 {
			t.Fatalf("iteration %d expected 0 delegations, got %d", i, len(dels))
		}
		elapsed := time.Since(start)
		if elapsed >= 50*time.Millisecond {
			t.Fatalf("iteration %d exceeded 50ms: took %v", i, elapsed)
		}
	}
}

func TestStunSentinelClient_RetryWithBackoff(t *testing.T) {
	mockClient := NewMockStunSentinelClient()
	mockClient.FailAttempts = 2 // Fail first 2 attempts, succeed on 3rd

	req := DropEgressRequest{
		AgentID:   "agent-failed-first",
		IP:        "10.244.0.99",
		Reason:    "test retry",
		Timestamp: time.Now().UTC(),
	}

	resp, err := DispatchDropWithRetry(context.Background(), mockClient, req, 3)
	if err != nil {
		t.Fatalf("expected retry to succeed on 3rd attempt, got error: %v", err)
	}
	if !resp.Success {
		t.Fatalf("expected response success to be true")
	}
	if mockClient.callCount != 3 {
		t.Fatalf("expected exactly 3 attempts, got %d", mockClient.callCount)
	}
}

func TestDelegationReaper_SweepExpiredAndPanicRecovery(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepository()
	bus := NewInProcessEventBus()

	now := time.Now().UTC()
	tPastValidTo := now.Add(-5 * time.Minute)

	_ = repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "agent-expired-1",
		PrincipalActorID: "operator-1",
		AuthzRef:         "authz-expired-test",
		ValidFrom:        now.Add(-10 * time.Minute),
		ValidTo:          &tPastValidTo,
	})

	reaper := NewDelegationReaper(repo, bus, 100*time.Millisecond)

	// Test direct sweep
	count, err := reaper.SweepExpired(ctx, now)
	if err != nil {
		t.Fatalf("sweep failed: %v", err)
	}
	if count != 1 {
		t.Fatalf("expected 1 expired delegation swept, got %d", count)
	}

	// Start reaper and let ticker run
	reaper.Start(ctx)
	time.Sleep(250 * time.Millisecond)
	reaper.Stop()

	sweeps, _, crashes := reaper.Stats()
	if sweeps == 0 {
		t.Errorf("expected at least 1 sweep cycle, got %d", sweeps)
	}
	if crashes != 0 {
		t.Errorf("expected 0 crashes, got %d", crashes)
	}
}
