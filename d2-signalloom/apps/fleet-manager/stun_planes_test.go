package main

import (
	"context"
	"errors"
	"io"
	"testing"

	"k8s.io/client-go/kubernetes/fake"
)

// ── What this suite pins (kusari-e2e FIX-A item 1) ───────────────────────────
//
// Stun step 2 used to call RevokeCredentials, which throws away the per-plane
// results RevokeCredentialsPlanes computes. CascadeResult.planes[] therefore
// only ever carried `gitops`, and a reader of the wire could not see whether
// OpenBao or SPIRE had contained anything. A full stun must now report
// freeze, bao, spire, gitops — in that order — for each target.

// fullPlaneStun wires the real k8s client (fake clientset) to a fake OpenBao
// accessor server and a SPIRE client, then stuns agent-solo.
func fullPlaneStun(t *testing.T, spire SpireClient) *CascadeResult {
	t.Helper()
	subject := "spiffe://signalloom.demo/ns/" + testNamespace + "/sa/" + gitopsAgent
	srv, _ := newFakeBaoAccessorServer(t, map[string]*fakeBaoToken{
		"acc-solo": {displayName: "jwt-" + subject},
	}, []string{"acc-solo"})
	t.Cleanup(srv.Close)

	bao := NewOpenBaoClient(OpenBaoConfig{Address: srv.URL, Token: "s.fleet", LogWriter: io.Discard})
	kc := newK8sFleetClientWithBao(fake.NewSimpleClientset(ownedChain("active", nil, nil)...), testNamespace, bao)
	kc.spireClient = spire

	orch := NewCascadeOrchestrator(singleAgentDAG(t, testNamespace), kc, 0)
	res, err := orch.Stun(context.Background(), gitopsAgent, "stun_planes_test: full plane stun")
	if err != nil {
		t.Fatalf("Stun: %v", err)
	}
	return res
}

func planeOrder(r *CascadeResult) []EnforcementPlane {
	out := make([]EnforcementPlane, 0, len(r.Planes))
	for _, p := range r.Planes {
		out = append(out, p.Plane)
	}
	return out
}

func assertPlaneOrder(t *testing.T, r *CascadeResult) {
	t.Helper()
	want := []EnforcementPlane{PlaneFreeze, PlaneBao, PlaneSpire, PlaneGitOps}
	got := planeOrder(r)
	if len(got) != len(want) {
		t.Fatalf("planes = %v, want exactly %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("planes = %v, want exactly %v", got, want)
		}
	}
}

func TestStun_ReportsEveryCredentialPlane(t *testing.T) {
	res := fullPlaneStun(t, &recordingSpireClient{})

	assertPlaneOrder(t, res)
	for _, p := range res.Planes {
		if p.Outcome != OutcomeContained {
			t.Fatalf("plane %s outcome = %s (error %q), want contained", p.Plane, p.Outcome, p.Error)
		}
	}
	freeze := res.Planes[0]
	if freeze.Details["pod"] != gitopsAgent {
		t.Fatalf("freeze details pod = %v, want %s", freeze.Details["pod"], gitopsAgent)
	}
	if freeze.Details["state_label"] != PodStateLabel+"=stunned" {
		t.Fatalf("freeze details state_label = %v, want %s=stunned", freeze.Details["state_label"], PodStateLabel)
	}
	if bao := res.Planes[1]; bao.Details["tokens_revoked"] != 1 {
		t.Fatalf("bao tokens_revoked = %v, want 1", bao.Details["tokens_revoked"])
	}

	tgt := soleTarget(t, res)
	if tgt.Outcome != OutcomeContained || !tgt.Credential.Succeeded {
		t.Fatalf("target outcome = %s credential=%+v, want contained with a succeeded credential step", tgt.Outcome, tgt.Credential)
	}
	if res.OverallOutcome != OutcomeContained || res.OverallOutcome != AggregateOutcome(res.Planes) {
		t.Fatalf("overall = %s, planes aggregate to %s; want both contained", res.OverallOutcome, AggregateOutcome(res.Planes))
	}
}

func TestStun_FailedCredentialPlaneIsVisibleAndDowngradesTarget(t *testing.T) {
	spire := newCountingSpireClient(OutcomeUnavailable)
	spire.returnErr = errors.New("INJECTED-SPIRE-FAULT")
	res := fullPlaneStun(t, spire)

	assertPlaneOrder(t, res)
	if got := res.Planes[2]; got.Plane != PlaneSpire || got.Outcome != OutcomeUnavailable || got.Error == "" {
		t.Fatalf("spire plane = %+v, want unavailable with the error attached", got)
	}
	if got := res.Planes[1]; got.Outcome != OutcomeContained {
		t.Fatalf("bao plane = %s, want contained (its sibling's failure must not hide it)", got.Outcome)
	}
	if got := res.Planes[0]; got.Outcome != OutcomeContained {
		t.Fatalf("freeze plane = %s, want contained", got.Outcome)
	}

	tgt := soleTarget(t, res)
	if tgt.Outcome != OutcomePartial || tgt.Credential.Succeeded {
		t.Fatalf("target outcome = %s credential=%+v, want partial with a failed credential step", tgt.Outcome, tgt.Credential)
	}
	if res.OverallOutcome != OutcomePartial || AggregateOutcome(res.Planes) != OutcomePartial {
		t.Fatalf("overall = %s, planes aggregate to %s; want both partial", res.OverallOutcome, AggregateOutcome(res.Planes))
	}
}
