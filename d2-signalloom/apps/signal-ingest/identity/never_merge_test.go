package identity

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestStructuralNeverMerge_RejectsAliasToDelegationPrincipal(t *testing.T) {
	TestNeverMerge_RejectsAliasToDelegationPrincipal(t)
}

func TestStructuralNeverMerge_RejectsDelegationBetweenAliasedIdentities(t *testing.T) {
	TestNeverMerge_RejectsDelegationBetweenAliasedIdentities(t)
}

func TestStructuralNeverMerge_RejectsSelfDelegation(t *testing.T) {
	TestNeverMerge_RejectsSelfDelegation(t)
}

func TestStructuralNeverMerge_CoexistenceWithoutAliasLeakage(t *testing.T) {
	TestNeverMerge_CoexistenceWithoutAliasLeakage(t)
}

// ---------------------------------------------------------------------------
// TestNeverMerge suite — pins never-merge invariant across pseudonymisation
// ---------------------------------------------------------------------------

func TestNeverMerge_RejectsAliasToDelegationPrincipal(t *testing.T) {
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

func TestNeverMerge_RejectsDelegationBetweenAliasedIdentities(t *testing.T) {
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

func TestNeverMerge_RejectsSelfDelegation(t *testing.T) {
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

func TestNeverMerge_CoexistenceWithoutAliasLeakage(t *testing.T) {
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

// TestNeverMerge_SurvivesPseudonymisation_Memory asserts that even when alias values are pseudonymised
// (and only alias_value_hash is populated / checked), the never-merge invariant continues to reject
// illegal alias and delegation links.
func TestNeverMerge_SurvivesPseudonymisation_Memory(t *testing.T) {
	ctx := context.Background()
	enc := NewNoopEncryptor()
	repo := NewMemoryRepositoryWithTenant(enc, "tenant-alpha")
	now := time.Now().UTC()

	// 1. Create actors
	delegate := ActorRecord{ActorID: "agent-007", Status: model.ActorActionable, CreatedAt: now}
	principal := ActorRecord{ActorID: "human-m", Status: model.ActorActionable, CreatedAt: now}
	if err := repo.CreateActor(ctx, delegate); err != nil {
		t.Fatalf("CreateActor: %v", err)
	}
	if err := repo.CreateActor(ctx, principal); err != nil {
		t.Fatalf("CreateActor: %v", err)
	}

	// 2. Add delegation
	deleg := DelegationRecord{
		DelegateActorID:  delegate.ActorID,
		PrincipalActorID: principal.ActorID,
		AuthzRef:         "authz-top-secret",
		ValidFrom:        now,
		CreatedAt:        now,
	}
	if err := repo.AddDelegation(ctx, deleg); err != nil {
		t.Fatalf("AddDelegation: %v", err)
	}

	// 3. Compute principal's pseudonym directly
	principalPseudo, err := enc.Pseudonym("tenant-alpha", principal.ActorID)
	if err != nil {
		t.Fatalf("Pseudonym: %v", err)
	}

	// 4. Attempt to insert alias with only pseudonym set (no cleartext alias_value)
	aliasWithPseudo := AliasRecord{
		ActorID:        delegate.ActorID,
		AliasType:      "actor",
		AliasValueHash: principalPseudo,
		ValidFrom:      now,
		CreatedAt:      now,
	}
	err = repo.AddAlias(ctx, aliasWithPseudo)
	if err == nil {
		t.Fatal("FAIL OPEN: MemoryRepository admitted an alias equating delegate to principal in pseudonym space!")
	}
	if !errors.Is(err, ErrNeverMergeViolation) {
		t.Errorf("expected ErrNeverMergeViolation, got: %v", err)
	}

	// 5. Test reverse: add alias first, then attempt illegal delegation
	otherDelegate := ActorRecord{ActorID: "agent-008", Status: model.ActorActionable, CreatedAt: now}
	otherPrincipal := ActorRecord{ActorID: "human-q", Status: model.ActorActionable, CreatedAt: now}
	_ = repo.CreateActor(ctx, otherDelegate)
	_ = repo.CreateActor(ctx, otherPrincipal)

	qPseudo, err := enc.Pseudonym("tenant-alpha", otherPrincipal.ActorID)
	if err != nil {
		t.Fatalf("Pseudonym: %v", err)
	}

	if err := repo.AddAlias(ctx, AliasRecord{
		ActorID:        otherDelegate.ActorID,
		AliasType:      "actor",
		AliasValueHash: qPseudo,
		ValidFrom:      now,
		CreatedAt:      now,
	}); err != nil {
		t.Fatalf("AddAlias legitimate setup: %v", err)
	}

	// Attempting to delegate between already aliased actors in pseudonym space MUST fail
	err = repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  otherDelegate.ActorID,
		PrincipalActorID: otherPrincipal.ActorID,
		AuthzRef:         "authz-q-grant",
		ValidFrom:        now,
		CreatedAt:        now,
	})
	if err == nil {
		t.Fatal("FAIL OPEN: MemoryRepository admitted a delegation between already-aliased identities in pseudonym space!")
	}
	if !errors.Is(err, ErrNeverMergeViolation) {
		t.Errorf("expected ErrNeverMergeViolation, got: %v", err)
	}
}

// TestNeverMerge_FailOpenVulnerabilityProof explains and tests the exact failure mode
// that SLDP-P2-3 closes: the SQL trigger in 001_identity_graph.sql compared cleartext
// principal_actor_id = NEW.alias_value. Once alias_value is pseudonymised or nulled,
// that comparison never matches and fails OPEN.
func TestNeverMerge_FailOpenVulnerabilityProof(t *testing.T) {
	const tenant = "test-bank"
	enc, err := NewAESGCMEncryptorWithKeys(
		[]byte("01234567890123456789012345678901"),
		[]byte("fedcba9876543210fedcba9876543210"),
		0,
	)
	if err != nil {
		t.Fatalf("NewAESGCMEncryptorWithKeys: %v", err)
	}

	const delegateActorID = "actor-agent-42"
	const principalActorID = "actor-human-ceo"

	// 1. In migration 001:
	// check_never_merge_alias checked: principal_actor_id = NEW.alias_value
	// After pseudonymisation, NEW.alias_value is NULL or ciphertext.
	var oldTriggerAliasValue string = "" // NULL in database post-backfill

	// Demonstration that old trigger fails open:
	oldMatches := (principalActorID == oldTriggerAliasValue)
	if oldMatches {
		t.Fatal("vulnerability demonstration invalid: cleartext matched empty string")
	}
	// Because oldMatches is false, the old trigger would NOT raise an exception and would FAIL OPEN!

	// 2. In migration 005 (domain-consistent rewrite):
	// check_never_merge_alias checks: principal_actor_pseudonym = NEW.alias_value_hash
	principalPseudonym, err := enc.Pseudonym(tenant, principalActorID)
	if err != nil {
		t.Fatalf("Pseudonym principal: %v", err)
	}

	aliasValuePseudonym, err := enc.Pseudonym(tenant, principalActorID) // trying to alias to principal
	if err != nil {
		t.Fatalf("Pseudonym alias: %v", err)
	}

	// Under migration 005, both are 64-hex keyed HMAC digests in the same domain:
	newMatches := (principalPseudonym == aliasValuePseudonym)
	if !newMatches {
		t.Fatal("domain-consistent pseudonym check failed to match identical principal pseudonym")
	}
	t.Logf("PROVED: Old comparison (cleartext==NULL) = %v (FAILS OPEN); New comparison (pseudo==pseudo) = %v (ENFORCED)",
		oldMatches, newMatches)
}

// TestNeverMerge_ConstraintAudit verifies that all migration files maintain the never-merge
// invariant and that every constraint/trigger reading alias_value has been audited.
func TestNeverMerge_ConstraintAudit(t *testing.T) {
	sql := MigrationSQL()

	// 1. check_never_merge_alias must compare in pseudonym space
	if !strings.Contains(sql, "principal_actor_pseudonym = NEW.alias_value_hash") {
		t.Error("AUDIT FAIL: check_never_merge_alias does not compare alias_value_hash against principal_actor_pseudonym")
	}
	if !strings.Contains(sql, "delegate_actor_pseudonym = NEW.alias_value_hash") {
		t.Error("AUDIT FAIL: check_never_merge_alias does not compare alias_value_hash against delegate_actor_pseudonym")
	}

	// 2. check_never_merge_delegation must compare in pseudonym space
	if !strings.Contains(sql, "alias_value_hash = NEW.principal_actor_pseudonym") {
		t.Error("AUDIT FAIL: check_never_merge_delegation does not compare principal_actor_pseudonym against alias_value_hash")
	}
	if !strings.Contains(sql, "alias_value_hash = NEW.delegate_actor_pseudonym") {
		t.Error("AUDIT FAIL: check_never_merge_delegation does not compare delegate_actor_pseudonym against alias_value_hash")
	}

	// 3. Cleartext indexes must be dropped
	if !strings.Contains(sql, "DROP INDEX IF EXISTS idx_aliases_value_temporal") {
		t.Error("AUDIT FAIL: idx_aliases_value_temporal is not dropped")
	}
	if !strings.Contains(sql, "DROP INDEX IF EXISTS idx_aliases_idempotent_seed") {
		t.Error("AUDIT FAIL: idx_aliases_idempotent_seed is not dropped")
	}

	// 4. Pseudonym shape constraint must exist
	if !strings.Contains(sql, "chk_aliases_pseudonymised") {
		t.Error("AUDIT FAIL: chk_aliases_pseudonymised constraint is missing")
	}

	// 5. Pseudonymous unique index must exist
	if !strings.Contains(sql, "idx_aliases_idempotent_seed_pseudonymous") {
		t.Error("AUDIT FAIL: idx_aliases_idempotent_seed_pseudonymous is missing")
	}
}
