package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// BenchmarkAdversarialLoad tests throughput and latency under sustained adversarial load.
// Enforces SLA ceiling: p99 latency <= 25ms under high-throughput hostile requests.
func BenchmarkAdversarialLoad(b *testing.B) {
	s := store.NewMemoryStore()
	repo := identity.NewMemoryRepository()
	resolverStore := identity.NewGraphResolverStore(repo)
	engine, err := correlation.NewEngine(s)
	if err != nil {
		b.Fatalf("failed to create correlation engine: %v", err)
	}

	now := time.Now().UTC()
	ctx := context.Background()
	_ = repo.CreateActor(ctx, identity.ActorRecord{
		ActorID:   "bench-operator@example.com",
		Status:    model.ActorActionable,
		Metadata:  map[string]any{"type": "human", "capabilities": []string{"agent:operate"}},
		CreatedAt: now,
		UpdatedAt: now,
	})

	h := &Handlers{
		Store:         s,
		Engine:        engine,
		IdentityStore: resolverStore,
	}
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	// Pre-generate adversarial payloads
	past := now.Add(-1 * time.Hour)
	payloads := [][]byte{
		// 1. Forged witness attestation
		func() []byte {
			data, _ := json.Marshal(CreateDelegationRequest{
				DelegateActorID:  "bench-forged-agent",
				PrincipalActorID: "bench-operator@example.com",
				AuthzRef:         "claim-bench-forged",
				Signature:        "forged-bench-signature",
				Capabilities:     []string{"agent:operate"},
			})
			return data
		}(),
		// 2. Scope escalation
		func() []byte {
			data, _ := json.Marshal(CreateDelegationRequest{
				DelegateActorID:  "bench-escalator-agent",
				PrincipalActorID: "bench-operator@example.com",
				AuthzRef:         "claim-bench-escalation",
				Capabilities:     []string{"cluster:admin", "secret:dump"},
			})
			return data
		}(),
		// 3. Expired lease
		func() []byte {
			data, _ := json.Marshal(CreateDelegationRequest{
				DelegateActorID:  "bench-expired-agent",
				PrincipalActorID: "bench-operator@example.com",
				AuthzRef:         "claim-bench-expired",
				Capabilities:     []string{"agent:operate"},
				ValidTo:          &past,
			})
			return data
		}(),
		// 4. Reflexive self-delegation
		func() []byte {
			data, _ := json.Marshal(CreateDelegationRequest{
				DelegateActorID:  "bench-reflexive-agent",
				PrincipalActorID: "bench-reflexive-agent",
				AuthzRef:         "claim-bench-reflexive",
				Capabilities:     []string{"agent:operate"},
			})
			return data
		}(),
	}

	var mu sync.Mutex
	latencies := make([]time.Duration, 0, b.N)

	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		r := rand.New(rand.NewSource(time.Now().UnixNano()))
		localLatencies := make([]time.Duration, 0, 1000)

		for pb.Next() {
			idx := r.Intn(len(payloads))
			body := payloads[idx]

			req := httptest.NewRequest(http.MethodPost, "/api/v1/delegations", bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()

			start := time.Now()
			mux.ServeHTTP(rec, req)
			dur := time.Since(start)

			localLatencies = append(localLatencies, dur)
		}

		mu.Lock()
		latencies = append(latencies, localLatencies...)
		mu.Unlock()
	})
	b.StopTimer()

	if len(latencies) > 0 {
		sort.Slice(latencies, func(i, j int) bool {
			return latencies[i] < latencies[j]
		})

		p50 := latencies[len(latencies)*50/100]
		p90 := latencies[len(latencies)*90/100]
		p99 := latencies[len(latencies)*99/100]

		b.Logf("Adversarial Benchmark Latency: N=%d, p50=%v, p90=%v, p99=%v", len(latencies), p50, p90, p99)

		// Hard SLA assertion: p99 <= 25ms
		if p99 > 25*time.Millisecond {
			b.Errorf("p99 latency SLA breached: %v > 25ms", p99)
		}
	}
}

// TestAdversarialSustainedLoad fires 1,000 concurrent forged delegation requests
// and asserts what the platform must guarantee under that load: every one is
// refused for the forged attestation, and none leaves state behind -- no
// delegation and no auto-provisioned actor for either party.
//
// It deliberately asserts no wall-clock latency. A p99 over 1,000 goroutines
// measures the scheduler and whatever else the machine is running, not this
// handler: the 25ms ceiling it used to carry failed 6 runs in 40 with the CPUs
// saturated and passed every run on an idle box, with identical code. The
// latency SLA lives in BenchmarkAdversarialLoad, which is the instrument for it.
func TestAdversarialSustainedLoad(t *testing.T) {
	s := store.NewMemoryStore()
	repo := identity.NewMemoryRepository()
	resolverStore := identity.NewGraphResolverStore(repo)
	engine, err := correlation.NewEngine(s)
	if err != nil {
		t.Fatalf("failed to create correlation engine: %v", err)
	}

	h := &Handlers{
		Store:         s,
		Engine:        engine,
		IdentityStore: resolverStore,
	}
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	const totalRequests = 1000
	const principal = "nonexistent-principal"
	var wg sync.WaitGroup
	errCh := make(chan error, totalRequests)

	for i := 0; i < totalRequests; i++ {
		wg.Add(1)
		go func(seq int) {
			defer wg.Done()

			payload := CreateDelegationRequest{
				DelegateActorID:  fmt.Sprintf("adversarial-agent-%d", seq),
				PrincipalActorID: principal,
				AuthzRef:         fmt.Sprintf("forged-claim-%d", seq),
				Signature:        "forged-signature",
				Capabilities:     []string{"admin:cluster"},
			}
			body, _ := json.Marshal(payload)

			req := httptest.NewRequest(http.MethodPost, "/api/v1/delegations", bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)

			if rec.Code != http.StatusForbidden {
				errCh <- fmt.Errorf("request %d: expected HTTP 403, got %d: %s", seq, rec.Code, rec.Body.String())
				return
			}
			var refusal map[string]any
			if err := json.Unmarshal(rec.Body.Bytes(), &refusal); err != nil {
				errCh <- fmt.Errorf("request %d: undecodable refusal %q: %v", seq, rec.Body.String(), err)
				return
			}
			if refusal["violation"] != "AttestationFailed" {
				errCh <- fmt.Errorf("request %d: expected violation AttestationFailed, got %v", seq, refusal["violation"])
			}
		}(i)
	}

	wg.Wait()
	close(errCh)
	for err := range errCh {
		t.Errorf("sustained load error: %v", err)
	}

	ctx := context.Background()
	asOf := time.Now().UTC().Add(time.Hour)
	if _, err := repo.GetActor(ctx, principal); !errors.Is(err, identity.ErrActorNotFound) {
		t.Errorf("a refused request auto-provisioned the principal %q (err=%v)", principal, err)
	}
	if dels, err := repo.GetDelegationsForPrincipalAsOf(ctx, principal, asOf); err != nil || len(dels) != 0 {
		t.Errorf("refused requests persisted %d delegation(s) for %q (err=%v)", len(dels), principal, err)
	}
	for i := 0; i < totalRequests; i++ {
		delegate := fmt.Sprintf("adversarial-agent-%d", i)
		if _, err := repo.GetActor(ctx, delegate); !errors.Is(err, identity.ErrActorNotFound) {
			t.Fatalf("a refused request auto-provisioned the delegate %q (err=%v)", delegate, err)
		}
	}
}
