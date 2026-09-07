package identity

import (
	"context"
	"fmt"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// Shared canonical timestamps for fixture windows
var (
	TimeT0 = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	TimeT1 = time.Date(2026, 2, 1, 0, 0, 0, 0, time.UTC)
	TimeT2 = time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC)
	TimeT3 = time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC)
	TimeT4 = time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	TimeT5 = time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
)

// FixtureActors defines the canonical test actors.
var FixtureActors = []ActorRecord{
	{
		ActorID:   "actor-human-alice",
		Status:    model.ActorActionable,
		Metadata:  map[string]any{"type": "human", "role": "sre-lead"},
		CreatedAt: TimeT0,
		UpdatedAt: TimeT0,
	},
	{
		ActorID:   "actor-human-bob",
		Status:    model.ActorActionable,
		Metadata:  map[string]any{"type": "human", "role": "security-analyst"},
		CreatedAt: TimeT0,
		UpdatedAt: TimeT0,
	},
	{
		ActorID:   "actor-agent-deployer",
		Status:    model.ActorActionable,
		Metadata:  map[string]any{"type": "agent", "service": "continuous-delivery"},
		CreatedAt: TimeT0,
		UpdatedAt: TimeT0,
	},
	{
		ActorID:   "actor-agent-scanner",
		Status:    model.ActorActionable,
		Metadata:  map[string]any{"type": "agent", "service": "vulnerability-scan"},
		CreatedAt: TimeT0,
		UpdatedAt: TimeT0,
	},
}

// FixtureAliases defines the labelled aliases across time windows.
var FixtureAliases = []AliasRecord{
	{
		ActorID:      "actor-human-alice",
		AliasType:    "email",
		AliasValue:   "alice@corp.internal",
		EdgeFidelity: model.FidelityDefinitive,
		ValidFrom:    TimeT0,
		ValidTo:      &TimeT5, // [T0, T5)
		CreatedAt:    TimeT0,
	},
	{
		ActorID:      "actor-human-alice",
		AliasType:    "email",
		AliasValue:   "alice-promoted@corp.internal",
		EdgeFidelity: model.FidelityDefinitive,
		ValidFrom:    TimeT5,
		ValidTo:      nil, // [T5, infinity)
		CreatedAt:    TimeT5,
	},
	{
		ActorID:      "actor-human-bob",
		AliasType:    "email",
		AliasValue:   "bob@corp.internal",
		EdgeFidelity: model.FidelityDefinitive,
		ValidFrom:    TimeT0,
		ValidTo:      nil, // [T0, infinity)
		CreatedAt:    TimeT0,
	},
	{
		ActorID:      "actor-agent-deployer",
		AliasType:    "spiffe",
		AliasValue:   "spiffe://cluster.local/ns/prod/sa/deployer",
		EdgeFidelity: model.FidelityDefinitive,
		ValidFrom:    TimeT0,
		ValidTo:      nil, // [T0, infinity)
		CreatedAt:    TimeT0,
	},
	{
		ActorID:      "actor-agent-deployer",
		AliasType:    "session",
		AliasValue:   "deployer-session-123",
		EdgeFidelity: model.FidelityStrong,
		ValidFrom:    TimeT2,
		ValidTo:      &TimeT3, // [T2, T3)
		CreatedAt:    TimeT2,
	},
	{
		ActorID:      "actor-agent-scanner",
		AliasType:    "spiffe",
		AliasValue:   "spiffe://cluster.local/ns/security/sa/scanner",
		EdgeFidelity: model.FidelityDefinitive,
		ValidFrom:    TimeT0,
		ValidTo:      nil, // [T0, infinity)
		CreatedAt:    TimeT0,
	},
}

// FixtureDelegations defines the acts-on-behalf-of delegations across time windows.
var FixtureDelegations = []DelegationRecord{
	{
		DelegateActorID:  "actor-agent-deployer",
		PrincipalActorID: "actor-human-alice",
		AuthzRef:         "oauth2-token-grant-xyz-1",
		ValidFrom:        TimeT1,
		ValidTo:          &TimeT3, // [T1, T3)
		Metadata:         map[string]any{"scope": "deploy:prod"},
		CreatedAt:        TimeT1,
	},
	{
		DelegateActorID:  "actor-agent-deployer",
		PrincipalActorID: "actor-human-alice",
		AuthzRef:         "oauth2-token-grant-xyz-2",
		ValidFrom:        TimeT3,
		ValidTo:          nil, // [T3, infinity)
		Metadata:         map[string]any{"scope": "deploy:prod:extended"},
		CreatedAt:        TimeT3,
	},
	{
		DelegateActorID:  "actor-agent-scanner",
		PrincipalActorID: "actor-agent-deployer",
		AuthzRef:         "mcp-subtask-delegation-456",
		ValidFrom:        TimeT4,
		ValidTo:          &TimeT5, // [T4, T5)
		Metadata:         map[string]any{"task": "pre-deploy-audit"},
		CreatedAt:        TimeT4,
	},
}

// SeedFixtureGraph populates the repository with the shared canonical actors, aliases, and delegations.
func SeedFixtureGraph(ctx context.Context, repo Repository) error {
	for _, a := range FixtureActors {
		if err := repo.CreateActor(ctx, a); err != nil {
			return fmt.Errorf("seed actor %s failed: %w", a.ActorID, err)
		}
	}
	for _, al := range FixtureAliases {
		if err := repo.AddAlias(ctx, al); err != nil {
			return fmt.Errorf("seed alias %s failed: %w", al.AliasValue, err)
		}
	}
	for _, d := range FixtureDelegations {
		if err := repo.AddDelegation(ctx, d); err != nil {
			return fmt.Errorf("seed delegation %s->%s failed: %w", d.DelegateActorID, d.PrincipalActorID, err)
		}
	}
	return nil
}
