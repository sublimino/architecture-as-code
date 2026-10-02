package main

import (
	"context"
	"io"
	"testing"

	"k8s.io/client-go/kubernetes/fake"
)

// RevokeCredentialsPlanes used c.defaultNamespace for every agent. An agent the
// DAG places in another namespace had its pod looked up in the wrong one, so
// its identity was derived (ns/<default>/sa/<guess>) and both credential
// planes acted on an identity it does not hold. The stun must use the
// target's DAG namespace.

const otherNamespace = "fe-signalloom-agents-b"

func TestStun_CredentialPlanesUseTheTargetsDAGNamespace(t *testing.T) {
	subject := "spiffe://signalloom.demo/ns/" + otherNamespace + "/sa/agent-solo"
	srv, paths := newFakeBaoAccessorServer(t, map[string]*fakeBaoToken{
		"acc-solo": {displayName: "jwt-" + subject},
	}, []string{"acc-solo"})
	defer srv.Close()

	pod := agentPod(gitopsAgent, "active", nil)
	pod.Namespace = otherNamespace
	bao := NewOpenBaoClient(OpenBaoConfig{Address: srv.URL, Token: "s.fleet", LogWriter: io.Discard})
	// The client's default namespace is testNamespace; the agent is not there.
	kc := newK8sFleetClientWithBao(fake.NewSimpleClientset(pod), testNamespace, bao)
	spire := &recordingSpireClient{}
	kc.spireClient = spire

	orch := NewCascadeOrchestrator(singleAgentDAG(t, otherNamespace), kc, 0)
	res, err := orch.Stun(context.Background(), gitopsAgent, "namespace_planes_test: non-default namespace")
	if err != nil {
		t.Fatalf("Stun: %v", err)
	}
	for _, plane := range []EnforcementPlane{PlaneBao, PlaneSpire} {
		p := planeByName(res.Planes, plane)
		if p == nil {
			t.Fatalf("no %s plane in %+v", plane, res.Planes)
		}
		if p.Details["subject"] != subject || p.Details["subject_source"] != "pod" || p.Outcome != OutcomeContained {
			t.Fatalf("%s outcome=%s subject=%v source=%v error=%q; want contained on %s observed from the pod",
				plane, p.Outcome, p.Details["subject"], p.Details["subject_source"], p.Error, subject)
		}
	}
	if len(spire.ids) != 1 || spire.ids[0] != subject {
		t.Fatalf("spire evicted %v, want [%s]", spire.ids, subject)
	}
	if got := revokedAccessors(*paths); len(got) != 1 {
		t.Fatalf("revoked accessors %v, want the agent's one token", got)
	}
}
