// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

type recordingStunClient struct {
	mu       sync.Mutex
	calls    int
	last     StunFreezeRequest
	response *StunFreezeResponse
	err      error
}

func (f *recordingStunClient) DispatchFreeze(_ context.Context, req StunFreezeRequest) (*StunFreezeResponse, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	f.last = req
	if f.response == nil {
		f.response = &StunFreezeResponse{Frozen: true}
	}
	return f.response, f.err
}

func (f *recordingStunClient) IsExempt(string, string) bool { return false }

func (f *recordingStunClient) IsInGracePeriod(string, time.Time) bool { return false }

func (f *recordingStunClient) snapshot() (int, StunFreezeRequest) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls, f.last
}

func attackChainFixtures(at time.Time, actorID string) map[string][]model.Observation {
	observation := func(id string, offset time.Duration, layer model.Layer, source string) model.Observation {
		return model.Observation{
			ID:         id,
			Timestamp:  at.Add(offset),
			Layer:      layer,
			Source:     source,
			Fidelity:   model.FidelitySuggestive,
			Confidence: 0.4,
			ActorID:    actorID,
		}
	}
	return map[string][]model.Observation{
		"exfil": {
			observation("exfil-cloud", 0, model.LayerCloudControlPlane, "gcp-cloud-audit"),
			observation("exfil-host", time.Minute, model.LayerEndpointHost, "tetragon"),
			observation("exfil-network", 2*time.Minute, model.LayerNetworkEgress, "net-ebpf"),
		},
		"account-takeover": {
			observation("ato-saas", 0, model.LayerApplicationSaaS, "google-workspace.drive-audit"),
			observation("ato-k8s", time.Minute, model.LayerKubernetes, "k8s-apiserver-audit"),
			observation("ato-cloud", 2*time.Minute, model.LayerCloudControlPlane, "iam.amazonaws.com"),
		},
		"privilege-cascade": {
			observation("priv-k8s", 0, model.LayerKubernetes, "k8s-apiserver-audit"),
			observation("priv-secret", time.Minute, model.LayerCloudControlPlane, "openbao-audit"),
			observation("priv-root", 2*time.Minute, model.LayerCloudControlPlane, "openbao-audit"),
		},
	}
}

func findChain(t *testing.T, id string) AttackChain {
	t.Helper()
	for _, chain := range DefaultAttackChains() {
		if chain.ID == id {
			return chain
		}
	}
	t.Fatalf("default chain %q not found", id)
	return AttackChain{}
}

func TestAttackChainDetector_DefaultChains(t *testing.T) {
	now := time.Date(2026, time.October, 12, 10, 0, 0, 0, time.UTC)
	actorID := "resolved-actor-7"
	fixtures := attackChainFixtures(now, actorID)

	for _, chainID := range []string{"exfil", "account-takeover", "privilege-cascade"} {
		chainID := chainID
		chain := findChain(t, chainID)
		observations := fixtures[chainID]

		t.Run(chainID+"/complete", func(t *testing.T) {
			stun := &recordingStunClient{}
			detector := NewAttackChainDetector(stun)
			matches, err := detector.Evaluate(context.Background(), observations)
			if err != nil {
				t.Fatal(err)
			}
			if len(matches) != 1 {
				t.Fatalf("want one %s match, got %#v", chainID, matches)
			}
			match := matches[0]
			if match.ChainID != chainID || match.ActorID != actorID {
				t.Fatalf("wrong correlated identity: %#v", match)
			}
			wantIDs := []string{observations[0].ID, observations[1].ID, observations[2].ID}
			if !reflect.DeepEqual(match.ObservationIDs, wantIDs) {
				t.Fatalf("observation order/distinctness: want %v, got %v", wantIDs, match.ObservationIDs)
			}
			maxSingle := 0.0
			for _, observation := range observations {
				if observation.Confidence > maxSingle {
					maxSingle = observation.Confidence
				}
			}
			if match.Confidence < 0.5 || match.Confidence <= maxSingle {
				t.Fatalf("correlated confidence %f must be actionable and exceed max single %f", match.Confidence, maxSingle)
			}
			if !match.StunDispatched || match.StunResponse == nil || !match.StunResponse.Frozen {
				t.Fatalf("stun result not recorded: %#v", match)
			}
			calls, request := stun.snapshot()
			if calls != 1 {
				t.Fatalf("want one stun dispatch, got %d", calls)
			}
			if request.ActorID != actorID || request.ViolationReason != chain.Reason {
				t.Fatalf("wrong stun request: %#v", request)
			}
		})

		t.Run(chainID+"/partial", func(t *testing.T) {
			stun := &recordingStunClient{}
			detector := NewAttackChainDetector(stun)
			matches, err := detector.Evaluate(context.Background(), observations[:len(observations)-1])
			if err != nil {
				t.Fatal(err)
			}
			if len(matches) != 0 {
				t.Fatalf("partial chain must not correlate: %#v", matches)
			}
			if calls, _ := stun.snapshot(); calls != 0 {
				t.Fatalf("partial chain must not stun, got %d calls", calls)
			}
		})

		t.Run(chainID+"/different-actor", func(t *testing.T) {
			stun := &recordingStunClient{}
			detector := NewAttackChainDetector(stun)
			split := append([]model.Observation(nil), observations...)
			split[1].ActorID = "resolved-actor-other"
			matches, err := detector.Evaluate(context.Background(), split)
			if err != nil {
				t.Fatal(err)
			}
			if len(matches) != 0 {
				t.Fatalf("cross-actor findings must not correlate: %#v", matches)
			}
			if calls, _ := stun.snapshot(); calls != 0 {
				t.Fatalf("cross-actor findings must not stun, got %d calls", calls)
			}
		})
	}
}

