// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

type fakeDecisionStunClient struct {
	requests []StunFreezeRequest
	exempt   map[string]bool
	response *StunFreezeResponse
	err      error
}

func (f *fakeDecisionStunClient) DispatchFreeze(_ context.Context, req StunFreezeRequest) (*StunFreezeResponse, error) {
	f.requests = append(f.requests, req)
	return f.response, f.err
}

func (f *fakeDecisionStunClient) IsExempt(actorID, spiffeID string) bool {
	return f.exempt[actorID] || f.exempt[spiffeID]
}

func (f *fakeDecisionStunClient) IsInGracePeriod(_ string, _ time.Time) bool {
	return false
}

type remoteStunCall struct {
	clusterID   string
	namespace   string
	name        string
	reason      string
	requestedBy string
}

type fakeRemoteStunRequester struct {
	calls []remoteStunCall
}

func (f *fakeRemoteStunRequester) RequestRemoteStun(clusterID, namespace, name, reason, requestedBy string) {
	f.calls = append(f.calls, remoteStunCall{
		clusterID: clusterID, namespace: namespace, name: name,
		reason: reason, requestedBy: requestedBy,
	})
}

func TestDecisionStunDispatcher(t *testing.T) {
	now := time.Date(2026, 10, 11, 10, 0, 0, 0, time.UTC)
	local := &fakeDecisionStunClient{
		exempt:   make(map[string]bool),
		response: &StunFreezeResponse{Frozen: true, PodName: "kusari-agent"},
	}
	remote := &fakeRemoteStunRequester{}
	dispatcher := NewDecisionStunDispatcher(local, remote, DispatchOptions{
		Now:       func() time.Time { return now },
		ClusterID: "cluster-c",
	})
	decision := obscel.Decision{
		TenantID: "kusari",
		Actor:    "pseud-x",
		RuleID:   "landlock-verified-denial",
		WindowID: "landlock-denial-burst",
	}
	trigger := model.Observation{
		Layer:     model.LayerEndpointHost,
		ActorHint: "spiffe://osramp.local/ns/fe-signalloom-agents/sa/kusari-agent",
		ActorID:   "kusari-agent",
		Labels: map[string]string{
			"verification_status": "VERIFIED",
			"denial_reason":       "landlock denied openat /etc/shadow",
			"agent_id":            "kusari-agent",
			"spiffe_id":           "spiffe://osramp.local/ns/fe-signalloom-agents/sa/kusari-agent",
		},
	}

	outcome, err := dispatcher.Dispatch(context.Background(), decision, trigger)
	if err != nil {
		t.Fatal(err)
	}
	if !outcome.LocalDispatched || outcome.FreezeResponse != local.response {
		t.Fatalf("unexpected dispatch outcome: %#v", outcome)
	}
	if len(local.requests) != 1 || len(remote.calls) != 1 {
		t.Fatalf("calls: local=%d remote=%d, want one each", len(local.requests), len(remote.calls))
	}
	request := local.requests[0]
	if request.ActorID != "kusari-agent" {
		t.Fatalf("actor id = %q", request.ActorID)
	}
	if request.SPIFFEID != trigger.Labels["spiffe_id"] {
		t.Fatalf("SPIFFE id = %q", request.SPIFFEID)
	}
	if request.ViolationReason != ViolationLandlockDenial {
		t.Fatalf("violation reason = %q", request.ViolationReason)
	}
	if !strings.Contains(request.Action, trigger.Labels["denial_reason"]) {
		t.Fatalf("action %q does not contain denial reason", request.Action)
	}
	if request.Namespace != "fe-signalloom-agents" {
		t.Fatalf("namespace = %q", request.Namespace)
	}
	remoteCall := remote.calls[0]
	if remoteCall.clusterID != "cluster-c" || remoteCall.namespace != "fe-signalloom-agents" {
		t.Fatalf("remote target = %#v", remoteCall)
	}
	if remoteCall.name != "kusari-agent" {
		t.Fatalf("remote name = %q", remoteCall.name)
	}
	if !strings.Contains(remoteCall.reason, "landlock-denial") {
		t.Fatalf("remote reason = %q", remoteCall.reason)
	}
	if remoteCall.requestedBy != "signalloom-policy-engine" {
		t.Fatalf("remote requested by = %q", remoteCall.requestedBy)
	}

	duplicate, err := dispatcher.Dispatch(context.Background(), decision, trigger)
	if err != nil {
		t.Fatal(err)
	}
	if !duplicate.Deduped {
		t.Fatalf("duplicate outcome = %#v, want deduped", duplicate)
	}
	if len(local.requests) != 1 || len(remote.calls) != 1 {
		t.Fatalf("duplicate dispatched: local=%d remote=%d", len(local.requests), len(remote.calls))
	}

	nonMatching := decision
	nonMatching.RuleID = "another-rule"
	skipped, err := dispatcher.Dispatch(context.Background(), nonMatching, trigger)
	if err != nil {
		t.Fatal(err)
	}
	if !skipped.Skipped || skipped.Reason != "not a landlock-denial decision" {
		t.Fatalf("non-matching outcome = %#v", skipped)
	}
	if len(local.requests) != 1 || len(remote.calls) != 1 {
		t.Fatalf("non-matching decision dispatched: local=%d remote=%d", len(local.requests), len(remote.calls))
	}

	now = now.Add(5*time.Minute + time.Nanosecond)
	rearmed, err := dispatcher.Dispatch(context.Background(), decision, trigger)
	if err != nil {
		t.Fatal(err)
	}
	if !rearmed.LocalDispatched || rearmed.Deduped {
		t.Fatalf("re-armed outcome = %#v", rearmed)
	}
	if len(local.requests) != 2 || len(remote.calls) != 2 {
		t.Fatalf("re-armed calls: local=%d remote=%d, want two each", len(local.requests), len(remote.calls))
	}
}

