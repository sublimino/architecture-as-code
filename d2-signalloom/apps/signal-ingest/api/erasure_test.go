package api

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/privacy"
)

// ---------------------------------------------------------------------------------------------
// HTTP-surface tests for the Article 17 erasure route.
//
// These drive the REAL ProtectedRouter rather than calling the handler directly, because the thing
// most worth proving here is the wiring: a gate reachable by an unregistered route, or registered
// without a permission, is not a gate. Calling the handler directly would pass in both of those
// broken worlds.
// ---------------------------------------------------------------------------------------------

type erasureTestSource struct {
	holds        []privacy.Hold
	jurisdiction bool
	err          error
}

func (s erasureTestSource) ActiveHolds(context.Context, string, string) (privacy.HoldQueryResult, error) {
	if s.err != nil {
		return privacy.HoldQueryResult{}, s.err
	}
	return privacy.HoldQueryResult{Holds: s.holds, Jurisdiction: s.jurisdiction}, nil
}

type erasureTestDestroyer struct{ calls int }

func (d *erasureTestDestroyer) DestroySubjectKeys(_ context.Context, tenantID, subjectID string) (privacy.KeyDestructionReceipt, error) {
	d.calls++
	return privacy.KeyDestructionReceipt{TenantID: tenantID, SubjectID: subjectID, KeysRemoved: 1}, nil
}

type erasureTestPseudonymiser struct{}

func (erasureTestPseudonymiser) Pseudonym(tenantID, value string) (string, error) {
	return "pseudo-" + tenantID + "-" + value, nil
}

const (
	erasureTestTenant  = "tenant-a"
	erasureTestSubject = "actor-contained"
)

func erasureHeldHold() privacy.Hold {
	return privacy.Hold{
		ID:          "quarantine:" + erasureTestSubject,
		SubjectID:   erasureTestSubject,
		TenantID:    erasureTestTenant,
		Kind:        privacy.HoldActiveContainment,
		IncidentRef: "quarantine/forged_claim",
		OpenedAt:    time.Now().UTC().Add(-time.Hour),
	}
}

// newErasureRouter builds a Handlers with a live privacy.Service and wraps it in the production
// router, authenticated as a principal holding the supplied permissions.
func newErasureRouter(t *testing.T, source privacy.IncidentSource, perms []Permission, actorIDs []string) (*ProtectedRouter, *erasureTestDestroyer, *audit.FakeWriter) {
	t.Helper()
	pubA, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	pubB, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	registry, err := privacy.NewOperatorRegistry([]privacy.Operator{
		{ID: "op-alice", PublicKey: pubA, Capabilities: []privacy.OperatorCapability{privacy.CapabilityGrantErasureOverride}},
		{ID: "op-bob", PublicKey: pubB, Capabilities: []privacy.OperatorCapability{privacy.CapabilityGrantErasureOverride}},
	})
	if err != nil {
		t.Fatalf("build registry: %v", err)
	}
	auditLog := audit.NewFakeWriter()
	destroyer := &erasureTestDestroyer{}
	svc, err := privacy.NewService(privacy.Config{
		Incidents:     source,
		Destroyer:     destroyer,
		Audit:         auditLog,
		Operators:     registry,
		Pseudonymiser: erasureTestPseudonymiser{},
	})
	if err != nil {
		t.Fatalf("build privacy service: %v", err)
	}

	h := &Handlers{Audit: auditLog, Privacy: svc}
	principal := Principal{
		Subject:     erasureTestPrincipal,
		TenantID:    erasureTestTenant,
		Permissions: map[Permission]bool{},
		ActorIDs:    map[string]bool{},
	}
	for _, p := range perms {
		principal.Permissions[p] = true
	}
	for _, a := range actorIDs {
		principal.ActorIDs[a] = true
	}
	router, err := NewProtectedRouter(h, staticAuthenticator{principal: principal}, auditLog, http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatalf("build router: %v", err)
	}
	return router, destroyer, auditLog
}

func erasurePost(t *testing.T, router *ProtectedRouter, subject string, body any) *httptest.ResponseRecorder {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal body: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/v1/privacy/erasure/"+subject, strings.NewReader(string(raw)))
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	return rec
}

// erasureTestPrincipal is the SPIFFE subject newErasureRouter authenticates as. The requester
// identity now comes from the credential, so a body that names anyone else is refused.
const erasureTestPrincipal = "spiffe://signalloom.test/ns/ops/sa/dpo"

