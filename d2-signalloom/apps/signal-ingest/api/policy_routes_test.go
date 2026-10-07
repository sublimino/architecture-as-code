// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/policy"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// Tokens for the review API's own key matrix. Each is >= 32 bytes (the static-key floor) and
// distinct, so a test can never pass because two keys collided.
const (
	policyReaderToken   = "policyReaderTenantAkey000000000000000000000"
	policyReviewerToken = "policyReviewerTenantAkey0000000000000000000"
	policyCrossToken    = "policyCrossTenantReaderKey00000000000000000"
	policyGatewayToken  = "policyGatewayActsForTenantsKey00000000000000"
	// policyActForReaderToken has act-for-tenant and policy:read, but lacks policy:review.
	policyActForReaderToken = "policyActForReaderNoReviewKey000000000000"
	policyReviewer2Token    = "policyReviewer2TenantAKey0000000000000000"
	// evidenceReaderToken stands in for the shipped sldc-evidence-reader key: observations:read
	// and nothing else. The contract's explicit requirement is that this key cannot review.
	evidenceReaderToken = "policyEvidenceReaderObsReadOnlyKey000000000"
)

const policyReviewFixedNow = "2026-10-05T11:22:33Z"

// policyAPIFixture is the review API under the production authentication chain.
//
// The real ActingTenantGate in front of the real ProtectedRouter over real static keys, because
// every interesting property of these routes is a property of that chain: which permission opens
// which route, which tenant a principal sees, and whose name ends up on a verdict. A naked mux
// would test the handler bodies and none of that.
func policyAPIFixture(t *testing.T) (http.Handler, *Handlers) {
	t.Helper()
	delegate, _, _ := testJWTDelegate(t)
	expires := time.Now().Add(24 * time.Hour)
	readOnly := []Permission{PermissionObservationRead}
	a, err := NewStaticKeyAuthenticator([]StaticBearerConfig{
		{Name: "policy-reader", Token: policyReaderToken, Subject: "static-key/policy-reader",
			TenantID: "tenant-a", Permissions: []Permission{PermissionPolicyRead}, ExpiresAt: expires},
		{Name: "policy-reviewer", Token: policyReviewerToken, Subject: "static-key/policy-reviewer",
			TenantID: "tenant-a", Permissions: []Permission{PermissionPolicyRead, PermissionPolicyReview}, ExpiresAt: expires},
		{Name: "policy-reviewer-2", Token: policyReviewer2Token, Subject: "static-key/policy-reviewer-2",
			TenantID: "tenant-a", Permissions: []Permission{PermissionPolicyRead, PermissionPolicyReview}, ExpiresAt: expires},
		{Name: "policy-cross", Token: policyCrossToken, Subject: "static-key/policy-cross",
			TenantID: "tenant-a", Permissions: []Permission{PermissionPolicyRead, PermissionPolicyReview, PermissionCrossTenantRead}, ExpiresAt: expires},
		{Name: "policy-gateway", Token: policyGatewayToken, Subject: "static-key/fe-signalloom-gateway",
			TenantID: "fe-signalloom", Permissions: []Permission{PermissionActForTenant, PermissionCrossTenantRead,
				PermissionPolicyRead, PermissionPolicyReview}, ExpiresAt: expires},
		{Name: "policy-act-for-reader", Token: policyActForReaderToken, Subject: "static-key/policy-act-for-reader",
			TenantID: "fe-signalloom", Permissions: []Permission{PermissionActForTenant, PermissionPolicyRead}, ExpiresAt: expires},
		{Name: "evidence-reader", Token: evidenceReaderToken, Subject: "static-key/sldc-evidence-reader",
			TenantID: "tenant-a", Permissions: readOnly, ExpiresAt: expires},
	}, delegate)
	if err != nil {
		t.Fatal(err)
	}

	aw := audit.NewFakeWriter()
	s := store.NewMemoryStore()
	e, err := correlation.NewEngine(s)
	if err != nil {
		t.Fatal(err)
	}
	fixed, err := time.Parse(time.RFC3339, policyReviewFixedNow)
	if err != nil {
		t.Fatal(err)
	}
	h := &Handlers{Store: s, Engine: e, Audit: aw, now: func() time.Time { return fixed }}
	seedPolicyFixture(t, h)

	router, err := NewProtectedRouter(h, a, aw, http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatal(err)
	}
	return a.ActingTenantGate(router), h
}

// seedPolicyFixture writes one raw observation, two findings and one decision per tenant, plus a
// finding/decision pair for tenant-b, so every tenancy assertion has something to be wrong about.
func seedPolicyFixture(t *testing.T, h *Handlers) {
	t.Helper()
	base := time.Now().UTC().Add(-2 * time.Minute)
	rows := []model.Observation{
		{ID: "raw-a", Timestamp: base, Layer: model.LayerCloudControlPlane, Fidelity: model.FidelityDefinitive,
			Source: "aws:cloudtrail", Confidence: 1, RawEvidenceRef: "s3://b/k", Description: "raw",
			Labels: map[string]string{policy.TenantLabel: "tenant-a"}},
		policyFinding("find-a1", "tenant-a", base.Add(10*time.Second)),
		policyFinding("find-a2", "tenant-a", base.Add(20*time.Second)),
		policyDecision("dec-a1", "tenant-a", base.Add(30*time.Second), []string{"find-a1", "find-a2"}),
		policyFinding("find-b1", "tenant-b", base.Add(15*time.Second)),
		policyDecision("dec-b1", "tenant-b", base.Add(35*time.Second), []string{"find-b1"}),
	}
	if err := h.Store.Append(context.Background(), rows); err != nil {
		t.Fatal(err)
	}
}

func policyFinding(id, tenant string, ts time.Time) model.Observation {
	return model.Observation{
		ID: id, Timestamp: ts, Layer: model.LayerIdentityAuth, Fidelity: model.FidelitySuggestive,
		Source: obscel.SourceFinding, Confidence: 0.4, ActorHint: "agent-" + tenant,
		RawEvidenceRef: "raw-a", Description: "policy finding",
		Labels: map[string]string{
			policy.TenantLabel: tenant, policy.LabelRuleID: "iam-priv-change",
			policy.LabelBundleID: "bundle-x", policy.LabelBundleVersion: "1.0.0",
			policy.LabelSeverity: "high", policy.LabelMode: "enforce",
			policy.LabelSourceObsID: "raw-a",
		},
	}
}