func TestAttackChainDetector_UsesPrincipalIDFallback(t *testing.T) {
	observations := attackChainFixtures(time.Now().UTC(), "")["exfil"]
	for index := range observations {
		observations[index].PrincipalID = "principal-9"
	}
	detector := NewAttackChainDetector(nil)
	matches, err := detector.Evaluate(context.Background(), observations)
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 1 || matches[0].ActorID != "principal-9" {
		t.Fatalf("principal fallback did not correlate: %#v", matches)
	}
}

func TestAttackChainDetector_IgnoresUnresolvedFindings(t *testing.T) {
	observations := attackChainFixtures(time.Now().UTC(), "")["exfil"]
	for index := range observations {
		observations[index].ActorHint = "cleartext-hint-must-not-join"
	}
	detector := NewAttackChainDetector(nil)
	matches, err := detector.Evaluate(context.Background(), observations)
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 0 {
		t.Fatalf("unresolved findings must be ignored: %#v", matches)
	}
}

func TestAttackChainDetector_IdempotentStun(t *testing.T) {
	observations := attackChainFixtures(time.Now().UTC(), "resolved-actor-8")["exfil"]
	stun := &recordingStunClient{}
	detector := NewAttackChainDetector(stun)
	for run := 0; run < 2; run++ {
		matches, err := detector.Evaluate(context.Background(), observations)
		if err != nil {
			t.Fatal(err)
		}
		if len(matches) != 1 {
			t.Fatalf("run %d: want one match, got %#v", run, matches)
		}
	}
	if calls, _ := stun.snapshot(); calls != 1 {
		t.Fatalf("repeated evaluation must dispatch once, got %d", calls)
	}
}

func TestAttackChainDetector_StunErrorIsWrapped(t *testing.T) {
	observations := attackChainFixtures(time.Now().UTC(), "resolved-actor-9")["exfil"]
	stunErr := errors.New("sentinel unavailable")
	stun := &recordingStunClient{err: stunErr}
	detector := NewAttackChainDetector(stun)
	matches, err := detector.Evaluate(context.Background(), observations)
	if !errors.Is(err, stunErr) || !strings.Contains(err.Error(), "dispatch stun") {
		t.Fatalf("want wrapped stun error, got %v", err)
	}
	if len(matches) != 1 || matches[0].StunDispatched {
		t.Fatalf("failed dispatch must retain an undispatched match: %#v", matches)
	}
}

func TestEngine_AttackChainMatchesAndStuns(t *testing.T) {
	observations := attackChainFixtures(time.Now().UTC(), "resolved-engine-actor")["account-takeover"]
	signalStore := store.NewMemoryStore()
	if err := signalStore.Append(context.Background(), observations); err != nil {
		t.Fatal(err)
	}
	engine, err := NewEngine(signalStore)
	if err != nil {
		t.Fatal(err)
	}
	stun := &recordingStunClient{}
	engine.SetAttackChainDetector(NewAttackChainDetector(stun))
	if _, err := engine.Correlate(context.Background()); err != nil {
		t.Fatal(err)
	}
	matches := engine.AttackChainMatches()
	if len(matches) != 1 || matches[0].ChainID != "account-takeover" || matches[0].ActorID != "resolved-engine-actor" {
		t.Fatalf("engine did not retain authoritative chain match: %#v", matches)
	}
	if calls, _ := stun.snapshot(); calls != 1 {
		t.Fatalf("engine correlation must dispatch one stun, got %d", calls)
	}

	matches[0].ObservationIDs[0] = "mutated"
	if engine.AttackChainMatches()[0].ObservationIDs[0] == "mutated" {
		t.Fatal("AttackChainMatches must clone nested observation IDs")
	}
}
