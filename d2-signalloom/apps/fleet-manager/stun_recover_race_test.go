package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

// Live, 2026-10-03 (e2e run 1): the operator's /recover landed while the
// sentinel's stun of the same agent was still running. It read the pod
// before the stun's label write, found nothing contained, released it
// "running" and answered success; the stun then completed and left the pod
// stunned. A recover and a stun of one agent now run one after the other:
// whichever starts second sees what the first did.

// gateClient holds one credential step open until released, so a cascade
// can be caught in flight.
type gateClient struct {
	*mockFleetClient
	holdRevoke, holdRestore bool
	entered                 chan string
	release                 chan struct{}
}

func newGateClient() *gateClient {
	return &gateClient{mockFleetClient: newMockClient(), entered: make(chan string, 4), release: make(chan struct{})}
}

func (g *gateClient) RevokeCredentials(ctx context.Context, id string) error {
	if g.holdRevoke {
		g.entered <- "stun:" + id
		<-g.release
	}
	return g.mockFleetClient.RevokeCredentials(ctx, id)
}

func (g *gateClient) RestoreCredentials(ctx context.Context, id string) error {
	if g.holdRestore {
		g.entered <- "recover:" + id
		<-g.release
	}
	return g.mockFleetClient.RestoreCredentials(ctx, id)
}

func twoAgentDAG(t *testing.T) *DAG {
	t.Helper()
	dag, err := BuildDAG([]Agent{
		{ID: "agent-solo", Type: "service", Namespace: testNamespace, State: StateRunning},
		{ID: "agent-other", Type: "service", Namespace: testNamespace, State: StateRunning},
	})
	if err != nil {
		t.Fatal(err)
	}
	return dag
}

func waitFor[T any](t *testing.T, ch <-chan T, what string) T {
	t.Helper()
	select {
	case v := <-ch:
		return v
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for %s", what)
	}
	var zero T
	return zero
}

func TestARecoverWaitsForAnInFlightStunOfTheSameAgent(t *testing.T) {
	g := newGateClient()
	g.holdRevoke = true
	o := NewCascadeOrchestrator(twoAgentDAG(t), g, 0)
	stunDone := make(chan struct{})
	go func() { _, _ = o.Stun(context.Background(), "agent-solo", ""); close(stunDone) }()
	waitFor(t, g.entered, "the stun to start")

	recovered := make(chan *CascadeResult, 1)
	go func() { r, _ := o.Recover(context.Background(), []string{"agent-solo"}); recovered <- r }()
	select {
	case r := <-recovered:
		t.Fatalf("recover answered while the stun was in flight: %+v", r.Targets)
	case <-time.After(150 * time.Millisecond):
	}

	close(g.release)
	waitFor(t, stunDone, "the stun")
	r := waitFor(t, recovered, "the recover")
	if len(r.Targets) != 1 || r.Targets[0].ToState != StateReplaced {
		t.Fatalf("recover targets = %+v; want the stunned pod replaced", r.Targets)
	}
	if got := g.getState("agent-solo"); got != StateReplaced {
		t.Fatalf("final state = %q: the stun overwrote the recovery", got)
	}
}

func TestAStunWaitsForAnInFlightRecoverOfTheSameAgent(t *testing.T) {
	g := newGateClient()
	g.states["agent-solo"] = StateStunned
	g.holdRestore = true
	o := NewCascadeOrchestrator(twoAgentDAG(t), g, 0)
	recoverDone := make(chan struct{})
	go func() { _, _ = o.Recover(context.Background(), []string{"agent-solo"}); close(recoverDone) }()
	waitFor(t, g.entered, "the recover to start")

	stunned := make(chan *CascadeResult, 1)
	go func() { r, _ := o.Stun(context.Background(), "agent-solo", ""); stunned <- r }()
	select {
	case <-stunned:
		t.Fatal("stun answered while the recover was in flight")
	case <-time.After(150 * time.Millisecond):
	}

	close(g.release)
	waitFor(t, recoverDone, "the recover")
	r := waitFor(t, stunned, "the stun")
	if r.Targets[0].FromState != StateReplaced || g.getState("agent-solo") != StateStunned {
		t.Fatalf("stun from=%q final=%q; want it applied after the recovery", r.Targets[0].FromState, g.getState("agent-solo"))
	}
}

func TestADifferentAgentIsNeverHeldUp(t *testing.T) {
	g := newGateClient()
	g.holdRevoke = true
	o := NewCascadeOrchestrator(twoAgentDAG(t), g, 0)
	go func() { _, _ = o.Stun(context.Background(), "agent-solo", "") }()
	waitFor(t, g.entered, "the stun to start")
	defer close(g.release)

	g.mu.Lock()
	g.states["agent-other"] = StateStunned
	g.mu.Unlock()
	done := make(chan struct{})
	go func() { _, _ = o.Recover(context.Background(), []string{"agent-other"}); close(done) }()
	waitFor(t, done, "an unrelated recover while agent-solo's stun is held")
}

func TestAWaitingCascadeGivesUpWithItsContext(t *testing.T) {
	g := newGateClient()
	g.holdRevoke = true
	o := NewCascadeOrchestrator(twoAgentDAG(t), g, 0)
	go func() { _, _ = o.Stun(context.Background(), "agent-solo", "") }()
	waitFor(t, g.entered, "the stun to start")
	defer close(g.release)

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	errc := make(chan error, 1)
	go func() { _, err := o.Recover(ctx, []string{"agent-solo"}); errc <- err }()
	if err := waitFor(t, errc, "the waiting recover to give up"); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v, want the deadline", err)
	}
}