func policyDecision(id, tenant string, ts time.Time, findingIDs []string) model.Observation {
	return model.Observation{
		ID: id, Timestamp: ts, Layer: model.LayerIdentityAuth, Fidelity: model.FidelitySuggestive,
		Source: obscel.SourceDecision, Confidence: 0.4, ActorHint: "agent-" + tenant,
		RawEvidenceRef: strings.Join(findingIDs, ","), Description: "policy decision",
		Labels: map[string]string{
			policy.TenantLabel: tenant, policy.LabelRuleID: "iam-priv-change",
			policy.LabelBundleID: "bundle-x", policy.LabelBundleVersion: "1.0.0",
			policy.LabelSeverity: "critical", policy.LabelMode: "enforce",
			policy.LabelWindowID: "iam-change-burst", policy.LabelCount: "2",
			policy.LabelFindingIDs: strings.Join(findingIDs, ","),
		},
	}
}

// policyRequest issues one request with the given key, decoding into out when out is non-nil.
func policyRequest(t *testing.T, router http.Handler, method, path, token, body string, headers map[string]string, out any) int {
	t.Helper()
	var r *http.Request
	if body == "" {
		r = httptest.NewRequest(method, path, nil)
	} else {
		r = httptest.NewRequest(method, path, strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
	}
	r.Header.Set("Authorization", "Bearer "+token)
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)
	if out != nil && w.Body.Len() > 0 {
		if err := json.Unmarshal(w.Body.Bytes(), out); err != nil {
			t.Fatalf("%s %s: body %q is not the expected JSON: %v", method, path, w.Body.String(), err)
		}
	}
	return w.Code
}

// --- permissions -----------------------------------------------------------------------------

// The contract's load-bearing permission assertion: the shipped evidence-reader key holds
// observations:read and must reach NEITHER the policy feeds nor the review write. A key that can
// read the evidence must not be able to put a verdict into it.
func TestEvidenceReaderKeyCannotReadOrReviewPolicy(t *testing.T) {
	router, _ := policyAPIFixture(t)
	for _, tc := range []struct{ method, path, body string }{
		{http.MethodGet, "/api/v1/policy/findings", ""},
		{http.MethodGet, "/api/v1/policy/decisions", ""},
		{http.MethodGet, "/api/v1/policy/rates", ""},
		{http.MethodPost, "/api/v1/policy/decisions/dec-a1/review", `{"verdict":"true_positive","note":"n"}`},
	} {
		code := policyRequest(t, router, tc.method, tc.path, evidenceReaderToken, tc.body, nil, nil)
		if code != http.StatusForbidden {
			t.Errorf("%s %s with observations:read only returned %d, want 403", tc.method, tc.path, code)
		}
	}
	// And the review did not land despite the refusal.
	var decisions []decisionView
	policyRequest(t, router, http.MethodGet, "/api/v1/policy/decisions", policyReaderToken, "", nil, &decisions)
	for _, d := range decisions {
		if d.Review != nil {
			t.Errorf("decision %s carries a review after a 403 POST", d.ID)
		}
	}
}

// policy:read opens the three feeds and NOT the write. This is the split that makes a reviewer a
// distinct role from a reader rather than a label on the same one.
func TestPolicyReadDoesNotGrantReview(t *testing.T) {
	router, _ := policyAPIFixture(t)
	for _, path := range []string{"/api/v1/policy/findings", "/api/v1/policy/decisions", "/api/v1/policy/rates"} {
		if code := policyRequest(t, router, http.MethodGet, path, policyReaderToken, "", nil, nil); code != http.StatusOK {
			t.Errorf("GET %s with policy:read returned %d, want 200", path, code)
		}
	}
	code := policyRequest(t, router, http.MethodPost, "/api/v1/policy/decisions/dec-a1/review",
		policyReaderToken, `{"verdict":"true_positive","note":"n"}`, nil, nil)
	if code != http.StatusForbidden {
		t.Errorf("POST review with policy:read only returned %d, want 403", code)
	}
}

// Even when a caller possesses PermissionActForTenant and can impersonate any tenant to read
// feeds, without PermissionPolicyReview they cannot submit a review verdict.
func TestPolicyReviewRequiresTheReviewPermissionEvenWithActForTenant(t *testing.T) {
	router, _ := policyAPIFixture(t)
	headers := map[string]string{ActingTenantHeader: "tenant-a"}
	// Reading feeds succeeds
	for _, path := range []string{"/api/v1/policy/findings", "/api/v1/policy/decisions", "/api/v1/policy/rates"} {
		if code := policyRequest(t, router, http.MethodGet, path, policyActForReaderToken, "", headers, nil); code != http.StatusOK {
			t.Errorf("GET %s with policy:read + act-for-tenant returned %d, want 200", path, code)
		}
	}
	// Posting a review fails with 403 Forbidden
	code := policyRequest(t, router, http.MethodPost, "/api/v1/policy/decisions/dec-a1/review",
		policyActForReaderToken, `{"verdict":"true_positive","note":"unauthorized review"}`, headers, nil)
	if code != http.StatusForbidden {
		t.Errorf("POST review with act-for-tenant but no policy:review returned %d, want 403", code)
	}
}

func TestPolicyRoutesRejectAnonymousRequests(t *testing.T) {
	router, _ := policyAPIFixture(t)
	for _, tc := range []struct{ method, path string }{
		{http.MethodGet, "/api/v1/policy/findings"},
		{http.MethodGet, "/api/v1/policy/decisions"},
		{http.MethodGet, "/api/v1/policy/rates"},
		{http.MethodPost, "/api/v1/policy/decisions/dec-a1/review"},
	} {
		r := httptest.NewRequest(tc.method, tc.path, nil)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		if w.Code != http.StatusUnauthorized {
			t.Errorf("%s %s unauthenticated returned %d, want 401", tc.method, tc.path, w.Code)
		}
	}
}

// --- findings --------------------------------------------------------------------------------