func freshBody() ErasureRequestBody {
	return ErasureRequestBody{
		RequestID:   "req-http-001",
		RequestedBy: erasureTestPrincipal,
		RequestedAt: time.Now().UTC().Add(-time.Minute),
	}
}

// TestErasureRouteIsRegisteredAndPermissionGated is the wiring proof.
//
// It comes first because every other test in this file is meaningless if the route is not actually
// reachable through the production router.
func TestErasureRouteIsRegisteredAndPermissionGated(t *testing.T) {
	router, _, _ := newErasureRouter(t,
		erasureTestSource{jurisdiction: true},
		[]Permission{PermissionErasureRequest}, []string{"*"})

	var found *RouteRequirement
	for _, r := range router.Inventory() {
		if r.Path == "/api/v1/privacy/erasure/{id}" {
			rr := r
			found = &rr
			break
		}
	}
	if found == nil {
		t.Fatal("the erasure route is absent from the protected router inventory; " +
			"a gate that no registered route reaches is decoration")
	}
	if found.Method != http.MethodPost {
		t.Errorf("erasure route method = %q, want POST", found.Method)
	}
	if found.Permission != PermissionErasureRequest {
		t.Errorf("erasure route permission = %q, want %q", found.Permission, PermissionErasureRequest)
	}
	// Erasure must not be reachable with a general actor-write permission. If it were, every
	// principal that can edit an actor could also destroy its attribution.
	if found.Permission == PermissionActorWrite {
		t.Error("erasure is gated by the general actor-write permission")
	}
}

func TestErasureRouteRefusesPrincipalWithoutThePermission(t *testing.T) {
	router, destroyer, _ := newErasureRouter(t,
		erasureTestSource{jurisdiction: true},
		[]Permission{PermissionActorWrite, PermissionActorRead}, []string{"*"})

	rec := erasurePost(t, router, erasureTestSubject, freshBody())
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403 for a principal lacking %q", rec.Code, PermissionErasureRequest)
	}
	if destroyer.calls != 0 {
		t.Fatal("key material was reached by an unauthorised principal")
	}
}

func TestErasureRouteIsActorScoped(t *testing.T) {
	// The principal may erase actor-other, but requests actor-contained.
	router, destroyer, _ := newErasureRouter(t,
		erasureTestSource{jurisdiction: true},
		[]Permission{PermissionErasureRequest}, []string{"actor-other"})

	rec := erasurePost(t, router, erasureTestSubject, freshBody())
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403 for an out-of-scope actor", rec.Code)
	}
	if destroyer.calls != 0 {
		t.Fatal("key material was reached for an actor outside the principal's binding")
	}
}

// TestErasureRouteRefusesContainedActorWith409 is the abuse case at the HTTP boundary.
func TestErasureRouteRefusesContainedActorWith409(t *testing.T) {
	router, destroyer, _ := newErasureRouter(t,
		erasureTestSource{jurisdiction: true, holds: []privacy.Hold{erasureHeldHold()}},
		[]Permission{PermissionErasureRequest}, []string{"*"})

	rec := erasurePost(t, router, erasureTestSubject, freshBody())
	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409 Conflict for a legal hold; body: %s", rec.Code, rec.Body.String())
	}
	if destroyer.calls != 0 {
		t.Fatal("key material was reached for an actor under active containment")
	}

	var resp ErasureResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v (body %s)", err, rec.Body.String())
	}
	if resp.Permitted {
		t.Error("a 409 response reports permitted=true")
	}
	if resp.Outcome != privacy.OutcomeRefusedLegalHold {
		t.Errorf("outcome = %q, want %q", resp.Outcome, privacy.OutcomeRefusedLegalHold)
	}
	if len(resp.HoldIDs) == 0 {
		t.Error("the 409 body does not name the blocking hold; an operator cannot act on it")
	}
	if resp.RequiredGround != privacy.GroundLegalClaims {
		t.Errorf("the 409 body does not name the Article 17(3) ground: %q", resp.RequiredGround)
	}
	// Remediation must be specific enough to act on. Asserting it is non-empty would pass for the
	// string "refused", which is exactly the useless answer this field exists to prevent.
	for _, want := range []string{"Article 17(3)(e)", "DISTINCT", "requester"} {
		if !strings.Contains(resp.Remediation, want) {
			t.Errorf("remediation does not mention %q: %q", want, resp.Remediation)
		}
	}
	// The cleartext subject must not leak into the body's pseudonym field.
	if resp.SubjectPseudonym == erasureTestSubject {
		t.Error("the response carries the cleartext subject as its pseudonym")
	}
}