func TestDecisionStunDispatcherExemptStillDedupes(t *testing.T) {
	now := time.Date(2026, 10, 11, 10, 0, 0, 0, time.UTC)
	local := &fakeDecisionStunClient{exempt: map[string]bool{"kusari-agent": true}}
	remote := &fakeRemoteStunRequester{}
	dispatcher := NewDecisionStunDispatcher(local, remote, DispatchOptions{Now: func() time.Time { return now }})
	decision, trigger := landlockDecisionAndTrigger()

	first, err := dispatcher.Dispatch(context.Background(), decision, trigger)
	if err != nil {
		t.Fatal(err)
	}
	if !first.LocalExempt || first.LocalDispatched {
		t.Fatalf("exempt outcome = %#v", first)
	}
	if len(local.requests) != 0 {
		t.Fatalf("exempt actor received %d local freezes", len(local.requests))
	}
	if len(remote.calls) != 1 {
		t.Fatalf("remote calls = %d, want 1", len(remote.calls))
	}

	second, err := dispatcher.Dispatch(context.Background(), decision, trigger)
	if err != nil {
		t.Fatal(err)
	}
	if !second.Deduped || len(local.requests) != 0 || len(remote.calls) != 1 {
		t.Fatalf("exempt pair was not deduped: outcome=%#v local=%d remote=%d", second, len(local.requests), len(remote.calls))
	}
}

func TestDecisionStunDispatcherNoClientsIsRecordedNoOp(t *testing.T) {
	dispatcher := NewDecisionStunDispatcher(nil, nil, DispatchOptions{})
	decision, trigger := landlockDecisionAndTrigger()
	first, err := dispatcher.Dispatch(context.Background(), decision, trigger)
	if err != nil {
		t.Fatal(err)
	}
	if !first.Skipped || first.Reason != "no stun clients configured" {
		t.Fatalf("no-client outcome = %#v", first)
	}
	second, err := dispatcher.Dispatch(context.Background(), decision, trigger)
	if err != nil {
		t.Fatal(err)
	}
	if !second.Deduped {
		t.Fatalf("no-client pair was not recorded: %#v", second)
	}
}

func TestDecisionStunDispatcherReturnsLocalErrorAndStillRequestsRemote(t *testing.T) {
	wantErr := errors.New("sentinel unavailable")
	local := &fakeDecisionStunClient{
		exempt: make(map[string]bool),
		err:    wantErr,
	}
	remote := &fakeRemoteStunRequester{}
	dispatcher := NewDecisionStunDispatcher(local, remote, DispatchOptions{})
	decision, trigger := landlockDecisionAndTrigger()

	outcome, err := dispatcher.Dispatch(context.Background(), decision, trigger)
	if !errors.Is(err, wantErr) {
		t.Fatalf("error = %v, want wrapped %v", err, wantErr)
	}
	if !outcome.LocalDispatched {
		t.Fatalf("local dispatch was not recorded: %#v", outcome)
	}
	if len(remote.calls) != 1 {
		t.Fatalf("remote calls = %d, want 1 after local error", len(remote.calls))
	}
}

func landlockDecisionAndTrigger() (obscel.Decision, model.Observation) {
	return obscel.Decision{
			TenantID: "kusari",
			Actor:    "pseud-x",
			RuleID:   "landlock-verified-denial",
			WindowID: "landlock-denial-burst",
		}, model.Observation{
			Layer:   model.LayerEndpointHost,
			ActorID: "kusari-agent",
			Labels: map[string]string{
				"verification_status": "VERIFIED",
				"denial_reason":       "landlock denied openat /etc/shadow",
				"agent_id":            "kusari-agent",
				"spiffe_id":           "spiffe://osramp.local/ns/fe-signalloom-agents/sa/kusari-agent",
			},
		}
}