func TestPolicyFindingsProjectsTheContractFields(t *testing.T) {
	router, _ := policyAPIFixture(t)
	var got []findingView
	if code := policyRequest(t, router, http.MethodGet, "/api/v1/policy/findings?window=30m",
		policyReaderToken, "", nil, &got); code != http.StatusOK {
		t.Fatalf("status %d", code)
	}
	if len(got) != 2 {
		t.Fatalf("got %d findings, want tenant-a's 2: %+v", len(got), got)
	}
	// Newest first.
	if !got[0].Timestamp.After(got[1].Timestamp) {
		t.Errorf("findings are not sorted newest-first: %v then %v", got[0].Timestamp, got[1].Timestamp)
	}
	f := got[0]
	if f.ID != "find-a2" || f.TenantID != "tenant-a" || f.Actor != "agent-tenant-a" ||
		f.Layer != string(model.LayerIdentityAuth) || f.SourceObservationID != "raw-a" ||
		f.RuleID != "iam-priv-change" || f.BundleID != "bundle-x" || f.BundleVersion != "1.0.0" ||
		f.Severity != "high" || f.Mode != "enforce" {
		t.Errorf("finding projection is wrong: %+v", f)
	}
	if f.Labels[policy.TenantLabel] != "tenant-a" {
		t.Errorf("labels not passed through: %v", f.Labels)
	}
}

// Only findings. A feed that also carried the raw observation it was derived from, or the
// decision it fed, would make the review queue uncountable.
func TestPolicyFindingsExcludesEveryOtherSource(t *testing.T) {
	router, _ := policyAPIFixture(t)
	var got []findingView
	policyRequest(t, router, http.MethodGet, "/api/v1/policy/findings", policyReaderToken, "", nil, &got)
	for _, f := range got {
		if !strings.HasPrefix(f.ID, "find-") {
			t.Errorf("findings feed returned a non-finding row: %+v", f)
		}
	}
}

func TestPolicyFindingsEmptyWindowIsAnEmptyArrayNotNull(t *testing.T) {
	router, _ := policyAPIFixture(t)
	r := httptest.NewRequest(http.MethodGet, "/api/v1/policy/findings?since=2030-01-01T00:00:00Z", nil)
	r.Header.Set("Authorization", "Bearer "+policyReaderToken)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)
	if got := strings.TrimSpace(w.Body.String()); got != "[]" {
		t.Errorf("empty findings serialised as %q, want []; a dashboard dereferencing null crashes", got)
	}
}

// --- windows, limits, bad input --------------------------------------------------------------

func TestPolicyWindowAndLimitValidation(t *testing.T) {
	router, _ := policyAPIFixture(t)
	for name, query := range map[string]string{
		"unknown window":    "?window=7m",
		"duration window":   "?window=1h30m",
		"bad since":         "?since=yesterday",
		"window and since":  "?window=5m&since=" + policyReviewFixedNow,
		"limit zero":        "?limit=0",
		"limit negative":    "?limit=-1",
		"limit not numeric": "?limit=many",
		"bad tenant shape":  "?tenant=Tenant_A",
	} {
		code := policyRequest(t, router, http.MethodGet, "/api/v1/policy/findings"+query, policyCrossToken, "", nil, nil)
		if code != http.StatusBadRequest {
			t.Errorf("%s (%s) returned %d, want 400", name, query, code)
		}
	}
	// Every advertised window value is accepted.
	for _, win := range []string{"5m", "10m", "30m", "90m"} {
		if code := policyRequest(t, router, http.MethodGet, "/api/v1/policy/findings?window="+win,
			policyReaderToken, "", nil, nil); code != http.StatusOK {
			t.Errorf("window=%s returned %d, want 200", win, code)
		}
	}
}

// The limit is capped TWICE and the lower cap wins. Stated as its own test because it is the one
// place these routes do not do what the dashboard contract says.
//
// The contract asks for limit <= 500, and the handler enforces that (MaxPolicyLimit). But the
// three read routes are enumeration-budgeted, and ProtectedRouter.applyEnumeration refuses any
// limit above RouterOptions.MaxPageSize -- 100 by default, which is what production configures --
// BEFORE the handler runs. So the effective ceiling is 100 unless an operator raises MaxPageSize,
// and 101..500 is a 400 from the router rather than a 200 from the handler.
//
// Keeping the budget was the deliberate choice. It exists to stop an authenticated principal
// inventorying the estate through a list route, and a feed of every detection is exactly the list
// route it was built for; dropping enumeration to reach the number in the contract would have
// traded a real control for a parameter value.
func TestPolicyLimitIsCappedByTheEnumerationBudgetBeforeTheHandler(t *testing.T) {
	router, _ := policyAPIFixture(t)
	if code := policyRequest(t, router, http.MethodGet, "/api/v1/policy/findings?limit=100",
		policyReaderToken, "", nil, nil); code != http.StatusOK {
		t.Errorf("limit=100 (the router's default MaxPageSize) returned %d, want 200", code)
	}
	if code := policyRequest(t, router, http.MethodGet, "/api/v1/policy/findings?limit=101",
		policyReaderToken, "", nil, nil); code != http.StatusBadRequest {
		t.Errorf("limit=101 returned %d, want the router's 400", code)
	}
	// Raise MaxPageSize and the handler's own 500 becomes the operative ceiling, so the contract
	// value is reachable by configuration rather than by a code change.
	delegate, _, _ := testJWTDelegate(t)
	a, err := NewStaticKeyAuthenticator([]StaticBearerConfig{
		{Name: "policy-reader", Token: policyReaderToken, Subject: "static-key/policy-reader",
			TenantID: "tenant-a", Permissions: []Permission{PermissionPolicyRead},
			ExpiresAt: time.Now().Add(time.Hour)},
	}, delegate)
	if err != nil {
		t.Fatal(err)
	}
	h, _ := newTestHandlers(t)
	wide, err := NewProtectedRouter(h, a, audit.NewFakeWriter(), http.NotFoundHandler(),
		RouterOptions{MaxPageSize: MaxPolicyLimit, PrincipalBudget: 10000})
	if err != nil {
		t.Fatal(err)
	}
	if code := policyRequest(t, wide, http.MethodGet, "/api/v1/policy/findings?limit=500",
		policyReaderToken, "", nil, nil); code != http.StatusOK {
		t.Errorf("limit=500 with MaxPageSize=500 returned %d, want 200", code)
	}
	if code := policyRequest(t, wide, http.MethodGet, "/api/v1/policy/findings?limit=501",
		policyReaderToken, "", nil, nil); code != http.StatusBadRequest {
		t.Errorf("limit=501 returned %d, want 400 from MaxPolicyLimit", code)
	}
}

