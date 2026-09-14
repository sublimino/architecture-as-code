package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
)

// SLDP-P2-2: evidence that the database tenant claim agrees with the P1-1 principal binding.
//
// The card asks for the tenant source to be derived from the authenticated principal and never from
// a client-supplied field, and for the two to be shown to agree. "Agree" is only meaningful if the
// claim is taken from the same place the principal binding writes, and if a hostile input that
// looks like a tenant changes nothing. Both are asserted below, the second end-to-end through the
// real ProtectedRouter rather than against a hand-built context.

func TestTenantBridge_CopiesThePrincipalBindingVerbatim(t *testing.T) {
	ctx := WithTenantContext(context.Background(), TenantContext{
		TenantID:  "tenant-a",
		Principal: "spiffe://cluster.local/ns/x/sa/y",
	})
	claim, ok := TenantClaimFromRequestContext(ctx)
	if !ok {
		t.Fatal("bridge found no claim on a context carrying a tenant context")
	}
	if claim.TenantID != "tenant-a" {
		t.Errorf("tenant changed in transit: got %q", claim.TenantID)
	}
	if claim.PrincipalSubject != "spiffe://cluster.local/ns/x/sa/y" {
		t.Errorf("principal changed in transit: got %q", claim.PrincipalSubject)
	}
}

func TestTenantBridge_RefusesRatherThanDefaultsWhenUnauthenticated(t *testing.T) {
	if _, ok := TenantClaimFromRequestContext(context.Background()); ok {
		t.Error("bridge produced a claim from a context with no authenticated tenancy")
	}
	// And the context is handed back untouched, so nothing downstream can mistake a zero claim for
	// a present one.
	ctx := context.Background()
	if got := WithIdentityTenantClaim(ctx); got != ctx {
		t.Error("bridge attached something to a context that carries no tenancy")
	}
	if _, ok := identity.TenantClaimFromContext(WithIdentityTenantClaim(ctx)); ok {
		t.Error("an unauthenticated context yielded an identity tenant claim")
	}
}

func TestTenantBridge_RefusesAHalfPopulatedPrincipalBinding(t *testing.T) {
	for _, tc := range []TenantContext{
		{TenantID: "", Principal: "spiffe://cluster.local/ns/x/sa/y"},
		{TenantID: "tenant-a", Principal: ""},
		{},
	} {
		ctx := WithTenantContext(context.Background(), tc)
		if _, ok := TenantClaimFromRequestContext(ctx); ok {
			t.Errorf("bridge accepted a half-populated binding %+v; an empty field would become an empty GUC", tc)
		}
	}
}

func TestTenantBridge_RefusesTheQuarantineTenant(t *testing.T) {
	// Rows quarantined by the 006 backfill are, by construction, rows nobody is entitled to read
	// through the ordinary path. A principal binding naming that tenant is a misconfiguration, and
	// the bridge must not turn it into a working session.
	ctx := WithTenantContext(context.Background(), TenantContext{
		TenantID:  identity.QuarantineTenant,
		Principal: "spiffe://cluster.local/ns/x/sa/y",
	})
	if _, ok := TenantClaimFromRequestContext(ctx); ok {
		t.Error("bridge issued a claim for the quarantine tenant")
	}
}

// The end-to-end assertion. It drives the real ProtectedRouter, so the tenancy under test is the
// one the authorization middleware actually installs, not one this test invented.
func TestTenantBridge_DerivedClaimMatchesTheAuthenticatedPrincipalEndToEnd(t *testing.T) {
	h, _ := newTestHandlers(t)

	var (
		gotClaim identity.TenantClaim
		gotOK    bool
	)
	h.AuditReady = func(ctx context.Context) error {
		gotClaim, gotOK = identity.TenantClaimFromContext(WithIdentityTenantClaim(ctx))
		return nil
	}

	p := Principal{
		Subject:     "spiffe://cluster.local/ns/x/sa/y",
		TenantID:    "tenant-a",
		ExpiresAt:   time.Now().Add(time.Hour),
		Permissions: map[Permission]bool{PermissionHealth: true},
	}
	router, _ := NewProtectedRouter(h, staticAuthenticator{principal: p}, h.Audit, http.NotFoundHandler(), RouterOptions{})

	req := httptest.NewRequest("GET", "/readyz", nil)
	// The hostile input. If anything in the chain read a tenant off the wire, this is the value it
	// would read; the assertion below is that it does not appear.
	req.Header.Set("X-Tenant-ID", "tenant-attacker")
	req.Header.Set("X-Tenant", "tenant-attacker")

	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("request failed: %d", w.Code)
	}

	if !gotOK {
		t.Fatal("no identity tenant claim was derived on an authenticated request")
	}
	if gotClaim.TenantID != p.TenantID {
		t.Errorf("derived claim %q does not match the authenticated principal's tenant %q", gotClaim.TenantID, p.TenantID)
	}
	if gotClaim.PrincipalSubject != p.Subject {
		t.Errorf("derived claim subject %q does not match the authenticated subject %q", gotClaim.PrincipalSubject, p.Subject)
	}
	if gotClaim.TenantID == "tenant-attacker" {
		t.Fatal("a request header determined the database tenant claim")
	}
}
