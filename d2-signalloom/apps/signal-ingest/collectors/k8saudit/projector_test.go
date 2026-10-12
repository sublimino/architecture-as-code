// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package k8saudit

import (
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func execEvent(stage string) AuditEvent {
	return AuditEvent{
		AuditID:   "aud-exec-1",
		Stage:     stage,
		Verb:      "create",
		User:      UserInfo{Username: "alice@corp.example"},
		SourceIPs: []string{"10.1.2.3"},
		UserAgent: "kubectl/v1.31.0",
		ObjectRef: &ObjectRef{
			Resource:    "pods",
			Subresource: "exec",
			Namespace:   "payments",
			Name:        "ledger-0",
			APIGroup:    "",
			APIVersion:  "v1",
		},
		ResponseStatus:           &ResponseStatus{Code: 201},
		Annotations:              map[string]string{decisionAnnotation: "allow"},
		StageTimestamp:           time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC),
		RequestReceivedTimestamp: time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC),
	}
}

func TestProject_ResponseCompleteExec(t *testing.T) {
	obs, ok := Projector{}.Project(execEvent(StageResponseComplete), "k8saudit://warden/node-1")
	if !ok {
		t.Fatal("a ResponseComplete exec must project an observation")
	}
	if obs.Layer != model.LayerKubernetes {
		t.Errorf("layer = %q, want %q", obs.Layer, model.LayerKubernetes)
	}
	if obs.Source != ObservationSource {
		t.Errorf("source = %q, want %q", obs.Source, ObservationSource)
	}
	if obs.ActorHint != "alice@corp.example" {
		t.Errorf("actor hint = %q, want the acting user", obs.ActorHint)
	}
	want := map[string]string{
		LabelVerb: "create", LabelResource: "pods", LabelSubresource: "exec",
		LabelNamespace: "payments", LabelName: "ledger-0", LabelAPIVersion: "v1",
		LabelDecision: "allow", LabelResponseCode: "201", LabelSourceIP: "10.1.2.3",
		LabelAuditID: "aud-exec-1", LabelStage: "ResponseComplete",
		LabelUserAgent: "kubectl/v1.31.0",
	}
	for k, v := range want {
		if obs.Labels[k] != v {
			t.Errorf("label %q = %q, want %q", k, obs.Labels[k], v)
		}
	}
	if _, ok := obs.Labels[LabelAPIGroup]; !ok {
		t.Error("api_group must always be set (\"\" is the core group, not an absence)")
	}
}

// TestProject_ActorIsNeverALabel is the binding C2 invariant: the user/SA
// identity goes to ActorHint only, never into the label space that becomes a
// segment column.
func TestProject_ActorIsNeverALabel(t *testing.T) {
	obs, _ := Projector{}.Project(execEvent(StageResponseComplete), "ref")
	for k, v := range obs.Labels {
		if v == "alice@corp.example" {
			t.Errorf("label %q carries the actor identity %q; identity must live only in ActorHint", k, v)
		}
		switch k {
		case "actor", "user", "username", "actor_hint", "impersonated_user":
			t.Errorf("label key %q is an identity key and must not be projected", k)
		}
	}
	// Every projected key is in the declared contract.
	contract := map[string]bool{}
	for _, k := range ProjectedKeys() {
		contract[k] = true
	}
	for k := range obs.Labels {
		if !contract[k] {
			t.Errorf("projected label %q is not in ProjectedKeys(); the contract and the projection disagree", k)
		}
	}
}

// TestProject_ImpersonationPrecedence: the impersonated subject is the acting
// identity, because it is the principal a rule must judge.
func TestProject_ImpersonationPrecedence(t *testing.T) {
	e := execEvent(StageResponseComplete)
	e.User = UserInfo{Username: "system:serviceaccount:ci:deployer"}
	e.ImpersonatedUser = &UserInfo{Username: "cluster-admin@corp.example"}
	obs, _ := Projector{}.Project(e, "ref")
	if obs.ActorHint != "cluster-admin@corp.example" {
		t.Errorf("actor hint = %q, want the impersonated subject", obs.ActorHint)
	}
}

// TestProject_EveryStageIsADistinctObservation: the stage filter is a rule
// concern, and for it to be mutation-testable the four stages of one request
// must be four distinct observations (distinct IDs), not one.
func TestProject_EveryStageIsADistinctObservation(t *testing.T) {
	ids := map[string]bool{}
	for _, stage := range []string{"RequestReceived", "ResponseStarted", "ResponseComplete"} {
		obs, ok := Projector{}.Project(execEvent(stage), "k8saudit://warden/node-1")
		if !ok {
			t.Fatalf("stage %q did not project", stage)
		}
		if obs.Labels[LabelStage] != stage {
			t.Errorf("stage label = %q, want %q", obs.Labels[LabelStage], stage)
		}
		if ids[obs.ID] {
			t.Errorf("stage %q produced a duplicate observation ID; stages would be deduped into one", stage)
		}
		ids[obs.ID] = true
	}
	if len(ids) != 3 {
		t.Fatalf("got %d distinct observations across 3 stages, want 3", len(ids))
	}
}

// TestProject_DecisionFallbackFromResponseCode: a record with no decision
// annotation derives the verdict from the status code.
func TestProject_DecisionFallbackFromResponseCode(t *testing.T) {
	e := execEvent(StageResponseComplete)
	e.Annotations = nil
	e.ResponseStatus = &ResponseStatus{Code: 403, Reason: "Forbidden"}
	obs, _ := Projector{}.Project(e, "ref")
	if obs.Labels[LabelDecision] != "forbid" {
		t.Errorf("decision = %q, want forbid for a 403", obs.Labels[LabelDecision])
	}
	if obs.Labels[LabelReason] != "Forbidden" {
		t.Errorf("reason = %q, want Forbidden", obs.Labels[LabelReason])
	}
}

// TestProject_NoIdentityNoResourceIsDropped: a record naming neither an actor
// nor a resource projects nothing — it is apiserver noise.
func TestProject_NoIdentityNoResourceIsDropped(t *testing.T) {
	if _, ok := (Projector{}).Project(AuditEvent{Stage: StageResponseComplete, Verb: "get"}, "ref"); ok {
		t.Error("an event with no actor and no objectRef must not project")
	}
}
