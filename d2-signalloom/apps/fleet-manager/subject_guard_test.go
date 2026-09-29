package main

import (
	"context"
	"errors"
	"io"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/fake"
)

// ── What this suite pins (kusari-e2e FIX-A items 3 and 4) ────────────────────
//
// Item 3: when the pod cannot be read, the subject is DERIVED from the agent id.
// Token revocation and SPIRE eviction by a derived subject can match nothing and
// still report contained with tokens_revoked=0. A derived identity now caps the
// bao and spire planes at partial with "identity derived, not observed".
//
// Item 4: a pod running as ServiceAccount `default` yields the subject
// .../sa/default, which every workload on that SA holds. Revoking or evicting
// it hits them all, so the planes refuse (unavailable). A non-default SA used
// by pods outside this agent's workload still acts but reports partial.

const guardAgent = "agent-cardvault"

func guardPod(name, sa string, owner string) *corev1.Pod {
	p := agentPod(name, "active", nil)
	p.Spec.ServiceAccountName = sa
	if owner != "" {
		p.OwnerReferences = []metav1.OwnerReference{{
			APIVersion: "apps/v1", Kind: "ReplicaSet", Name: owner, UID: types.UID("uid-" + owner), Controller: isController(),
		}}
	}
	return p
}

// guardClient wires the real client to a fake OpenBao server holding one token
// for the given subject, plus a recording SPIRE client.
func guardClient(t *testing.T, subject string, objects ...runtime.Object) (*k8sFleetClient, *[]string, *recordingSpireClient) {
	t.Helper()
	srv, paths := newFakeBaoAccessorServer(t, map[string]*fakeBaoToken{
		"acc-1": {displayName: "jwt-" + subject},
	}, []string{"acc-1"})
	t.Cleanup(srv.Close)
	bao := NewOpenBaoClient(OpenBaoConfig{Address: srv.URL, Token: "s.fleet", LogWriter: io.Discard})
	kc := newK8sFleetClientWithBao(fake.NewSimpleClientset(objects...), testNamespace, bao)
	spire := &recordingSpireClient{}
	kc.spireClient = spire
	return kc, paths, spire
}

func subjectFor(sa string) string {
	return "spiffe://signalloom.demo/ns/" + testNamespace + "/sa/" + sa
}

func credentialPlane(t *testing.T, results []PlaneResult, plane EnforcementPlane) PlaneResult {
	t.Helper()
	p := planeByName(results, plane)
	if p == nil {
		t.Fatalf("no %s plane in %+v", plane, results)
	}
	return *p
}

func TestSubjectGuard_DerivedIdentityCapsCredentialPlanesAtPartial(t *testing.T) {
	kc, _, spire := guardClient(t, subjectFor("cardvault")) // no pod: identity is derived

	results, err := kc.RevokeCredentialsPlanes(context.Background(), guardAgent)
	if !errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("err = %v, want ErrEnforcementUnavailable (a derived identity is not containment)", err)
	}
	for _, plane := range []EnforcementPlane{PlaneBao, PlaneSpire} {
		p := credentialPlane(t, results, plane)
		if p.Outcome != OutcomePartial {
			t.Fatalf("%s outcome = %s, want partial", plane, p.Outcome)
		}
		if !strings.Contains(p.Error, "identity derived, not observed") {
			t.Fatalf("%s error = %q, want it to say the identity was derived", plane, p.Error)
		}
		if p.Details["subject_source"] != "derived" {
			t.Fatalf("%s subject_source = %v, want derived", plane, p.Details["subject_source"])
		}
	}
	if len(spire.ids) != 1 {
		t.Fatalf("spire evictions = %v, want the derived subject still attempted once", spire.ids)
	}
}

func TestSubjectGuard_DefaultServiceAccountIsRefused(t *testing.T) {
	kc, paths, spire := guardClient(t, subjectFor("default"),
		guardPod(guardAgent, "default", "rs-cardvault"),
		guardPod("agent-other", "default", "rs-other"))

	results, err := kc.RevokeCredentialsPlanes(context.Background(), guardAgent)
	if !errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("err = %v, want ErrEnforcementUnavailable", err)
	}
	for _, plane := range []EnforcementPlane{PlaneBao, PlaneSpire} {
		p := credentialPlane(t, results, plane)
		if p.Outcome != OutcomeUnavailable {
			t.Fatalf("%s outcome = %s, want unavailable", plane, p.Outcome)
		}
		if !strings.Contains(p.Error, "refusing to act on shared ServiceAccount default") {
			t.Fatalf("%s error = %q, want the shared-SA refusal", plane, p.Error)
		}
	}
	if len(spire.ids) != 0 {
		t.Fatalf("spire evicted %v, want no eviction of the shared default identity", spire.ids)
	}
	if got := revokedAccessors(*paths); len(got) != 0 {
		t.Fatalf("revoked token accessors %v, want none for the shared default identity", got)
	}

	resp, evictErr := kc.EvictSpireEntry(context.Background(), testNamespace, guardAgent)
	if evictErr == nil || resp == nil || resp.Outcome != OutcomeUnavailable ||
		!strings.Contains(resp.Error, "refusing to act on shared ServiceAccount default") {
		t.Fatalf("EvictSpireEntry = %+v, %v; want an unavailable refusal", resp, evictErr)
	}
	if len(spire.ids) != 0 {
		t.Fatalf("EvictSpireEntry evicted %v, want none", spire.ids)
	}
}

func TestSubjectGuard_SharedServiceAccountReportsPartialWithCount(t *testing.T) {
	kc, paths, spire := guardClient(t, subjectFor("shared-sa"),
		guardPod(guardAgent, "shared-sa", "rs-cardvault"),
		guardPod("agent-other", "shared-sa", "rs-other"),
		guardPod("agent-third", "shared-sa", "rs-third"))

	results, err := kc.RevokeCredentialsPlanes(context.Background(), guardAgent)
	if !errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("err = %v, want ErrEnforcementUnavailable", err)
	}
	for _, plane := range []EnforcementPlane{PlaneBao, PlaneSpire} {
		p := credentialPlane(t, results, plane)
		if p.Outcome != OutcomePartial {
			t.Fatalf("%s outcome = %s, want partial", plane, p.Outcome)
		}
		if !strings.Contains(p.Error, "shared by 2 other pods") {
			t.Fatalf("%s error = %q, want it to name the 2 other pods on the ServiceAccount", plane, p.Error)
		}
	}
	if len(spire.ids) != 1 || len(revokedAccessors(*paths)) != 1 {
		t.Fatalf("spire=%v tokens=%v, want the revocation still carried out", spire.ids, revokedAccessors(*paths))
	}
}

func TestSubjectGuard_ReplicasOfTheSameWorkloadAreNotSharing(t *testing.T) {
	kc, _, _ := guardClient(t, subjectFor("cardvault-sa"),
		guardPod(guardAgent, "cardvault-sa", "rs-cardvault"),
		guardPod("agent-cardvault-replica", "cardvault-sa", "rs-cardvault"))

	results, err := kc.RevokeCredentialsPlanes(context.Background(), guardAgent)
	if err != nil {
		t.Fatalf("RevokeCredentialsPlanes: %v (replicas of one workload share its SA legitimately)", err)
	}
	for _, p := range results {
		if p.Outcome != OutcomeContained {
			t.Fatalf("%s outcome = %s (%s), want contained", p.Plane, p.Outcome, p.Error)
		}
	}
}