// The window must actually exclude. A window parameter that parsed and then did nothing would be
// the most plausible silent defect in these routes: every assertion above would still pass.
func TestPolicyWindowExcludesOlderRows(t *testing.T) {
	router, h := policyAPIFixture(t)
	old := policyFinding("find-old", "tenant-a", time.Now().UTC().Add(-45*time.Minute))
	if err := h.Store.Append(context.Background(), []model.Observation{old}); err != nil {
		t.Fatal(err)
	}
	var wide, narrow []findingView
	policyRequest(t, router, http.MethodGet, "/api/v1/policy/findings?window=90m", policyReaderToken, "", nil, &wide)
	policyRequest(t, router, http.MethodGet, "/api/v1/policy/findings?window=5m", policyReaderToken, "", nil, &narrow)
	if len(wide) != 3 {
		t.Errorf("window=90m returned %d findings, want 3", len(wide))
	}
	if len(narrow) != 2 {
		t.Errorf("window=5m returned %d findings, want 2 (the 45-minute-old row must be excluded)", len(narrow))
	}
}

func TestPolicyLimitTruncatesToTheNewest(t *testing.T) {
	router, _ := policyAPIFixture(t)
	var got []findingView
	policyRequest(t, router, http.MethodGet, "/api/v1/policy/findings?limit=1", policyReaderToken, "", nil, &got)
	if len(got) != 1 {
		t.Fatalf("limit=1 returned %d rows", len(got))
	}
	if got[0].ID != "find-a2" {
		t.Errorf("limit kept %s, want the newest finding find-a2", got[0].ID)
	}
}

// --- tenancy ---------------------------------------------------------------------------------

func TestPolicyFeedsAreTenantScoped(t *testing.T) {
	router, _ := policyAPIFixture(t)
	var aFindings []findingView
	policyRequest(t, router, http.MethodGet, "/api/v1/policy/findings?window=90m", policyReaderToken, "", nil, &aFindings)
	for _, f := range aFindings {
		if f.TenantID != "tenant-a" {
			t.Errorf("tenant-a's key saw tenant %q", f.TenantID)
		}
	}
	var allFindings []findingView
	policyRequest(t, router, http.MethodGet, "/api/v1/policy/findings?window=90m", policyCrossToken, "", nil, &allFindings)
	if len(allFindings) <= len(aFindings) {
		t.Errorf("cross-tenant reader saw %d findings, scoped reader saw %d: the grant did nothing",
			len(allFindings), len(aFindings))
	}
}

func TestPolicyTenantParameterNarrowsOnlyForCrossTenantReaders(t *testing.T) {
	router, _ := policyAPIFixture(t)
	// A cross-tenant reader may pick one tenant out of the set.
	var picked []findingView
	if code := policyRequest(t, router, http.MethodGet, "/api/v1/policy/findings?tenant=tenant-b&window=90m",
		policyCrossToken, "", nil, &picked); code != http.StatusOK {
		t.Fatalf("cross-tenant reader naming tenant-b got %d", code)
	}
	if len(picked) != 1 || picked[0].TenantID != "tenant-b" {
		t.Errorf("tenant=tenant-b returned %+v, want only tenant-b's finding", picked)
	}
	// A scoped principal naming its own tenant is a no-op, not an error: a dashboard should not
	// have to know whether its user is a superadmin before building a URL.
	if code := policyRequest(t, router, http.MethodGet, "/api/v1/policy/findings?tenant=tenant-a",
		policyReaderToken, "", nil, nil); code != http.StatusOK {
		t.Errorf("scoped reader naming its OWN tenant got %d, want 200", code)
	}
	// Naming another tenant is a refusal, never an empty list. An empty list would read as
	// "tenant-b has no findings", which is a false statement about another tenant's estate.
	for _, path := range []string{
		"/api/v1/policy/findings?tenant=tenant-b",
		"/api/v1/policy/decisions?tenant=tenant-b",
		"/api/v1/policy/rates?tenant=tenant-b",
	} {
		if code := policyRequest(t, router, http.MethodGet, path, policyReaderToken, "", nil, nil); code != http.StatusForbidden {
			t.Errorf("%s as a scoped reader returned %d, want 403", path, code)
		}
	}
}

// --- decisions -------------------------------------------------------------------------------

func TestPolicyDecisionsProjectsTheContractFields(t *testing.T) {
	router, _ := policyAPIFixture(t)
	var got []decisionView
	if code := policyRequest(t, router, http.MethodGet, "/api/v1/policy/decisions",
		policyReaderToken, "", nil, &got); code != http.StatusOK {
		t.Fatalf("status %d", code)
	}
	if len(got) != 1 {
		t.Fatalf("got %d decisions, want 1: %+v", len(got), got)
	}
	d := got[0]
	if d.ID != "dec-a1" || d.TenantID != "tenant-a" || d.Actor != "agent-tenant-a" ||
		d.WindowID != "iam-change-burst" || d.RuleID != "iam-priv-change" ||
		d.BundleID != "bundle-x" || d.BundleVersion != "1.0.0" ||
		d.Severity != "critical" || d.Mode != "enforce" || d.Count != 2 {
		t.Errorf("decision projection is wrong: %+v", d)
	}
	if len(d.FindingIDs) != 2 || d.FindingIDs[0] != "find-a1" || d.FindingIDs[1] != "find-a2" {
		t.Errorf("finding_ids = %v, want [find-a1 find-a2]", d.FindingIDs)
	}
	if d.Review != nil {
		t.Errorf("an unreviewed decision carries review %+v, want null", d.Review)
	}
}

func TestPolicyDecisionsFindingIDsIsAnArrayNotNull(t *testing.T) {
	router, h := policyAPIFixture(t)
	bare := policyDecision("dec-bare", "tenant-a", time.Now().UTC(), nil)
	delete(bare.Labels, policy.LabelFindingIDs)
	bare.Labels[policy.LabelCount] = "not-a-number"
	if err := h.Store.Append(context.Background(), []model.Observation{bare}); err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(http.MethodGet, "/api/v1/policy/decisions", nil)
	r.Header.Set("Authorization", "Bearer "+policyReaderToken)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)
	if strings.Contains(w.Body.String(), `"finding_ids":null`) {
		t.Errorf("a decision with no finding_ids label serialised null: %s", w.Body.String())
	}
	// A malformed count must not fail the whole feed: the decision is real and still needs reviewing.
	var got []decisionView
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("feed is not decodable: %v", err)
	}
	if len(got) != 2 {
		t.Errorf("a malformed count label dropped a decision from the feed: got %d, want 2", len(got))
	}
}

// --- review: the write -----------------------------------------------------------------------

