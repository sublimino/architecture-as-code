package main

import (
	"context"
	"io"
	"sync"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

// The Kusari shape: DAG id agent-kusari-agent, pod ServiceAccount
// kusari-agent. Building the subject from the raw id targeted
// spiffe://.../sa/agent-kusari-agent, an identity nothing holds, so token
// revocation, SPIRE eviction and the consistency count all hit nothing while
// reporting success.

const (
	kusariAgentID = "agent-kusari-agent"
	kusariSubject = "spiffe://signalloom.demo/ns/" + testNamespace + "/sa/kusari-agent"
	kusariWrongID = "spiffe://signalloom.demo/ns/" + testNamespace + "/sa/agent-kusari-agent"
)

func kusariPod() *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "agent-kusari-5685ff664b-46q85",
			Namespace: testNamespace,
			Labels:    map[string]string{AgentLabel: "true", AgentNameLabel: "kusari-agent"},
		},
		Spec: corev1.PodSpec{ServiceAccountName: "kusari-agent"},
	}
}

// recordingSpireClient records the SPIFFE ID each eviction targeted.
type recordingSpireClient struct {
	countingSpireClient
	mu  sync.Mutex
	ids []string
}

func (r *recordingSpireClient) EvictAgent(_ context.Context, req SpireEvictionRequest) (*SpireEvictionResponse, error) {
	r.mu.Lock()
	r.ids = append(r.ids, req.SPIFFEID)
	r.mu.Unlock()
	return &SpireEvictionResponse{Plane: PlaneSpire, Outcome: OutcomeContained, EntriesEvicted: 1}, nil
}

func planeByName(results []PlaneResult, plane EnforcementPlane) *PlaneResult {
	for i := range results {
		if results[i].Plane == plane {
			return &results[i]
		}
	}
	return nil
}

func TestAgentSubject_KusariPodServiceAccountDrivesBothPlanes(t *testing.T) {
	srv, paths := newFakeBaoAccessorServer(t, map[string]*fakeBaoToken{
		"acc-real":  {displayName: "jwt-" + kusariSubject},
		"acc-real2": {displayName: "jwt-" + kusariSubject},
		"acc-wrong": {displayName: "jwt-" + kusariWrongID},
	}, []string{"acc-real", "acc-wrong", "acc-real2"})
	defer srv.Close()

	bao := NewOpenBaoClient(OpenBaoConfig{Address: srv.URL, Token: "s.fleet", LogWriter: io.Discard})
	kc := newK8sFleetClientWithBao(fake.NewSimpleClientset(kusariPod()), testNamespace, bao)
	spire := &recordingSpireClient{}
	kc.spireClient = spire

	results, err := kc.RevokeCredentialsPlanes(context.Background(), kusariAgentID)
	if err != nil {
		t.Fatalf("RevokeCredentialsPlanes: %v", err)
	}

	if got := revokedAccessors(*paths); len(got) != 2 || got[0] != "acc-real" || got[1] != "acc-real2" {
		t.Fatalf("revoked accessors = %q, want [acc-real acc-real2] (the pod's ServiceAccount identity)", got)
	}
	if len(spire.ids) != 1 || spire.ids[0] != kusariSubject {
		t.Fatalf("SPIRE eviction targeted %q, want [%s]", spire.ids, kusariSubject)
	}
	for _, plane := range []EnforcementPlane{PlaneBao, PlaneSpire} {
		res := planeByName(results, plane)
		if res == nil {
			t.Fatalf("no %s result", plane)
		}
		if res.Details["subject"] != kusariSubject || res.Details["subject_source"] != "pod" {
			t.Fatalf("%s details subject=%v subject_source=%v, want %s and pod", plane, res.Details["subject"], res.Details["subject_source"], kusariSubject)
		}
	}
}

func TestAgentSubject_UnreadablePodFallsBackToDerivedName(t *testing.T) {
	kc := newK8sFleetClient(fake.NewSimpleClientset(), testNamespace) // no pod
	subject, source := kc.agentSubject(context.Background(), testNamespace, kusariAgentID)
	if subject != kusariSubject || source != "derived" {
		t.Fatalf("subject=%q source=%q, want %s and derived (agentNameFromID)", subject, source, kusariSubject)
	}
}
