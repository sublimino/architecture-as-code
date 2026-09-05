package identity

import (
	"context"
	"errors"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestStructuralNeverMerge_RejectsAliasToDelegationPrincipal(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepository()

	// 1. Create two actors: delegate and principal
	delegate := ActorRecord{ActorID: "actor-delegate-1", Status: model.ActorActionable, CreatedAt: TimeT0}
	principal := ActorRecord{ActorID: "actor-principal-1", Status: model.ActorActionable, CreatedAt: TimeT0}
	if err := repo.CreateActor(ctx, delegate); err != nil {
		t.Fatalf("CreateActor delegate: %v", err)
	}
	if err := repo.CreateActor(ctx, principal); err != nil {
		t.Fatalf("CreateActor principal: %v", err)
	}

	// 2. Establish delegation: delegate -> principal
	deleg := DelegationRecord{
		DelegateActorID:  delegate.ActorID,
		PrincipalActorID: principal.ActorID,
		AuthzRef:         "authz-token-123",
		ValidFrom:        TimeT0,
		ValidTo:          nil,
	}
	if err := repo.AddDelegation(ctx, deleg); err != nil {
		t.Fatalf("AddDelegation: %v", err)
	}

	// 3. Attempting to insert an alias row equating delegate to its delegation principal MUST fail
	invalidAlias := AliasRecord{
		ActorID:      delegate.ActorID,
		AliasType:    "principal_merge_attempt",
		AliasValue:   principal.ActorID, // Pointing delegate at principal as alias
		EdgeFidelity: model.FidelityDefinitive,
		ValidFrom:    TimeT0,
	}
	err := repo.AddAlias(ctx, invalidAlias)
	if err == nil {
		t.Fatal("expected structural rejection when trying to alias delegate to its principal")
	}
	if !errors.Is(err, ErrNeverMergeViolation) {
		t.Errorf("expected ErrNeverMergeViolation, got: %v", err)
	}

	// 4. Attempting to alias principal to delegate must also fail
	invalidAliasReverse := AliasRecord{
		ActorID:      principal.ActorID,
		AliasType:    "delegate_merge_attempt",
		AliasValue:   delegate.ActorID,
		EdgeFidelity: model.FidelityDefinitive,
		ValidFrom:    TimeT0,
	}
	err = repo.AddAlias(ctx, invalidAliasReverse)
	if err == nil {
		t.Fatal("expected structural rejection when trying to alias principal to its delegate")
	}
	if !errors.Is(err, ErrNeverMergeViolation) {
		t.Errorf("expected ErrNeverMergeViolation, got: %v", err)
	}
}

func TestStructuralNeverMerge_RejectsDelegationBetweenAliasedIdentities(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepository()

	act1 := ActorRecord{ActorID: "actor-1", Status: model.ActorActionable, CreatedAt: TimeT0}
	act2 := ActorRecord{ActorID: "actor-2", Status: model.ActorActionable, CreatedAt: TimeT0}
	_ = repo.CreateActor(ctx, act1)
	_ = repo.CreateActor(ctx, act2)

	// Add alias equating actor-1 to actor-2
	alias := AliasRecord{
		ActorID:      act1.ActorID,
		AliasType:    "legacy_alias",
		AliasValue:   act2.ActorID,
		EdgeFidelity: model.FidelityDefinitive,
		ValidFrom:    TimeT0,
	}
	if err := repo.AddAlias(ctx, alias); err != nil {
		t.Fatalf("AddAlias: %v", err)
	}

	// Attempting to create a delegation between already aliased actors MUST fail
	deleg := DelegationRecord{
		DelegateActorID:  act1.ActorID,
		PrincipalActorID: act2.ActorID,
		AuthzRef:         "token-abc",
		ValidFrom:        TimeT0,
	}
	err := repo.AddDelegation(ctx, deleg)
	if err == nil {
		t.Fatal("expected structural rejection when creating delegation between aliased identities")
	}
	if !errors.Is(err, ErrNeverMergeViolation) {
		t.Errorf("expected ErrNeverMergeViolation, got: %v", err)
	}
}

func TestStructuralNeverMerge_RejectsSelfDelegation(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepository()

	act := ActorRecord{ActorID: "actor-self", Status: model.ActorActionable, CreatedAt: TimeT0}
	_ = repo.CreateActor(ctx, act)

	selfDeleg := DelegationRecord{
		DelegateActorID:  act.ActorID,
		PrincipalActorID: act.ActorID, // Self delegation
		AuthzRef:         "token-self",
		ValidFrom:        TimeT0,
	}
	err := repo.AddDelegation(ctx, selfDeleg)
	if err == nil {
		t.Fatal("expected error on self-delegation")
	}
	if !errors.Is(err, ErrNeverMergeViolation) {
		t.Errorf("expected ErrNeverMergeViolation, got: %v", err)
	}
}

func TestStructuralNeverMerge_CoexistenceWithoutAliasLeakage(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepository()
	if err := SeedFixtureGraph(ctx, repo); err != nil {
		t.Fatalf("SeedFixtureGraph: %v", err)
	}

	asOf := TimeT2

	// Get aliases for deployer
	deployerAliases, err := repo.GetAliasesForActorAsOf(ctx, "actor-agent-deployer", asOf)
	if err != nil {
		t.Fatalf("GetAliasesForActorAsOf deployer: %v", err)
	}

	// Get aliases for alice
	aliceAliases, err := repo.GetAliasesForActorAsOf(ctx, "actor-human-alice", asOf)
	if err != nil {
		t.Fatalf("GetAliasesForActorAsOf alice: %v", err)
	}

	// Assert mutual exclusion: Deployer aliases have no alice email; Alice aliases have no deployer SPIFFE
	for _, a := range deployerAliases {
		if a.AliasValue == "alice@corp.internal" || a.AliasValue == "alice-promoted@corp.internal" {
			t.Errorf("deployer aliases leaked alice alias: %s", a.AliasValue)
		}
	}
	for _, a := range aliceAliases {
		if a.AliasValue == "spiffe://cluster.local/ns/prod/sa/deployer" || a.AliasValue == "deployer-session-123" {
			t.Errorf("alice aliases leaked deployer alias: %s", a.AliasValue)
		}
	}

	// Delegations are present and distinct
	deployerDelegations, err := repo.GetDelegationsForDelegateAsOf(ctx, "actor-agent-deployer", asOf)
	if err != nil {
		t.Fatalf("GetDelegationsForDelegateAsOf: %v", err)
	}
	if len(deployerDelegations) != 1 {
		t.Fatalf("expected 1 delegation, got %d", len(deployerDelegations))
	}
	if deployerDelegations[0].PrincipalActorID != "actor-human-alice" {
		t.Errorf("expected principal actor-human-alice, got %s", deployerDelegations[0].PrincipalActorID)
	}
}