func recordReview(t *testing.T, router http.Handler, token, decisionID, body string, headers map[string]string) (int, reviewResponse) {
	t.Helper()
	var out reviewResponse
	code := policyRequest(t, router, http.MethodPost, "/api/v1/policy/decisions/"+decisionID+"/review",
		token, body, headers, &out)
	return code, out
}

func TestPolicyReviewRecordsAVerdictAndJoinsItToTheDecision(t *testing.T) {
	router, h := policyAPIFixture(t)
	code, got := recordReview(t, router, policyReviewerToken, "dec-a1",
		`{"verdict":"false_positive","note":"known nightly batch job"}`, nil)
	if code != http.StatusCreated {
		t.Fatalf("POST review returned %d, want 201", code)
	}
	if got.DecisionID != "dec-a1" || got.Verdict != "false_positive" ||
		got.Note != "known nightly batch job" || got.Reviewer != "static-key/policy-reviewer" {
		t.Errorf("201 body is wrong: %+v", got)
	}
	want := policy.ReviewID("tenant-a", "dec-a1", "static-key/policy-reviewer", "false_positive", "known nightly batch job")
	if got.ID != want {
		t.Errorf("review id %s, want the derived %s", got.ID, want)
	}
	fixed, _ := time.Parse(time.RFC3339, policyReviewFixedNow)
	if !got.ReviewedAt.Equal(fixed) {
		t.Errorf("reviewed_at %v, want the server clock %v", got.ReviewedAt, fixed)
	}

	// It is in the store as an observation, not in a side table.
	rows, err := h.Store.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatal(err)
	}
	var stored *model.Observation
	for i := range rows {
		if rows[i].ID == want {
			stored = &rows[i]
		}
	}
	if stored == nil {
		t.Fatal("the review is not in the signal store")
	}
	if stored.Source != policy.SourceReview || stored.Layer != model.LayerIdentityAuth {
		t.Errorf("stored review has source %q layer %q, want policy_review and the decision's layer",
			stored.Source, stored.Layer)
	}
	if stored.Labels[policy.LabelReviewer] != "static-key/policy-reviewer" ||
		stored.Labels[policy.LabelDecisionID] != "dec-a1" ||
		stored.Labels[policy.TenantLabel] != "tenant-a" {
		t.Errorf("stored review labels are wrong: %v", stored.Labels)
	}

	// And the decisions feed now shows it.
	var decisions []decisionView
	policyRequest(t, router, http.MethodGet, "/api/v1/policy/decisions", policyReviewerToken, "", nil, &decisions)
	if len(decisions) != 1 || decisions[0].Review == nil {
		t.Fatalf("the decisions feed does not carry the review: %+v", decisions)
	}
	rv := decisions[0].Review
	if rv.Verdict != "false_positive" || rv.Reviewer != "static-key/policy-reviewer" || rv.ID != want {
		t.Errorf("joined review is wrong: %+v", rv)
	}
}

// A review must never appear in the findings feed or the decisions feed as a row of its own: it
// is a judgement ABOUT a decision, and counting it as one would double the queue.
func TestRecordedReviewDoesNotAppearAsAFindingOrDecision(t *testing.T) {
	router, _ := policyAPIFixture(t)
	if code, _ := recordReview(t, router, policyReviewerToken, "dec-a1", `{"verdict":"needs_info","note":""}`, nil); code != http.StatusCreated {
		t.Fatalf("POST review returned %d", code)
	}
	var findings []findingView
	policyRequest(t, router, http.MethodGet, "/api/v1/policy/findings?window=90m", policyReviewerToken, "", nil, &findings)
	if len(findings) != 2 {
		t.Errorf("findings feed grew to %d after a review was recorded", len(findings))
	}
	var decisions []decisionView
	policyRequest(t, router, http.MethodGet, "/api/v1/policy/decisions?window=90m", policyReviewerToken, "", nil, &decisions)
	if len(decisions) != 1 {
		t.Errorf("decisions feed grew to %d after a review was recorded", len(decisions))
	}
}

func TestPolicyReviewRejectsABadVerdict(t *testing.T) {
	router, _ := policyAPIFixture(t)
	for name, body := range map[string]string{
		"empty":            `{"verdict":"","note":"n"}`,
		"absent":           `{"note":"n"}`,
		"unknown value":    `{"verdict":"probably","note":"n"}`,
		"wrong case":       `{"verdict":"TRUE_POSITIVE","note":"n"}`,
		"unknown field":    `{"verdict":"true_positive","note":"n","reviewer":"forged"}`,
		"reviewer forged":  `{"verdict":"true_positive","reviewer":"somebody-else"}`,
		"not json":         `verdict=true_positive`,
		"array not object": `[{"verdict":"true_positive"}]`,
	} {
		code := policyRequest(t, router, http.MethodPost, "/api/v1/policy/decisions/dec-a1/review",
			policyReviewerToken, body, nil, nil)
		if code != http.StatusBadRequest {
			t.Errorf("%s (%s) returned %d, want 400", name, body, code)
		}
	}
	for _, v := range []string{"true_positive", "false_positive", "needs_info"} {
		code := policyRequest(t, router, http.MethodPost, "/api/v1/policy/decisions/dec-a1/review",
			policyReviewerToken, `{"verdict":"`+v+`","note":"ok"}`, nil, nil)
		if code != http.StatusCreated {
			t.Errorf("verdict %s returned %d, want 201", v, code)
		}
	}
}

func TestPolicyReviewRejectsAnOverLongNote(t *testing.T) {
	router, _ := policyAPIFixture(t)
	body, err := json.Marshal(reviewRequestBody{Verdict: "needs_info", Note: strings.Repeat("x", policy.MaxReviewNoteLen+1)})
	if err != nil {
		t.Fatal(err)
	}
	if code := policyRequest(t, router, http.MethodPost, "/api/v1/policy/decisions/dec-a1/review",
		policyReviewerToken, string(body), nil, nil); code != http.StatusBadRequest {
		t.Errorf("a note of %d characters returned %d, want 400: silently truncating would alter the reviewer's stated reason",
			policy.MaxReviewNoteLen+1, code)
	}
	atLimit, _ := json.Marshal(reviewRequestBody{Verdict: "needs_info", Note: strings.Repeat("x", policy.MaxReviewNoteLen)})
	if code := policyRequest(t, router, http.MethodPost, "/api/v1/policy/decisions/dec-a1/review",
		policyReviewerToken, string(atLimit), nil, nil); code != http.StatusCreated {
		t.Errorf("a note of exactly %d characters returned %d, want 201", policy.MaxReviewNoteLen, code)
	}
}

