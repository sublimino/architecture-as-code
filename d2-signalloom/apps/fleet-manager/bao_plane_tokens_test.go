package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"k8s.io/client-go/kubernetes/fake"
)

// The bao plane used to revoke one synthetic lease ("cardvault/creds/<agent>")
// and report Contained, while every JWT-login token the agent held stayed live
// until its 5m TTL. These tests pin that a stun now kills the tokens, and that
// the plane is Contained only when BOTH the lease and the token revocation
// succeeded.

const baoPlaneSubject = "spiffe://signalloom.demo/ns/" + testNamespace + "/sa/agent-cardvault"

func baoPlaneClient(t *testing.T, addr string) *k8sFleetClient {
	t.Helper()
	bao := NewOpenBaoClient(OpenBaoConfig{Address: addr, Token: "s.fleet", LogWriter: io.Discard})
	// The agent pod carries ServiceAccount agent-cardvault, which is where the
	// plane reads the subject from (agentSubject).
	return newK8sFleetClientWithBao(fake.NewSimpleClientset(agentPod("agent-cardvault", "active", nil)), testNamespace, bao)
}

func TestBaoPlane_RevokesTheAgentsTokens(t *testing.T) {
	srv, paths := newFakeBaoAccessorServer(t, map[string]*fakeBaoToken{
		"acc-1":     {displayName: "jwt-" + baoPlaneSubject},
		"acc-2":     {displayName: "jwt-" + baoPlaneSubject, meta: map[string]string{"sub": baoPlaneSubject}},
		"acc-other": {displayName: "jwt-spiffe://signalloom.demo/ns/" + testNamespace + "/sa/kusari-agent"},
	}, []string{"acc-1", "acc-other", "acc-2"})
	defer srv.Close()

	res, err := baoPlaneClient(t, srv.URL).revokeBaoPlane(context.Background(), testNamespace, "agent-cardvault", "k1")
	if err != nil {
		t.Fatalf("revokeBaoPlane: %v", err)
	}
	if res.Outcome != OutcomeContained {
		t.Fatalf("outcome = %s, want contained", res.Outcome)
	}
	if res.Details["leases_revoked"] != 1 || res.Details["tokens_revoked"] != 2 {
		t.Fatalf("details leases_revoked=%v tokens_revoked=%v, want 1 and 2", res.Details["leases_revoked"], res.Details["tokens_revoked"])
	}
	if got := revokedAccessors(*paths); len(got) != 2 || got[0] != "acc-1" || got[1] != "acc-2" {
		t.Fatalf("revoked accessors = %q, want [acc-1 acc-2]", got)
	}
	if res.Details["subject"] != baoPlaneSubject || res.Details["subject_source"] != "pod" {
		t.Fatalf("subject=%v source=%v, want %s from the pod", res.Details["subject"], res.Details["subject_source"], baoPlaneSubject)
	}
}

func TestBaoPlane_TokenRevocationFailureIsNotContained(t *testing.T) {
	// Lease revoke succeeds; the accessor LIST is refused. Reporting Contained
	// here is precisely the old defect: a live token behind a green plane.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/sys/leases/revoke" {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"errors":["storage unavailable"]}`))
	}))
	defer srv.Close()

	res, err := baoPlaneClient(t, srv.URL).revokeBaoPlane(context.Background(), testNamespace, "agent-cardvault", "k2")
	if !errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("err = %v, want ErrEnforcementUnavailable", err)
	}
	if res == nil || res.Outcome == OutcomeContained {
		t.Fatalf("result = %+v, want a non-contained outcome", res)
	}
	if res.Details["leases_revoked"] != 1 || res.Details["tokens_revoked"] != 0 {
		t.Fatalf("details leases_revoked=%v tokens_revoked=%v, want 1 and 0 (the partial truth)", res.Details["leases_revoked"], res.Details["tokens_revoked"])
	}
}
