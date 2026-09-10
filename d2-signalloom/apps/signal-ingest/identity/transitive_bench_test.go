package identity

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// BenchmarkTransitiveTraversal benchmarks traversal over synthetic delegation chains.
func BenchmarkTransitiveTraversal(b *testing.B) {
	ctx := context.Background()
	repo := NewMemoryRepository(NewNoopEncryptor())

	now := time.Now().UTC()
	// Build a 100-node delegation chain
	for i := 0; i <= 100; i++ {
		_ = repo.CreateActor(ctx, ActorRecord{
			ActorID:   fmt.Sprintf("bench-node-%d", i),
			CreatedAt: now.Add(-24 * time.Hour),
		})
	}
	for i := 0; i < 100; i++ {
		_ = repo.AddDelegation(ctx, DelegationRecord{
			DelegateActorID:  fmt.Sprintf("bench-node-%d", i),
			PrincipalActorID: fmt.Sprintf("bench-node-%d", i+1),
			AuthzRef:         fmt.Sprintf("authz-%d", i),
			ValidFrom:        now.Add(-12 * time.Hour),
		})
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _, err := repo.FindTransitiveDelegations(ctx, "bench-node-0", now, 8)
		if err != nil {
			b.Fatalf("traversal error: %v", err)
		}
	}
}