func TestPolicyReviewIsIdempotentAndSaysSo(t *testing.T) {
	router, h := policyAPIFixture(t)
	body := `{"verdict":"true_positive","note":"escalated to IR"}`
	code, first := recordReview(t, router, policyReviewerToken, "dec-a1", body, nil)
	if code != http.StatusCreated {
		t.Fatalf("first POST returned %d", code)
	}
	// The same reviewer re-asserting the same thing is a conflict, not a second row: a dashboard
	// that double-fires on a slow click has to be able to tell that nothing changed.
	var conflict struct {
		Error  string         `json:"error"`
		Review reviewResponse `json:"review"`
	}
	code = policyRequest(t, router, http.MethodPost, "/api/v1/policy/decisions/dec-a1/review",
		policyReviewerToken, body, nil, &conflict)
	if code != http.StatusConflict {
		t.Fatalf("repeat POST returned %d, want 409", code)
	}
	if conflict.Review.ID != first.ID {
		t.Errorf("409 named review %s, want the already-recorded %s", conflict.Review.ID, first.ID)
	}
	rows, err := h.Store.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for i := range rows {
		if policy.IsReview(&rows[i]) {
			n++
		}
	}
	if n != 1 {
		t.Errorf("%d review rows in the store after two identical POSTs, want 1", n)
	}
}

// A changed verdict is a SECOND assertion, not an overwrite. Both stay in the evidence; the feed
// shows the current position.
func TestPolicyReviewRevisionIsASecondRowAndTheFeedShowsTheLatest(t *testing.T) {
	router, h := policyAPIFixture(t)
	clock := make([]time.Time, 0, 2)
	base, _ := time.Parse(time.RFC3339, policyReviewFixedNow)
	clock = append(clock, base, base.Add(time.Hour))
	i := 0
	h.now = func() time.Time {
		t := clock[i]
		if i < len(clock)-1 {
			i++
		}
		return t
	}
	if code, _ := recordReview(t, router, policyReviewerToken, "dec-a1", `{"verdict":"true_positive","note":"first look"}`, nil); code != http.StatusCreated {
		t.Fatalf("first review returned %d", code)
	}
	if code, _ := recordReview(t, router, policyReviewerToken, "dec-a1", `{"verdict":"false_positive","note":"second look: benign"}`, nil); code != http.StatusCreated {
		t.Fatalf("revised review returned %d, want 201 (a revision is a new assertion)", code)
	}
	rows, err := h.Store.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for j := range rows {
		if policy.IsReview(&rows[j]) {
			n++
		}
	}
	if n != 2 {
		t.Errorf("%d review rows after a revision, want 2: the first judgement must stay on the record", n)
	}
	var decisions []decisionView
	policyRequest(t, router, http.MethodGet, "/api/v1/policy/decisions", policyReviewerToken, "", nil, &decisions)
	if len(decisions) != 1 || decisions[0].Review == nil {
		t.Fatalf("feed lost the review: %+v", decisions)
	}
	if decisions[0].Review.Verdict != "false_positive" {
		t.Errorf("feed shows verdict %q, want the latest false_positive", decisions[0].Review.Verdict)
	}
}

// A changed note with the same verdict is a revision (a new assertion with a different ReviewID),
// not a conflict. Replaying the exact same revision is a 409 conflict.
func TestPolicyReviewChangedNoteIsARevisionNotAConflict(t *testing.T) {
	router, h := policyAPIFixture(t)
	clock := make([]time.Time, 0, 2)
	base, _ := time.Parse(time.RFC3339, policyReviewFixedNow)
	clock = append(clock, base, base.Add(30*time.Minute))
	i := 0
	h.now = func() time.Time {
		t := clock[i]
		if i < len(clock)-1 {
			i++
		}
		return t
	}

	body1 := `{"verdict":"true_positive","note":"initial suspicion"}`
	code, first := recordReview(t, router, policyReviewerToken, "dec-a1", body1, nil)
	if code != http.StatusCreated {
		t.Fatalf("first review returned %d, want 201", code)
	}

	body2 := `{"verdict":"true_positive","note":"confirmed after IR triage"}`
	code, second := recordReview(t, router, policyReviewerToken, "dec-a1", body2, nil)
	if code != http.StatusCreated {
		t.Fatalf("changed note review returned %d, want 201 (a changed note is a revision)", code)
	}
	if second.ID == first.ID {
		t.Errorf("changed note got same review ID %s", first.ID)
	}

	// Replaying the exact same second review is a 409 Conflict
	var conflict struct {
		Error  string         `json:"error"`
		Review reviewResponse `json:"review"`
	}
	code = policyRequest(t, router, http.MethodPost, "/api/v1/policy/decisions/dec-a1/review",
		policyReviewerToken, body2, nil, &conflict)
	if code != http.StatusConflict {
		t.Fatalf("replaying exact second review returned %d, want 409", code)
	}
	if conflict.Review.ID != second.ID {
		t.Errorf("409 named review %s, want %s", conflict.Review.ID, second.ID)
	}

	rows, err := h.Store.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for j := range rows {
		if policy.IsReview(&rows[j]) {
			n++
		}
	}
	if n != 2 {
		t.Errorf("%d review rows in store, want 2 (initial note and revised note)", n)
	}

	var decisions []decisionView
	policyRequest(t, router, http.MethodGet, "/api/v1/policy/decisions", policyReviewerToken, "", nil, &decisions)
	if len(decisions) != 1 || decisions[0].Review == nil {
		t.Fatalf("feed lost review: %+v", decisions)
	}
	if decisions[0].Review.Note != "confirmed after IR triage" {
		t.Errorf("feed note is %q, want latest revision %q", decisions[0].Review.Note, "confirmed after IR triage")
	}
}