// TestErasureRouteDistinguishesHoldFromOutage is the status-code discrimination test.
//
// 409 and 503 demand different operator responses: one is "get two signatures", the other is "page
// whoever owns the incident database". Collapsing them into one code makes the control
// indistinguishable from an outage, and an operator who cannot tell them apart routes around it.
func TestErasureRouteDistinguishesHoldFromOutage(t *testing.T) {
	cases := map[string]struct {
		source     privacy.IncidentSource
		wantStatus int
		wantIn     string
	}{
		"active legal hold": {
			source:     erasureTestSource{jurisdiction: true, holds: []privacy.Hold{erasureHeldHold()}},
			wantStatus: http.StatusConflict,
			wantIn:     "legal hold",
		},
		"incident source down": {
			source:     erasureTestSource{err: errors.New("incident db unreachable")},
			wantStatus: http.StatusServiceUnavailable,
			wantIn:     "outage, not a policy decision",
		},
		"no source has jurisdiction": {
			source:     erasureTestSource{jurisdiction: false},
			wantStatus: http.StatusServiceUnavailable,
			wantIn:     "incident source",
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			router, destroyer, _ := newErasureRouter(t, tc.source,
				[]Permission{PermissionErasureRequest}, []string{"*"})
			rec := erasurePost(t, router, erasureTestSubject, freshBody())
			if rec.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d; body: %s", rec.Code, tc.wantStatus, rec.Body.String())
			}
			if destroyer.calls != 0 {
				t.Fatal("key material was reached on a refusal path")
			}
			var resp ErasureResponse
			if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
				t.Fatalf("decode response: %v", err)
			}
			if !strings.Contains(resp.Remediation, tc.wantIn) {
				t.Errorf("remediation %q does not contain %q", resp.Remediation, tc.wantIn)
			}
		})
	}
}

// TestErasureRouteUnconfiguredGateRefuses covers the nil-Privacy deployment.
//
// With no gate configured no erasure may proceed. The alternative — erasing when unconfigured — is
// the exact defect the gate exists for, so this asserts the direction of the default.
func TestErasureRouteUnconfiguredGateRefuses(t *testing.T) {
	auditLog := audit.NewFakeWriter()
	h := &Handlers{Audit: auditLog} // Privacy deliberately nil
	principal := Principal{
		Subject:     erasureTestPrincipal,
		TenantID:    erasureTestTenant,
		Permissions: map[Permission]bool{PermissionErasureRequest: true},
		ActorIDs:    map[string]bool{"*": true},
	}
	router, err := NewProtectedRouter(h, staticAuthenticator{principal: principal}, auditLog, http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatalf("build router: %v", err)
	}
	rec := erasurePost(t, router, erasureTestSubject, freshBody())
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503 when no erasure gate is configured", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "not configured") {
		t.Errorf("body does not explain that the gate is unconfigured: %s", rec.Body.String())
	}
}

func TestErasureRouteRejectsMalformedInput(t *testing.T) {
	router, destroyer, _ := newErasureRouter(t,
		erasureTestSource{jurisdiction: true},
		[]Permission{PermissionErasureRequest}, []string{"*"})

	t.Run("malformed json is 400 not 500", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/privacy/erasure/"+erasureTestSubject, strings.NewReader("{not json"))
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400", rec.Code)
		}
	})

	t.Run("missing requested_at is 400", func(t *testing.T) {
		body := freshBody()
		body.RequestedAt = time.Time{}
		rec := erasurePost(t, router, erasureTestSubject, body)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400 for a zero requested_at", rec.Code)
		}
	})

	t.Run("stale request is 409", func(t *testing.T) {
		body := freshBody()
		body.RequestedAt = time.Now().UTC().Add(-privacy.MaxRequestAge - time.Hour)
		rec := erasurePost(t, router, erasureTestSubject, body)
		if rec.Code != http.StatusConflict {
			t.Fatalf("status = %d, want 409 for a stale request", rec.Code)
		}
	})

	t.Run("GET is rejected by the router", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/privacy/erasure/"+erasureTestSubject, nil)
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)
		if rec.Code == http.StatusOK {
			t.Fatal("GET on the erasure route succeeded")
		}
	})

	if destroyer.calls != 0 {
		t.Fatal("key material was reached on a malformed-input path")
	}
}

