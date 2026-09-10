package identity

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

func TestCapabilityClaimVerifier(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepository()
	s := store.NewMemoryStore()

	countStore := func() int {
		obs, err := s.QueryRange(ctx, store.Query{})
		if err != nil {
			return 0
		}
		return len(obs)
	}

	// Seed test actors
	now := time.Now().UTC()
	err := repo.CreateActor(ctx, ActorRecord{
		ActorID:   "actor-human-alice",
		Status:    model.ActorActionable,
		Metadata:  map[string]any{"type": "human", "role": "operator", "capabilities": []string{"agent:*", "deploy:staging", "read:*"}},
		CreatedAt: now,
		UpdatedAt: now,
	})
	if err != nil {
		t.Fatalf("CreateActor alice failed: %v", err)
	}

	err = repo.CreateActor(ctx, ActorRecord{
		ActorID:   "actor-restricted-analyst",
		Status:    model.ActorActionable,
		Metadata:  map[string]any{"type": "human", "role": "analyst", "capabilities": []string{"read:logs", "scan:status"}},
		CreatedAt: now,
		UpdatedAt: now,
	})
	if err != nil {
		t.Fatalf("CreateActor analyst failed: %v", err)
	}

	err = repo.CreateActor(ctx, ActorRecord{
		ActorID:   "actor-agent-1",
		Status:    model.ActorProvisional,
		Metadata:  map[string]any{"type": "agent"},
		CreatedAt: now,
		UpdatedAt: now,
	})
	if err != nil {
		t.Fatalf("CreateActor agent-1 failed: %v", err)
	}

	verifier := NewCapabilityClaimVerifier(repo, s)

	t.Run("legitimate_claim_within_bounds", func(t *testing.T) {
		claim := CapabilityClaim{
			ClaimID:          "claim-valid-1",
			DelegateActorID:  "actor-agent-1",
			PrincipalActorID: "actor-human-alice",
			Capabilities:     []string{"agent:operate", "deploy:staging", "read:telemetry"},
			ValidFrom:        now,
		}

		res, err := verifier.VerifyClaim(ctx, claim)
		if err != nil {
			t.Fatalf("expected claim to pass, got err: %v", err)
		}
		if !res.Valid {
			t.Fatal("expected res.Valid == true")
		}
		if len(res.Capabilities) != 3 {
			t.Errorf("expected 3 normalized capabilities, got %d", len(res.Capabilities))
		}
	})

	t.Run("escalation_rejected_100_percent", func(t *testing.T) {
		escalationAttempts := []struct {
			name        string
			principal   string
			caps        []string
			expectedErr string
		}{
			{
				name:        "analyst_requests_deploy_prod",
				principal:   "actor-restricted-analyst",
				caps:        []string{"deploy:prod"},
				expectedErr: "deploy:prod",
			},
			{
				name:        "analyst_requests_cluster_admin",
				principal:   "actor-restricted-analyst",
				caps:        []string{"cluster-admin"},
				expectedErr: "cluster-admin",
			},
			{
				name:        "alice_requests_deploy_prod_unauthorized",
				principal:   "actor-human-alice",
				caps:        []string{"deploy:prod"}, // alice only has deploy:staging
				expectedErr: "deploy:prod",
			},
			{
				name:        "analyst_requests_agent_stun_mutation",
				principal:   "actor-restricted-analyst",
				caps:        []string{"agent:stun", "read:logs"},
				expectedErr: "agent:stun",
			},
			{
				name:        "unregistered_user_requests_admin",
				principal:   "unknown-service-account",
				caps:        []string{"admin:all"},
				expectedErr: "admin:all",
			},
		}

		initialViolationCount := countStore()

		for i, tc := range escalationAttempts {
			t.Run(tc.name, func(t *testing.T) {
				claim := CapabilityClaim{
					ClaimID:          tc.name,
					DelegateActorID:  "actor-agent-1",
					PrincipalActorID: tc.principal,
					Capabilities:     tc.caps,
					ValidFrom:        now,
				}

				res, err := verifier.VerifyClaim(ctx, claim)
				if err == nil {
					t.Fatalf("[%s] expected capability escalation to be rejected, but it succeeded", tc.name)
				}
				if res.Valid {
					t.Fatalf("[%s] expected res.Valid to be false", tc.name)
				}

				var scopeErr *ScopeExceededError
				if !errors.As(err, &scopeErr) {
					t.Fatalf("[%s] expected ScopeExceededError, got: %v", tc.name, err)
				}
				if !errors.Is(err, ErrScopeExceeded) {
					t.Fatalf("[%s] expected err to unwrap to ErrScopeExceeded", tc.name)
				}

				// Verify audit violation observation was written to the store
				if res.ViolationRecord == nil {
					t.Fatalf("[%s] expected violation record in result", tc.name)
				}
				if res.ViolationRecord.Labels["violation_type"] != "scope_exceeded" {
					t.Errorf("[%s] expected violation_type=scope_exceeded, got: %s",
						tc.name, res.ViolationRecord.Labels["violation_type"])
				}

				expectedStoreCount := initialViolationCount + i + 1
				if countStore() != expectedStoreCount {
					t.Errorf("[%s] expected store to have %d observations, got %d", tc.name, expectedStoreCount, countStore())
				}
			})
		}
	})

	t.Run("forged_claims_rejected", func(t *testing.T) {
		forgedCases := []struct {
			name           string
			sig            string
			signatureValid *bool
		}{
			{name: "explicit_forged_flag", sig: "forged"},
			{name: "invalid_sig_prefix", sig: "invalid-signature-1234"},
			{name: "tampered_signature_valid_flag", sig: "some-sig", signatureValid: boolPtr(false)},
		}

		for _, fc := range forgedCases {
			t.Run(fc.name, func(t *testing.T) {
				claim := CapabilityClaim{
					ClaimID:          fc.name,
					DelegateActorID:  "actor-agent-1",
					PrincipalActorID: "actor-human-alice",
					Capabilities:     []string{"agent:operate"},
					Signature:        fc.sig,
					SignatureValid:   fc.signatureValid,
					ValidFrom:        now,
				}

				res, err := verifier.VerifyClaim(ctx, claim)
				if err == nil {
					t.Fatalf("expected forged claim to be rejected")
				}
				if !errors.Is(err, ErrForgedClaim) {
					t.Fatalf("expected ErrForgedClaim, got: %v", err)
				}
				if res.ViolationRecord == nil {
					t.Fatal("expected audit violation record for forged claim")
				}
				if res.ViolationRecord.Labels["violation_type"] != "forged_signature" {
					t.Errorf("expected forged_signature violation, got %s", res.ViolationRecord.Labels["violation_type"])
				}
			})
		}
	})

	t.Run("landlock_containment_for_agent_nono_evidenced", func(t *testing.T) {
		// Case A: Missing Landlock claim on agent-nono-evidenced -> rejected
		uncontainedClaim := CapabilityClaim{
			ClaimID:           "claim-nono-uncontained",
			DelegateActorID:   "agent-nono-evidenced",
			PrincipalActorID:  "actor-human-alice",
			Capabilities:      []string{"agent:operate"},
			ContainmentClaims: []string{"network:isolated"}, // missing Landlock
			ValidFrom:         now,
		}

		res, err := verifier.VerifyClaim(ctx, uncontainedClaim)
		if err == nil {
			t.Fatal("expected missing landlock claim to be rejected on agent-nono-evidenced")
		}
		if !errors.Is(err, ErrMissingLandlockClaim) {
			t.Fatalf("expected ErrMissingLandlockClaim, got: %v", err)
		}
		if res.ViolationRecord == nil {
			t.Fatal("expected audit violation record for missing landlock containment")
		}
		if res.ViolationRecord.Labels["violation_type"] != "missing_landlock_containment" {
			t.Errorf("expected missing_landlock_containment violation, got %s", res.ViolationRecord.Labels["violation_type"])
		}

		// Case B: Verified Landlock claim on agent-nono-evidenced -> passes
		containedClaim := CapabilityClaim{
			ClaimID:           "claim-nono-contained",
			DelegateActorID:   "agent-nono-evidenced",
			PrincipalActorID:  "actor-human-alice",
			Capabilities:      []string{"agent:operate"},
			ContainmentClaims: []string{"containment:landlock", "network:isolated"},
			ValidFrom:         now,
		}

		res, err = verifier.VerifyClaim(ctx, containedClaim)
		if err != nil {
			t.Fatalf("expected contained claim to pass, got err: %v", err)
		}
		if !res.Valid {
			t.Fatal("expected res.Valid == true")
		}
		if !res.LandlockVerified {
			t.Fatal("expected res.LandlockVerified == true")
		}
	})

	t.Run("invalid_payload_rejected", func(t *testing.T) {
		claim := CapabilityClaim{
			ClaimID: "invalid-empty",
		}
		res, err := verifier.VerifyClaim(ctx, claim)
		if err == nil {
			t.Fatal("expected empty claim to fail")
		}
		if !errors.Is(err, ErrInvalidClaim) {
			t.Errorf("expected ErrInvalidClaim, got %v", err)
		}
		if res.Valid {
			t.Fatal("expected res.Valid == false")
		}
	})
}

func boolPtr(b bool) *bool {
	return &b
}