// Two distinct reviewers recording the same verdict and note against the same decision each
// produce a distinct row in the evidence store. Collapsing them would destroy agreement.
func TestPolicyReviewDistinctReviewersEachRecordARow(t *testing.T) {
	router, h := policyAPIFixture(t)
	body := `{"verdict":"true_positive","note":"unambiguous compromise"}`

	// Reviewer 1 records review
	code1, rev1 := recordReview(t, router, policyReviewerToken, "dec-a1", body, nil)
	if code1 != http.StatusCreated {
		t.Fatalf("reviewer 1 returned %d, want 201", code1)
	}

	// Reviewer 2 records review with identical verdict and note
	code2, rev2 := recordReview(t, router, policyReviewer2Token, "dec-a1", body, nil)
	if code2 != http.StatusCreated {
		t.Fatalf("reviewer 2 returned %d, want 201 (distinct reviewers must both record)", code2)
	}

	if rev1.ID == rev2.ID {
		t.Fatalf("distinct reviewers got identical review ID: %s", rev1.ID)
	}
	if rev1.Reviewer == rev2.Reviewer {
		t.Fatalf("expected distinct reviewer subjects, got %s for both", rev1.Reviewer)
	}

	// Replay reviewer 1 -> 409
	code := policyRequest(t, router, http.MethodPost, "/api/v1/policy/decisions/dec-a1/review",
		policyReviewerToken, body, nil, nil)
	if code != http.StatusConflict {
		t.Errorf("replay of reviewer 1 returned %d, want 409", code)
	}

	// Replay reviewer 2 -> 409
	code = policyRequest(t, router, http.MethodPost, "/api/v1/policy/decisions/dec-a1/review",
		policyReviewer2Token, body, nil, nil)
	if code != http.StatusConflict {
		t.Errorf("replay of reviewer 2 returned %d, want 409", code)
	}

	rows, err := h.Store.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for j := range rows {
		if policy.IsReview(&rows[j]) {
			n++
		}
	}
	if n != 2 {
		t.Errorf("%d review rows in store, want 2 (one per reviewer)", n)
	}
}

func TestPolicyReviewOfAnUnknownOrNonDecisionIDIs404(t *testing.T) {
	router, _ := policyAPIFixture(t)
	for name, id := range map[string]string{
		"unknown":          "dec-does-not-exist",
		"a finding":        "find-a1",
		"a raw obs":        "raw-a",
		"another tenant's": "dec-b1",
	} {
		code := policyRequest(t, router, http.MethodPost, "/api/v1/policy/decisions/"+id+"/review",
			policyReviewerToken, `{"verdict":"needs_info","note":""}`, nil, nil)
		if code != http.StatusNotFound {
			t.Errorf("review of %s (%s) returned %d, want 404", name, id, code)
		}
	}
}

// 404 and not 403 for another tenant's decision, so the route is not an existence oracle over the
// estate: a reviewer learns nothing about whether dec-b1 exists.
func TestPolicyReviewCannotCrossTenantsButACrossTenantReviewerCan(t *testing.T) {
	router, h := policyAPIFixture(t)
	if code := policyRequest(t, router, http.MethodPost, "/api/v1/policy/decisions/dec-b1/review",
		policyReviewerToken, `{"verdict":"true_positive","note":""}`, nil, nil); code != http.StatusNotFound {
		t.Errorf("tenant-a's reviewer reviewing tenant-b's decision got %d, want 404", code)
	}
	code, got := recordReview(t, router, policyCrossToken, "dec-b1", `{"verdict":"true_positive","note":"real"}`, nil)
	if code != http.StatusCreated {
		t.Fatalf("cross-tenant reviewer got %d, want 201", code)
	}
	// The review is stamped with the DECISION's tenant, not the reviewing key's. Otherwise a
	// cross-tenant reviewer's verdicts would all land under its own tenant and be invisible to
	// the tenant whose decision was judged.
	rows, _ := h.Store.QueryRange(context.Background(), store.Query{})
	for i := range rows {
		if rows[i].ID == got.ID && rows[i].Labels[policy.TenantLabel] != "tenant-b" {
			t.Errorf("review of tenant-b's decision landed under tenant %q", rows[i].Labels[policy.TenantLabel])
		}
	}
}

// --- reviewer attribution --------------------------------------------------------------------

// A gateway holding tenant:act-for records the dashboard user's name, because its own key subject
// is shared by every user behind it. Attributing a verdict to "the dashboard" would make the
// record worthless.
func TestGatewayReviewIsAttributedToTheDashboardUser(t *testing.T) {
	router, _ := policyAPIFixture(t)
	headers := map[string]string{
		ActingTenantHeader:  "tenant-a",
		ActingSubjectHeader: "alice@example.com",
	}
	code, got := recordReview(t, router, policyGatewayToken, "dec-a1", `{"verdict":"true_positive","note":"confirmed"}`, headers)
	if code != http.StatusCreated {
		t.Fatalf("gateway review returned %d: %+v", code, got)
	}
	want := "static-key/fe-signalloom-gateway/alice@example.com"
	if got.Reviewer != want {
		t.Errorf("reviewer %q, want %q: both the person and the credential that carried them", got.Reviewer, want)
	}
	// Two different users behind the same gateway are two different reviewers, so their verdicts
	// do not collapse onto one row.
	headers[ActingSubjectHeader] = "bob@example.com"
	code2, got2 := recordReview(t, router, policyGatewayToken, "dec-a1", `{"verdict":"true_positive","note":"confirmed"}`, headers)
	if code2 != http.StatusCreated {
		t.Fatalf("second user's identical verdict returned %d, want 201", code2)
	}
	if got2.ID == got.ID {
		t.Error("two users' verdicts derived the same review ID: agreement was collapsed away")
	}
}

// A principal WITHOUT tenant:act-for cannot name a reviewer. Otherwise any key holding
// policy:review could forge a verdict onto somebody else's name.
func TestActingSubjectIsIgnoredWithoutActForTenant(t *testing.T) {
	router, _ := policyAPIFixture(t)
	code, got := recordReview(t, router, policyReviewerToken, "dec-a1", `{"verdict":"needs_info","note":""}`,
		map[string]string{ActingSubjectHeader: "ceo@example.com"})
	if code != http.StatusCreated {
		t.Fatalf("returned %d", code)
	}
	if got.Reviewer != "static-key/policy-reviewer" {
		t.Errorf("reviewer %q: a key without tenant:act-for forged an identity", got.Reviewer)
	}
}

// --- rates -----------------------------------------------------------------------------------