// TestErasureRouteRequesterComesFromTheCredentialNotTheBody covers a defect that the original
// suite passed straight through.
//
// THE DEFECT: the handler used body.RequestedBy when present and fell back to the authenticated
// principal only when it was omitted. RequestedBy is the SOLE input to the requester-is-approver
// check, so an operator holding both erasure:request and erasure:grant_override could POST
// `"requested_by": "nobody"`, co-sign with one colleague, and have the separation-of-duties check
// evaluate `"alice" == "nobody"` → false. Dual authorisation dropped from three humans to two, at
// the client's choosing.
//
// The original test set RequestedBy to "" and exercised only the safe fallback branch, which is
// why it was green. This exercises the branch that actually ran.
func TestErasureRouteRequesterComesFromTheCredentialNotTheBody(t *testing.T) {

	t.Run("a spoofed requester is refused", func(t *testing.T) {
		router, destroyer, _ := newErasureRouter(t,
			erasureTestSource{jurisdiction: true},
			[]Permission{PermissionErasureRequest}, []string{"*"})

		body := freshBody()
		body.RequestedBy = "nobody" // not the authenticated principal
		rec := erasurePost(t, router, erasureTestSubject, body)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400 for a requested_by that is not the authenticated principal; body: %s",
				rec.Code, rec.Body.String())
		}
		if !strings.Contains(rec.Body.String(), "authenticated principal") {
			t.Errorf("the refusal does not explain why: %s", rec.Body.String())
		}
		if destroyer.calls != 0 {
			t.Fatal("key material was reached by a request that spoofed its own requester identity")
		}
	})

	t.Run("an omitted requester defaults to the principal", func(t *testing.T) {
		router, destroyer, _ := newErasureRouter(t,
			erasureTestSource{jurisdiction: true},
			[]Permission{PermissionErasureRequest}, []string{"*"})

		body := freshBody()
		body.RequestedBy = ""
		rec := erasurePost(t, router, erasureTestSubject, body)
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200; body: %s", rec.Code, rec.Body.String())
		}
		if destroyer.calls != 1 {
			t.Fatalf("destroyer called %d times, want 1", destroyer.calls)
		}
	})

	// The discriminating positive: supplying the CORRECT principal must still work, or the fix
	// would pass for a handler that rejected every populated requested_by.
	t.Run("a matching requester is accepted", func(t *testing.T) {
		router, destroyer, _ := newErasureRouter(t,
			erasureTestSource{jurisdiction: true},
			[]Permission{PermissionErasureRequest}, []string{"*"})

		body := freshBody()
		body.RequestedBy = erasureTestPrincipal
		rec := erasurePost(t, router, erasureTestSubject, body)
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200 when requested_by matches the principal; body: %s", rec.Code, rec.Body.String())
		}
		if destroyer.calls != 1 {
			t.Fatalf("destroyer called %d times, want 1", destroyer.calls)
		}
	})
}

// TestErasureRouteUnheldSubjectSucceeds is the discriminating positive.
//
// Without it, every refusal test above would pass for a handler that returns 409 unconditionally.
func TestErasureRouteUnheldSubjectSucceeds(t *testing.T) {
	router, destroyer, auditLog := newErasureRouter(t,
		erasureTestSource{jurisdiction: true},
		[]Permission{PermissionErasureRequest}, []string{"*"})

	rec := erasurePost(t, router, erasureTestSubject, freshBody())
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body: %s", rec.Code, rec.Body.String())
	}
	if destroyer.calls != 1 {
		t.Fatalf("destroyer called %d times, want 1", destroyer.calls)
	}
	var resp ErasureResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !resp.Permitted {
		t.Error("a 200 response reports permitted=false")
	}
	if resp.Receipt == nil {
		t.Error("a permitted erasure carries no destruction receipt")
	}
	if len(auditLog.EventsByType(audit.EventPartitionDropped)) != 1 {
		t.Error("the permitted erasure was not recorded in the audit trail")
	}
}
