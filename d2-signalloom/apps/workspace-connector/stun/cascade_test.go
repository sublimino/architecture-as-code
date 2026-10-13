package stun

import (
	"context"
	"testing"
	"time"
)

func TestMemoryStunExecutor_ExecuteStun(t *testing.T) {
	executor := NewMemoryStunExecutor()
	ctx := context.Background()

	req := StunRequest{
		AgentID:             "spiffe://osramp.local/ns/agents/sa/rogue-analyst",
		ServiceAccountEmail: "agent-rogue-analyst@corp.internal",
		Reason:              "Anomalous file access volume spike (10x baseline) detected by CEL engine",
		RequestedAt:         time.Now().UTC(),
	}

	res, err := executor.ExecuteStun(ctx, req)
	if err != nil {
		t.Fatalf("unexpected stun error: %v", err)
	}

	if res.Status != "STUNNED" {
		t.Errorf("expected status STUNNED, got %s", res.Status)
	}
	if !res.ServiceAccountDisabled {
		t.Errorf("expected ServiceAccountDisabled=true")
	}
	if !res.OpenBaoLeaseRevoked {
		t.Errorf("expected OpenBaoLeaseRevoked=true")
	}
	if res.SuperCredState != "STUNNED" {
		t.Errorf("expected SuperCredState=STUNNED, got %s", res.SuperCredState)
	}
	if !executor.IsStunned(req.AgentID) {
		t.Errorf("expected IsStunned=true for agent %s", req.AgentID)
	}
}

func TestMemoryStunExecutor_Validation(t *testing.T) {
	executor := NewMemoryStunExecutor()
	ctx := context.Background()

	// Empty request
	_, err := executor.ExecuteStun(ctx, StunRequest{})
	if err == nil {
		t.Errorf("expected error on empty stun request, got nil")
	}

	// Whitespace-only request
	_, err = executor.ExecuteStun(ctx, StunRequest{
		AgentID:             "   ",
		ServiceAccountEmail: "   ",
	})
	if err == nil {
		t.Errorf("expected error on whitespace stun request, got nil")
	}

	// Oversized AgentID
	longID := ""
	for i := 0; i < 257; i++ {
		longID += "a"
	}
	_, err = executor.ExecuteStun(ctx, StunRequest{AgentID: longID})
	if err == nil {
		t.Errorf("expected error on oversized AgentID, got nil")
	}

	// Oversized ServiceAccountEmail
	_, err = executor.ExecuteStun(ctx, StunRequest{ServiceAccountEmail: longID})
	if err == nil {
		t.Errorf("expected error on oversized ServiceAccountEmail, got nil")
	}

	// Oversized Reason
	longReason := ""
	for i := 0; i < 1025; i++ {
		longReason += "r"
	}
	_, err = executor.ExecuteStun(ctx, StunRequest{
		AgentID: "valid-agent",
		Reason:  longReason,
	})
	if err == nil {
		t.Errorf("expected error on oversized Reason, got nil")
	}
}