func TestPolicyRatesBucketsEverySourceNotJustPolicy(t *testing.T) {
	router, _ := policyAPIFixture(t)
	var got []rateBucketView
	if code := policyRequest(t, router, http.MethodGet, "/api/v1/policy/rates?window=90m&bucket=1m",
		policyReaderToken, "", nil, &got); code != http.StatusOK {
		t.Fatalf("status %d", code)
	}
	sources := map[string]int{}
	for _, b := range got {
		sources[b.Source] += b.Count
		if b.BucketStart.Second() != 0 || b.BucketStart.Nanosecond() != 0 {
			t.Errorf("bucket_start %v is not truncated to the minute", b.BucketStart)
		}
	}
	// The raw observation is the denominator that makes the derived series mean anything.
	if sources["aws:cloudtrail"] != 1 {
		t.Errorf("raw observations missing from the rates series: %v", sources)
	}
	if sources[obscel.SourceFinding] != 2 || sources[obscel.SourceDecision] != 1 {
		t.Errorf("derived series are wrong: %v", sources)
	}
	// Tenancy still applies: tenant-b's rows are absent.
	total := 0
	for _, n := range sources {
		total += n
	}
	if total != 4 {
		t.Errorf("rates counted %d rows for tenant-a, want 4 (tenant-b's 2 must be excluded)", total)
	}
}

func TestPolicyRatesBucketValidationAndOrdering(t *testing.T) {
	router, _ := policyAPIFixture(t)
	for _, bad := range []string{"2m", "1h", "60s", "0m", "minute"} {
		if code := policyRequest(t, router, http.MethodGet, "/api/v1/policy/rates?bucket="+bad,
			policyReaderToken, "", nil, nil); code != http.StatusBadRequest {
			t.Errorf("bucket=%s returned %d, want 400", bad, code)
		}
	}
	var got []rateBucketView
	if code := policyRequest(t, router, http.MethodGet, "/api/v1/policy/rates?window=90m&bucket=5m",
		policyReaderToken, "", nil, &got); code != http.StatusOK {
		t.Fatalf("bucket=5m returned %d", code)
	}
	for _, b := range got {
		if b.BucketStart.Minute()%5 != 0 {
			t.Errorf("bucket=5m produced bucket_start %v, not on a 5-minute boundary", b.BucketStart)
		}
	}
	// Oldest first, then layer, then source: a chart reads left to right.
	for i := 1; i < len(got); i++ {
		if got[i].BucketStart.Before(got[i-1].BucketStart) {
			t.Errorf("rates are not ordered oldest-first at %d: %v before %v", i, got[i].BucketStart, got[i-1].BucketStart)
		}
	}
}

func TestPolicyRatesEmptyWindowIsAnEmptyArray(t *testing.T) {
	router, _ := policyAPIFixture(t)
	r := httptest.NewRequest(http.MethodGet, "/api/v1/policy/rates?since=2030-01-01T00:00:00Z", nil)
	r.Header.Set("Authorization", "Bearer "+policyReaderToken)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)
	if got := strings.TrimSpace(w.Body.String()); got != "[]" {
		t.Errorf("empty rates serialised as %q, want []", got)
	}
}

// --- read-side deduplication -----------------------------------------------------------------

// A duplicated row in a pre-Deduper segment is a burst that never happened. Counting it twice in
// the rate chart, or listing it twice in the review queue, would put a fiction in front of the
// human whose judgement is being recorded.
func TestPolicyFeedsDeduplicateByID(t *testing.T) {
	_, h := policyAPIFixture(t)
	// Append the same finding twice directly, as a pre-Deduper segment holds it.
	dup := policyFinding("find-a1", "tenant-a", time.Now().UTC().Add(-30*time.Second))
	if err := h.Store.Append(context.Background(), []model.Observation{dup}); err != nil {
		t.Fatal(err)
	}
	raw, err := h.Store.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatal(err)
	}
	seen := 0
	for i := range raw {
		if raw[i].ID == "find-a1" {
			seen++
		}
	}
	if seen < 2 {
		t.Skip("the memory store collapsed the duplicate itself; nothing for the read-side pass to do")
	}
	router, _ := policyAPIFixture(t)
	_ = router
	var got []findingView
	r := httptest.NewRequest(http.MethodGet, "/api/v1/policy/findings?window=90m", nil)
	r.Header.Set("Authorization", "Bearer "+policyReaderToken)
	w := httptest.NewRecorder()
	// Reuse the same handlers so the duplicate is visible.
	delegate, _, _ := testJWTDelegate(t)
	a, err := NewStaticKeyAuthenticator([]StaticBearerConfig{
		{Name: "policy-reader", Token: policyReaderToken, Subject: "static-key/policy-reader",
			TenantID: "tenant-a", Permissions: []Permission{PermissionPolicyRead}, ExpiresAt: time.Now().Add(time.Hour)},
	}, delegate)
	if err != nil {
		t.Fatal(err)
	}
	rt, err := NewProtectedRouter(h, a, audit.NewFakeWriter(), http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatal(err)
	}
	rt.ServeHTTP(w, r)
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v (%s)", err, w.Body.String())
	}
	n := 0
	for _, f := range got {
		if f.ID == "find-a1" {
			n++
		}
	}
	if n != 1 {
		t.Errorf("find-a1 appears %d times in the findings feed, want 1", n)
	}
}

// --- route inventory -------------------------------------------------------------------------

// The four routes exist, at exactly the contracted paths and permissions, in the production
// router's own inventory. A handler nobody registered is not a feature, and a route registered
// under the wrong permission is a silent privilege change.
func TestPolicyRoutesAreRegisteredWithTheContractedPermissions(t *testing.T) {
	h, _ := newTestHandlers(t)
	want := map[string]Permission{
		"GET /api/v1/policy/findings":               PermissionPolicyRead,
		"GET /api/v1/policy/decisions":              PermissionPolicyRead,
		"GET /api/v1/policy/rates":                  PermissionPolicyRead,
		"POST /api/v1/policy/decisions/{id}/review": PermissionPolicyReview,
	}
	found := map[string]Permission{}
	for _, rd := range h.routeDefinitions(nil) {
		key := rd.method + " " + rd.path
		if _, interesting := want[key]; interesting {
			found[key] = rd.permission
			if rd.actorScoped {
				t.Errorf("%s is actorScoped; its {id} is a decision id, not an actor id", key)
			}
		}
	}
	for key, perm := range want {
		got, ok := found[key]
		if !ok {
			t.Errorf("route %s is not registered", key)
			continue
		}
		if got != perm {
			t.Errorf("route %s requires %q, want %q", key, got, perm)
		}
	}
	// Both permissions must be known, or a static key configured for them would silently get nothing.
	for _, p := range []Permission{PermissionPolicyRead, PermissionPolicyReview} {
		if !KnownPermissions[p] {
			t.Errorf("KnownPermissions does not list %q", p)
		}
	}
}
