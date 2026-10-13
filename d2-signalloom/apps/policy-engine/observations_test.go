package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

const testSegmentRootKeyHex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

func TestMain(m *testing.M) {
	if os.Getenv("SIGNAL_SEGMENT_PSEUDONYM_KEY") == "" {
		_ = os.Setenv("SIGNAL_SEGMENT_PSEUDONYM_KEY", testSegmentRootKeyHex)
	}
	os.Exit(m.Run())
}

// shippedBundlesDir is the real Flux-reconciled tree, reached from
// apps/policy-engine. Asserting against it rather than a copy is what proves
// the deployed bundle boots.
const shippedBundlesDir = "../../../policy/bundles"

const testBundleYAML = `
id: tenant-a-bundle
tenant_id: tenant-a
version: 1.0.0
mode: shadow
vars:
  break_glass_actors:
    - "arn:aws:iam::1:user/bg"
actor_vars: [break_glass_actors]
rules:
  - id: iam-change
    name: iam change
    severity: high
    expression: |-
      obs.layer == "cloud_control_plane" &&
      has(obs.labels.event_name) &&
      obs.labels.event_name == "AttachUserPolicy" &&
      !(obs.actor in vars.break_glass_actors)
`

const otherTenantBundleYAML = `
id: tenant-b-bundle
tenant_id: tenant-b
version: 2.1.0
mode: enforce
rules:
  - id: anything
    name: anything
    severity: low
    expression: 'obs.id != ""'
`

func writeFixtureBundles(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for name, body := range map[string]string{
		"tenant-a/iam.yaml":   testBundleYAML,
		"tenant-b/other.yaml": otherTenantBundleYAML,
	} {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// snapshot renders the durable set as a comparable string.
func snapshot(s *PolicyStore) string {
	var sb strings.Builder
	for _, tenant := range s.ObservationBundleTenants() {
		for _, b := range s.ObservationBundles(tenant) {
			sb.WriteString(tenant + "/" + b.ID + "@" + b.Version + ":" + string(b.Mode))
			for _, r := range obscel.SortedRules(b) {
				sb.WriteString("|" + r.ID)
			}
			sb.WriteString("\n")
		}
	}
	return sb.String()
}

// TestObservationBundleLoaderIsIdempotentAcrossRestarts: the boot loader run
// twice over the same tree must produce the same durable set, both in a fresh
// process and in a reloaded one. This is the "survives restart" property the
// API registration path deliberately lacks.
func TestObservationBundleLoaderIsIdempotentAcrossRestarts(t *testing.T) {
	dir := writeFixtureBundles(t)

	boot := func() *PolicyStore {
		engine, err := NewCELEngine()
		if err != nil {
			t.Fatalf("NewCELEngine: %v", err)
		}
		store := NewPolicyStore(engine)
		n, err := store.LoadObservationBundles(dir)
		if err != nil {
			t.Fatalf("LoadObservationBundles: %v", err)
		}
		if n != 2 {
			t.Fatalf("expected 2 bundles loaded, got %d", n)
		}
		return store
	}

	first := boot()
	want := "tenant-a/tenant-a-bundle@1.0.0:shadow|iam-change\ntenant-b/tenant-b-bundle@2.1.0:enforce|anything\n"
	if got := snapshot(first); got != want {
		t.Fatalf("durable set:\n got %q\nwant %q", got, want)
	}

	// A second process over the same tree.
	if got := snapshot(boot()); got != want {
		t.Fatalf("a restart must reproduce the set exactly:\n got %q\nwant %q", snapshot(boot()), want)
	}

	// A reload in the same process.
	if _, err := first.LoadObservationBundles(dir); err != nil {
		t.Fatalf("reload: %v", err)
	}
	if got := snapshot(first); got != want {
		t.Fatalf("reload must be idempotent, not additive:\n got %q\nwant %q", got, want)
	}
}

// TestObservationBundleLoaderReplacesRatherThanMerges: a bundle deleted from
// git must disappear on the next load. Merging would keep a withdrawn rule
// firing, which is exactly the git-versus-behaviour divergence that policy as
// versioned code exists to eliminate.
func TestObservationBundleLoaderReplacesRatherThanMerges(t *testing.T) {
	dir := writeFixtureBundles(t)
	engine, _ := NewCELEngine()
	store := NewPolicyStore(engine)
	if _, err := store.LoadObservationBundles(dir); err != nil {
		t.Fatal(err)
	}
	if got := len(store.ObservationBundles("tenant-b")); got != 1 {
		t.Fatalf("tenant-b should have 1 bundle, got %d", got)
	}

	if err := os.Remove(filepath.Join(dir, "tenant-b/other.yaml")); err != nil {
		t.Fatal(err)
	}
	if _, err := store.LoadObservationBundles(dir); err != nil {
		t.Fatal(err)
	}
	if got := len(store.ObservationBundles("tenant-b")); got != 0 {
		t.Fatalf("a bundle removed from the tree must not survive a reload, still have %d", got)
	}
	if got := len(store.ObservationBundles("tenant-a")); got != 1 {
		t.Fatalf("tenant-a must be untouched, got %d", got)
	}
}

func TestObservationBundleLoaderTolerantOfMissingDir(t *testing.T) {
	engine, _ := NewCELEngine()
	store := NewPolicyStore(engine)

	for _, dir := range []string{"", filepath.Join(t.TempDir(), "absent"), t.TempDir()} {
		n, err := store.LoadObservationBundles(dir)
		if err != nil {
			t.Fatalf("dir %q must not be an error: %v", dir, err)
		}
		if n != 0 {
			t.Fatalf("dir %q: expected 0 bundles, got %d", dir, n)
		}
	}
}

// TestObservationBundlesAreTenantScoped: one tenant must never be evaluated
// against another's bundles.
func TestObservationBundlesAreTenantScoped(t *testing.T) {
	dir := writeFixtureBundles(t)
	engine, _ := NewCELEngine()
	store := NewPolicyStore(engine)
	if _, err := store.LoadObservationBundles(dir); err != nil {
		t.Fatal(err)
	}
	for tenant, want := range map[string]int{"tenant-a": 1, "tenant-b": 1, "tenant-c": 0, "": 0} {
		if got := len(store.ObservationBundles(tenant)); got != want {
			t.Errorf("tenant %q: got %d bundles want %d", tenant, got, want)
		}
	}

	// The returned slice must be a copy: mutating it must not reach the store.
	got := store.ObservationBundles("tenant-a")
	got[0] = nil
	if store.ObservationBundles("tenant-a")[0] == nil {
		t.Fatal("ObservationBundles must return a copy, not the durable slice")
	}
}

// TestRegisteredBundleIsDryRunAndAbsentAfterRestart is the §4.4 contract: the
// HTTP registration surface is dry-run only and never persists.
//
// Killed mutation: having HandleRegisterBundle also append to obsBundles (or
// having LoadObservationBundles merge rather than replace) makes the post-boot
// assertion below find the registration still present, i.e. a policy change
// made over an API outliving the git tree that is supposed to be authoritative.
func TestRegisteredBundleIsDryRunAndAbsentAfterRestart(t *testing.T) {
	dir := writeFixtureBundles(t)
	engine, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	store := NewPolicyStore(engine)
	if _, err := store.LoadObservationBundles(dir); err != nil {
		t.Fatal(err)
	}
	before := snapshot(store)

	handlers := NewPolicyEngineHandlers(store, engine)
	body, _ := json.Marshal(PolicyBundle{
		FrameworkID: "ad-hoc",
		Version:     "v9.9.9",
		Author:      "dashboard",
		Rules:       []PolicyRule{{ID: "r", Name: "n", CELExpression: `agent.model != ""`}},
	})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/policies/bundles", bytes.NewReader(body))
	req.Header.Set("X-Tenant-ID", "tenant-a")
	w := httptest.NewRecorder()
	handlers.HandleRegisterBundle(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("registration must still work for existing callers, got %d: %s", w.Code, w.Body.String())
	}
	var registered PolicyBundle
	if err := json.Unmarshal(w.Body.Bytes(), &registered); err != nil {
		t.Fatal(err)
	}
	if !registered.DryRun {
		t.Error("a bundle registered over the API must be flagged dry_run")
	}
	if !strings.Contains(w.Body.String(), `"dry_run":true`) {
		t.Errorf("the dry_run flag must be visible on the wire, got %s", w.Body.String())
	}

	// It is reachable through the framework surface in-process...
	if _, err := store.GetActiveBundle("tenant-a", "ad-hoc", ""); err != nil {
		t.Errorf("the registration should be live in-process: %v", err)
	}
	// ...but it never joined the durable observation set.
	if got := snapshot(store); got != before {
		t.Fatalf("registration must not alter the durable set:\n got %q\nwant %q", got, before)
	}

	// And a restart over the same tree does not know about it.
	restarted := NewPolicyStore(engine)
	if _, err := restarted.LoadObservationBundles(dir); err != nil {
		t.Fatal(err)
	}
	if got := snapshot(restarted); got != before {
		t.Fatalf("a registration must be absent after a loader restart:\n got %q\nwant %q", got, before)
	}
	if _, err := restarted.GetActiveBundle("tenant-a", "ad-hoc", ""); err == nil {
		t.Fatal("the API registration must not survive a restart")
	}
}

// TestLoadedFrameworkBundlesAreNotDryRun: the flag must distinguish the two
// origins, otherwise it says nothing.
func TestLoadedFrameworkBundlesAreNotDryRun(t *testing.T) {
	engine, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	store := NewPolicyStore(engine)
	bundle := &PolicyBundle{
		FrameworkID: "eu-ai-act",
		Version:     "v1.0.0",
		Author:      "system",
		Rules:       []PolicyRule{{ID: "r", Name: "n", CELExpression: `agent.model != ""`}},
	}
	if err := store.RegisterBundle("", bundle); err != nil {
		t.Fatal(err)
	}
	if bundle.DryRun {
		t.Error("a bundle registered in-process by the loader must not be flagged dry_run")
	}
}

func postObservation(t *testing.T, h http.HandlerFunc, body string, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/observations/evaluate", strings.NewReader(body))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	h(w, req)
	return w
}

func newObservationHandler(t *testing.T, dir string) http.HandlerFunc {
	t.Helper()
	engine, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	store := NewPolicyStore(engine)
	key, _ := hex.DecodeString(testSegmentRootKeyHex)
	store.SetPseudonymConfig(key, 1)
	if _, err := store.LoadObservationBundles(dir); err != nil {
		t.Fatalf("LoadObservationBundles(%s): %v", dir, err)
	}
	ev, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatal(err)
	}
	return NewObservationHandlers(store, ev).HandleEvaluateObservation
}

// TestEvaluateObservationAgainstShippedBundle drives the dry-run route with the
// real Flux-reconciled tree, so a defect in the shipped bundle fails here.
func TestEvaluateObservationAgainstShippedBundle(t *testing.T) {
	h := newObservationHandler(t, shippedBundlesDir)

	w := postObservation(t, h, `{
	  "tenant_id": "kusari",
	  "observation": {
	    "id": "obs-1",
	    "timestamp": "2026-10-04T08:00:00Z",
	    "layer": "cloud_control_plane",
	    "source": "aws:cloudtrail",
	    "fidelity": "high",
	    "confidence": 0.9,
	    "actor": "arn:aws:iam::123456789012:user/dev",
	    "labels": {"event_source": "iam.amazonaws.com", "event_name": "AttachUserPolicy"}
	  }
	}`, nil)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	var resp EvaluateObservationResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if !resp.DryRun {
		t.Error("the observation route is a dry-run surface and must say so")
	}
	if len(resp.Faults) != 0 {
		t.Errorf("the shipped bundle must not fault: %v", resp.Faults)
	}
	// The tenant's shipped tree holds more than one bundle (kusari-iam-change
	// and kusari-cloud-signals), and they overlap on the IAM path by design --
	// cloud-signals.yaml says so in its header, and the overlap is what lets the
	// narrow IAM bundle be promoted to warn on its own schedule. A finding is
	// per bundle by construction, because Finding.ID hashes the bundle version,
	// so one AttachUserPolicy legitimately yields one finding per bundle.
	//
	// So this test asserts the kusari-iam-change finding specifically rather
	// than asserting that nothing else fired. Every original claim about that
	// finding -- rule, tenant, derived id, observation timestamp -- is unchanged.
	var f obscel.Finding
	byBundle := map[string]obscel.Finding{}
	for _, got := range resp.Findings {
		byBundle[got.BundleID] = got
	}
	f, ok := byBundle["kusari-iam-change"]
	if !ok {
		t.Fatalf("no finding from kusari-iam-change; got %d findings (%+v)", len(resp.Findings), resp.Findings)
	}
	if _, ok := byBundle["kusari-cloud-signals"]; !ok {
		t.Errorf("no finding from kusari-cloud-signals over an AttachUserPolicy event; its iam-credential-or-policy-change rule has drifted (got %+v)", resp.Findings)
	}
	if f.RuleID != "iam-priv-change" {
		t.Errorf("rule_id: got %q", f.RuleID)
	}
	if f.TenantID != "kusari" {
		t.Errorf("tenant_id: got %q", f.TenantID)
	}
	if want := obscel.FindingID("kusari", "iam-priv-change", "1.0.0", "obs-1"); f.ID != want {
		t.Errorf("finding id must be derived: got %q want %q", f.ID, want)
	}
	if got := f.Timestamp.UTC().Format("2006-01-02T15:04:05Z"); got != "2026-10-04T08:00:00Z" {
		t.Errorf("finding timestamp must be the observation's, got %s", got)
	}
	// Every bundle the tenant has shipped was evaluated, and each reports its
	// mode. Asserting the SET rather than a single element is what keeps this
	// honest: a bundle silently missing from the dry-run surface is the defect
	// this line exists to catch, and a length-1 check could no longer see it.
	// Every bundle the tenant ships is evaluated on every observation (the dry-run
	// reports each bundle's mode); the full-coverage detection streams added
	// their bundles, so the set grew. The new streams are source+layer gated and
	// correctly fire ZERO findings on this cloud_control_plane AttachUserPolicy
	// event — but they are still evaluated, so they must appear here. A bundle
	// silently missing from this set is the defect this assertion exists to catch.
	wantBundles := map[string]bool{
		"kusari-iam-change@1.0.0":       true,
		"kusari-cloud-signals@1.1.0":    true,
		"kusari-k8s-audit@1.0.0":        true,
		"kusari-landlock-denial@1.0.0":  true,
		"kusari-gcp-admin@1.0.0":        true,
		"kusari-openbao-audit@1.0.0":    true,
		"kusari-identity-auth@1.0.0":    true,
		"kusari-application-saas@1.0.0": true,
		"kusari-network-egress@1.0.0":   true,
		"kusari-endpoint-runtime@1.0.0": true,
	}
	for _, b := range resp.Bundles {
		if !wantBundles[b] {
			t.Errorf("unexpected bundle %q in the dry-run response", b)
		}
		delete(wantBundles, b)
	}
	for b := range wantBundles {
		t.Errorf("bundle %q was not evaluated by the dry-run surface; got %v", b, resp.Bundles)
	}
	for _, id := range []string{"kusari-iam-change", "kusari-cloud-signals"} {
		if resp.Modes[id] != "shadow" {
			t.Errorf("mode must be reported so the caller knows nothing was enforced; %s = %q, got %v", id, resp.Modes[id], resp.Modes)
		}
	}
}

func TestEvaluateObservationBenignEventYieldsNoFindings(t *testing.T) {
	h := newObservationHandler(t, shippedBundlesDir)
	w := postObservation(t, h, `{"tenant_id":"kusari","observation":{"id":"o","timestamp":"2026-10-04T08:00:00Z","layer":"cloud_control_plane","labels":{"event_source":"iam.amazonaws.com","event_name":"ListUsers"},"actor":"arn:x"}}`, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	var resp EvaluateObservationResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Findings) != 0 {
		t.Fatalf("expected no findings, got %+v", resp.Findings)
	}
	if len(resp.Faults) != 0 {
		t.Fatalf("expected no faults, got %v", resp.Faults)
	}
}

// TestEvaluateObservationFiresEndpointRulesOnLiveStunSentinelStream proves the
// endpoint-runtime rules fire on a "stun-sentinel"-sourced observation (the live
// sentinel wire), not only on the collector projection
// ("sentinel.ebpf.syscall_trace"). It drives the real Flux-reconciled tree.
//
// The dry-run route does not pseudonymise, so vars.allowed_exec_actors stays
// cleartext ["agent-trusted-sa"] and obs.actor is the posted value verbatim —
// which is exactly what lets a positive/negative execve pair be asserted here.
func TestEvaluateObservationFiresEndpointRulesOnLiveStunSentinelStream(t *testing.T) {
	h := newObservationHandler(t, shippedBundlesDir)

	// endpointRuleFired reports whether the endpoint-runtime bundle produced a
	// finding for ruleID over the posted observation body, asserting no faults.
	endpointRuleFired := func(t *testing.T, body, ruleID string) bool {
		t.Helper()
		w := postObservation(t, h, body, nil)
		if w.Code != http.StatusOK {
			t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
		}
		var resp EvaluateObservationResponse
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatal(err)
		}
		if len(resp.Faults) != 0 {
			t.Fatalf("the shipped bundle faulted on a stun-sentinel observation: %v", resp.Faults)
		}
		for _, f := range resp.Findings {
			if f.BundleID == "kusari-endpoint-runtime" && f.RuleID == ruleID {
				return true
			}
		}
		return false
	}

	const layerSrc = `"layer":"endpoint_host","source":"stun-sentinel","fidelity":"strong","confidence":0.95`

	t.Run("sensitive-file-open fires on a live sentinel openat of /etc/shadow", func(t *testing.T) {
		body := `{"tenant_id":"kusari","observation":{"id":"s1","timestamp":"2026-10-04T08:00:00Z",` + layerSrc +
			`,"labels":{"classification":"file_access","target":"/etc/shadow","syscall":"sys_enter_openat"}}}`
		if !endpointRuleFired(t, body, "sensitive-file-open") {
			t.Error("sensitive-file-open did not fire on a stun-sentinel file_access of /etc/shadow")
		}
	})

	t.Run("unexpected-execve fires for a non-allowlisted actor on the live stream", func(t *testing.T) {
		body := `{"tenant_id":"kusari","observation":{"id":"s2","timestamp":"2026-10-04T08:00:00Z",` + layerSrc +
			`,"actor":"agent-rogue","labels":{"classification":"process_exec","syscall":"sys_enter_execve"}}}`
		if !endpointRuleFired(t, body, "unexpected-execve") {
			t.Error("unexpected-execve did not fire on a stun-sentinel process_exec by a non-allowlisted actor")
		}
	})

	t.Run("capability-or-ptrace fires when the source gate admits stun-sentinel", func(t *testing.T) {
		// The live sentinel never emits ptrace today (see the bundle NOTE), but the
		// unioned source gate must admit "stun-sentinel" for this rule too: a
		// syscall=="ptrace" stun-sentinel observation fires, proving the gate, not
		// the (absent) live probe.
		body := `{"tenant_id":"kusari","observation":{"id":"s3","timestamp":"2026-10-04T08:00:00Z",` + layerSrc +
			`,"labels":{"syscall":"ptrace"}}}`
		if !endpointRuleFired(t, body, "capability-or-ptrace") {
			t.Error("capability-or-ptrace did not fire on a stun-sentinel ptrace syscall; the source union did not admit stun-sentinel")
		}
	})

	t.Run("NEGATIVE: a non-sensitive file open produces no endpoint finding", func(t *testing.T) {
		body := `{"tenant_id":"kusari","observation":{"id":"s4","timestamp":"2026-10-04T08:00:00Z",` + layerSrc +
			`,"labels":{"classification":"file_access","target":"/var/log/scratch.log","syscall":"sys_enter_openat"}}}`
		if endpointRuleFired(t, body, "sensitive-file-open") {
			t.Error("sensitive-file-open fired on a non-sensitive target; the membership gate is not holding")
		}
	})

	t.Run("NEGATIVE: an allow-listed actor's exec produces no unexpected-execve", func(t *testing.T) {
		body := `{"tenant_id":"kusari","observation":{"id":"s5","timestamp":"2026-10-04T08:00:00Z",` + layerSrc +
			`,"actor":"agent-trusted-sa","labels":{"classification":"process_exec","syscall":"sys_enter_execve"}}}`
		if endpointRuleFired(t, body, "unexpected-execve") {
			t.Error("unexpected-execve fired for an allow-listed actor; the actor scope is not holding")
		}
	})
}

func TestEvaluateObservationRequestValidation(t *testing.T) {
	h := newObservationHandler(t, writeFixtureBundles(t))

	cases := []struct {
		name    string
		method  string
		body    string
		headers map[string]string
		want    int
	}{
		{"GET is refused", http.MethodGet, "", nil, http.StatusMethodNotAllowed},
		{"HEAD is refused with 0 body bytes", http.MethodHead, "", nil, http.StatusMethodNotAllowed},
		{"PUT is refused", http.MethodPut, "", nil, http.StatusMethodNotAllowed},
		{"DELETE is refused", http.MethodDelete, "", nil, http.StatusMethodNotAllowed},
		{"PATCH is refused", http.MethodPatch, "", nil, http.StatusMethodNotAllowed},
		{"malformed json", http.MethodPost, `{`, nil, http.StatusBadRequest},
		{"missing tenant", http.MethodPost, `{"observation":{"id":"o"}}`, nil, http.StatusBadRequest},
		{"tenant from header", http.MethodPost, `{"observation":{"id":"o","layer":"x"}}`,
			map[string]string{"X-Tenant-ID": "tenant-a"}, http.StatusOK},
		{"tenant mismatch is refused", http.MethodPost,
			`{"tenant_id":"tenant-a","observation":{"id":"o","tenant_id":"tenant-b"}}`, nil, http.StatusBadRequest},
		{"unknown tenant evaluates nothing", http.MethodPost,
			`{"tenant_id":"tenant-zzz","observation":{"id":"o"}}`, nil, http.StatusOK},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(tc.method, "/api/v1/observations/evaluate", strings.NewReader(tc.body))
			for k, v := range tc.headers {
				req.Header.Set(k, v)
			}
			w := httptest.NewRecorder()
			h(w, req)
			if w.Code != tc.want {
				t.Fatalf("got %d want %d: %s", w.Code, tc.want, w.Body.String())
			}
			if tc.want == http.StatusMethodNotAllowed && w.Header().Get("Allow") != "POST, OPTIONS" {
				t.Fatalf("Allow header = %q, want POST, OPTIONS", w.Header().Get("Allow"))
			}
			if tc.method == http.MethodHead && w.Body.Len() != 0 {
				t.Fatalf("expected 0 body bytes on HEAD, got %d: %q", w.Body.Len(), w.Body.String())
			}
		})
	}
}

// TestEvaluateObservationBindsTenantOntoTheObservation: a finding must never be
// attributed to a tenant the caller did not name (D7).
func TestEvaluateObservationBindsTenantOntoTheObservation(t *testing.T) {
	h := newObservationHandler(t, writeFixtureBundles(t))
	w := postObservation(t, h, `{"tenant_id":"tenant-b","observation":{"id":"o","layer":"x"}}`, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	var resp EvaluateObservationResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Findings) != 1 {
		t.Fatalf("expected 1 finding, got %d", len(resp.Findings))
	}
	if resp.Findings[0].TenantID != "tenant-b" {
		t.Fatalf("finding must carry the request tenant, got %q", resp.Findings[0].TenantID)
	}
}

// TestEvaluateObservationReportsFaultsWithoutHidingFindings: a broken rule in
// a tenant's bundle must not blank the dry-run surface.
func TestEvaluateObservationReportsFaultsWithoutHidingFindings(t *testing.T) {
	dir := t.TempDir()
	// Loaded directly into the store: LoadBundleDir is fail-closed, so a bundle
	// with a runtime-faulting rule cannot be written to disk and loaded. The
	// fault being reachable at all is the point.
	engine, _ := NewCELEngine()
	store := NewPolicyStore(engine)
	if _, err := store.LoadObservationBundles(dir); err != nil {
		t.Fatal(err)
	}
	store.obsBundles["tenant-a"] = []*obscel.Bundle{{
		ID: "mixed", TenantID: "tenant-a", Version: "1.0.0", Mode: obscel.ModeShadow,
		Rules: []obscel.Rule{
			{ID: "aa-good", Severity: "low", Expression: `obs.id != ""`},
			{ID: "bb-faulting", Severity: "low", Expression: `obs.labels.absent == "x"`},
		},
	}}
	ev, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatal(err)
	}
	h := NewObservationHandlers(store, ev).HandleEvaluateObservation

	w := postObservation(t, h, `{"tenant_id":"tenant-a","observation":{"id":"o","labels":{}}}`, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("a faulting rule must not fail the dry-run request, got %d", w.Code)
	}
	var resp EvaluateObservationResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Findings) != 1 || resp.Findings[0].RuleID != "aa-good" {
		t.Fatalf("the healthy rule must still report: %+v", resp.Findings)
	}
	if len(resp.Faults) != 1 || !strings.Contains(resp.Faults[0], "bb-faulting") {
		t.Fatalf("the fault must be surfaced and name the rule, got %v", resp.Faults)
	}
}

func TestDefaultBundlesDirIsTheConfigMapMount(t *testing.T) {
	if DefaultBundlesDir != "/etc/policy-engine/bundles" {
		t.Fatalf("the default must match the manifest mount, got %q", DefaultBundlesDir)
	}
	if BundlesDirEnv != "POLICY_BUNDLES_DIR" {
		t.Fatalf("env var name drifted: %q", BundlesDirEnv)
	}
}

// TestBootRefusesActorVars asserts that booting without pseudonymisation key material
// refuses to load any bundle that declares actor_vars (fail-closed contract).
func TestBootRefusesActorVars(t *testing.T) {
	t.Setenv("SIGNAL_SEGMENT_PSEUDONYM_KEY", "")

	dir := writeFixtureBundles(t)
	engine, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	store := NewPolicyStore(engine)
	_, err = store.LoadObservationBundles(dir)
	if err == nil {
		t.Fatal("expected LoadObservationBundles to fail when actor_vars is declared but no key is configured")
	}
	if !strings.Contains(err.Error(), "SIGNAL_SEGMENT_PSEUDONYM_KEY is not configured") {
		t.Fatalf("unexpected error message: %v", err)
	}
}

// TestRegisteredDryRun asserts that API-registered bundles with actor_vars fail without key
// and succeed (with pseudonymised vars and dry_run: true) when key is configured.
func TestRegisteredDryRun(t *testing.T) {
	engine, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}

	// 1. Without key configured: registering bundle with actor_vars fails
	storeNoKey := NewPolicyStore(engine)
	t.Setenv("SIGNAL_SEGMENT_PSEUDONYM_KEY", "")
	bundleWithActors := &PolicyBundle{
		FrameworkID: "test-actors",
		Version:     "v1.0.0",
		ActorVars:   []string{"admin_actors"},
		Vars:        map[string][]string{"admin_actors": {"arn:aws:iam::1:user/admin"}},
		Rules:       []PolicyRule{{ID: "r", Name: "n", CELExpression: `agent.model != ""`}},
	}
	err = storeNoKey.RegisterBundle("tenant-a", bundleWithActors)
	if err == nil {
		t.Fatal("expected RegisterBundle to fail when bundle declares actor_vars and no key configured")
	}

	// Over HTTP: returns 400
	handlersNoKey := NewPolicyEngineHandlers(storeNoKey, engine)
	body, _ := json.Marshal(bundleWithActors)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/policies/bundles", bytes.NewReader(body))
	req.Header.Set("X-Tenant-ID", "tenant-a")
	w := httptest.NewRecorder()
	handlersNoKey.HandleRegisterBundle(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 when registering bundle with actor_vars without key, got %d: %s", w.Code, w.Body.String())
	}

	// 2. With key configured: succeeds and pseudonymises actor_vars
	t.Setenv("SIGNAL_SEGMENT_PSEUDONYM_KEY", testSegmentRootKeyHex)
	storeWithKey := NewPolicyStore(engine)
	key, _ := hex.DecodeString(testSegmentRootKeyHex)
	storeWithKey.SetPseudonymConfig(key, 1)

	handlersWithKey := NewPolicyEngineHandlers(storeWithKey, engine)
	req2 := httptest.NewRequest(http.MethodPost, "/api/v1/policies/bundles", bytes.NewReader(body))
	req2.Header.Set("X-Tenant-ID", "tenant-a")
	w2 := httptest.NewRecorder()
	handlersWithKey.HandleRegisterBundle(w2, req2)
	if w2.Code != http.StatusCreated {
		t.Fatalf("expected 201 when registering with key, got %d: %s", w2.Code, w2.Body.String())
	}
	var registered PolicyBundle
	if err := json.Unmarshal(w2.Body.Bytes(), &registered); err != nil {
		t.Fatal(err)
	}
	if !registered.DryRun {
		t.Error("registered bundle must be marked dry_run")
	}
	if registered.Vars["admin_actors"][0] == "arn:aws:iam::1:user/admin" {
		t.Error("registered bundle actor_vars must be pseudonymised, got cleartext")
	}
	if len(registered.Vars["admin_actors"][0]) != 64 {
		t.Errorf("expected 64-hex pseudonym in registered bundle vars, got %q", registered.Vars["admin_actors"][0])
	}
}

// TestEvaluateObservationUsesThePseudonymisedActorAndAllowlists asserts that cleartext actors
// are pseudonymised before evaluation, allowlists match pseudonymised identities, and cleartext
// allowlists against pseudonymised actors do not fire.
func TestEvaluateObservationUsesThePseudonymisedActorAndAllowlists(t *testing.T) {
	t.Setenv("SIGNAL_SEGMENT_PSEUDONYM_KEY", testSegmentRootKeyHex)
	t.Setenv("SIGNAL_SEGMENT_PSEUDONYM_EPOCH", "1")

	dir := t.TempDir()
	bundleYAML := `
id: allowlist-test-bundle
tenant_id: kusari
version: 1.0.0
mode: shadow
vars:
  allowed_actors:
    - "arn:aws:iam::123456789012:user/allowed-admin"
actor_vars: [allowed_actors]
rules:
  - id: check-allowed
    name: check allowed
    severity: high
    expression: |-
      obs.actor in vars.allowed_actors
  - id: check-not-allowed
    name: check not allowed
    severity: high
    expression: |-
      !(obs.actor in vars.allowed_actors)
`
	p := filepath.Join(dir, "kusari", "allowlist.yaml")
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(bundleYAML), 0o644); err != nil {
		t.Fatal(err)
	}

	engine, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	store := NewPolicyStore(engine)
	key, _ := hex.DecodeString(testSegmentRootKeyHex)
	store.SetPseudonymConfig(key, 1)

	if _, err := store.LoadObservationBundles(dir); err != nil {
		t.Fatalf("LoadObservationBundles: %v", err)
	}

	ev, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatal(err)
	}
	h := NewObservationHandlers(store, ev).HandleEvaluateObservation

	// 1. Observation with cleartext allowed actor (actor_is_pseudonym: false)
	// Must match check-allowed rule and NOT match check-not-allowed rule.
	// Finding.Actor must be the 64-hex pseudonym, not cleartext!
	w := postObservation(t, h, `{
	  "tenant_id": "kusari",
	  "actor_is_pseudonym": false,
	  "observation": {
	    "id": "obs-allowed",
	    "timestamp": "2026-10-04T08:00:00Z",
	    "layer": "cloud_control_plane",
	    "actor": "arn:aws:iam::123456789012:user/allowed-admin"
	  }
	}`, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	var resp EvaluateObservationResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Findings) != 1 || resp.Findings[0].RuleID != "check-allowed" {
		t.Fatalf("expected 1 finding for check-allowed, got %+v", resp.Findings)
	}
	if resp.Findings[0].Actor == "arn:aws:iam::123456789012:user/allowed-admin" {
		t.Errorf("Finding.Actor must be pseudonym, got cleartext ARN: %q", resp.Findings[0].Actor)
	}
	if len(resp.Findings[0].Actor) != 64 {
		t.Errorf("Finding.Actor must be 64-character pseudonym, got %q", resp.Findings[0].Actor)
	}

	// 2. Observation with non-allowed actor
	w2 := postObservation(t, h, `{
	  "tenant_id": "kusari",
	  "actor_is_pseudonym": false,
	  "observation": {
	    "id": "obs-other",
	    "timestamp": "2026-10-04T08:00:00Z",
	    "layer": "cloud_control_plane",
	    "actor": "arn:aws:iam::123456789012:user/unauthorized"
	  }
	}`, nil)
	if w2.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w2.Code, w2.Body.String())
	}
	var resp2 EvaluateObservationResponse
	if err := json.Unmarshal(w2.Body.Bytes(), &resp2); err != nil {
		t.Fatal(err)
	}
	if len(resp2.Findings) != 1 || resp2.Findings[0].RuleID != "check-not-allowed" {
		t.Fatalf("expected 1 finding for check-not-allowed, got %+v", resp2.Findings)
	}

	// 3. Cleartext actor with actor_is_pseudonym: true should NOT match pseudonymised allowlist
	w3 := postObservation(t, h, `{
	  "tenant_id": "kusari",
	  "actor_is_pseudonym": true,
	  "observation": {
	    "id": "obs-fake-pseudonym",
	    "timestamp": "2026-10-04T08:00:00Z",
	    "layer": "cloud_control_plane",
	    "actor": "arn:aws:iam::123456789012:user/allowed-admin"
	  }
	}`, nil)
	var resp3 EvaluateObservationResponse
	json.Unmarshal(w3.Body.Bytes(), &resp3)
	if len(resp3.Findings) != 1 || resp3.Findings[0].RuleID != "check-not-allowed" {
		t.Fatalf("cleartext actor with actor_is_pseudonym:true must not match pseudonymised bundle var, got %+v", resp3.Findings)
	}
}

// TestEvaluateObservationReproducesTheKusariGolden asserts that evaluating the Kusari corpus
// through HandleEvaluateObservation reproduces the exact canonical findings in kusari-canonical-findings.txt.
func TestEvaluateObservationReproducesTheKusariGolden(t *testing.T) {
	t.Setenv("SIGNAL_SEGMENT_PSEUDONYM_KEY", testSegmentRootKeyHex)
	t.Setenv("SIGNAL_SEGMENT_PSEUDONYM_EPOCH", "1")

	engine, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	store := NewPolicyStore(engine)
	key, _ := hex.DecodeString(testSegmentRootKeyHex)
	store.SetPseudonymConfig(key, 1)

	if _, err := store.LoadObservationBundles(shippedBundlesDir); err != nil {
		t.Fatalf("LoadObservationBundles: %v", err)
	}

	ev, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatal(err)
	}
	h := NewObservationHandlers(store, ev).HandleEvaluateObservation

	corpusBytes, err := os.ReadFile(filepath.Join("..", "..", "pkg", "obscel", "testdata", "kusari-corpus.json"))
	if err != nil {
		t.Fatalf("reading corpus: %v", err)
	}
	var observations []obscel.Observation
	if err := json.Unmarshal(corpusBytes, &observations); err != nil {
		t.Fatalf("unmarshal corpus: %v", err)
	}

	findingsBytes, err := os.ReadFile(filepath.Join("..", "..", "pkg", "obscel", "testdata", "kusari-canonical-findings.txt"))
	if err != nil {
		t.Fatalf("reading golden findings: %v", err)
	}
	wantGolden := strings.TrimSpace(string(findingsBytes))

	var gotCanonical []string
	for _, obs := range observations {
		reqBody, _ := json.Marshal(EvaluateObservationRequest{
			TenantID:         "kusari",
			Observation:      obs,
			ActorIsPseudonym: false,
		})
		req := httptest.NewRequest(http.MethodPost, "/api/v1/observations/evaluate", bytes.NewReader(reqBody))
		w := httptest.NewRecorder()
		h(w, req)
		if w.Code != http.StatusOK {
			t.Fatalf("evaluating observation %s returned %d: %s", obs.ID, w.Code, w.Body.String())
		}
		var resp EvaluateObservationResponse
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("unmarshal resp: %v", err)
		}
		for _, f := range resp.Findings {
			gotCanonical = append(gotCanonical, obscel.CanonicalFinding(f))
		}
	}

	sort.Strings(gotCanonical)
	gotText := strings.TrimSpace(strings.Join(gotCanonical, "\n"))

	if gotText != wantGolden {
		t.Fatalf("dry-run evaluation does not match kusari golden findings:\n got:\n%s\nwant:\n%s", gotText, wantGolden)
	}
}

func TestObservationRoutes_MethodGatingAndHEAD(t *testing.T) {
	h := newObservationHandler(t, shippedBundlesDir)
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/observations/evaluate", h)
	srv := httptest.NewServer(headBodySuppressingMiddleware(mux))
	defer srv.Close()

	// 1. HEAD /api/v1/observations/evaluate -> 405 Method Not Allowed with Allow: POST and 0 body bytes
	headReq, err := http.NewRequest(http.MethodHead, srv.URL+"/api/v1/observations/evaluate", nil)
	if err != nil {
		t.Fatalf("HEAD request create failed: %v", err)
	}
	headResp, err := http.DefaultClient.Do(headReq)
	if err != nil {
		t.Fatalf("HEAD failed: %v", err)
	}
	headBody, _ := io.ReadAll(headResp.Body)
	headResp.Body.Close()
	if headResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("expected 405 on HEAD, got %d", headResp.StatusCode)
	}
	if allow := headResp.Header.Get("Allow"); allow != "POST, OPTIONS" {
		t.Errorf("expected Allow: POST, OPTIONS on HEAD, got %q", allow)
	}
	if len(headBody) != 0 {
		t.Errorf("expected 0 body bytes on HEAD, got %d", len(headBody))
	}

	// 2. GET /api/v1/observations/evaluate -> 405 Method Not Allowed with Allow: POST, OPTIONS
	getReq, err := http.NewRequest(http.MethodGet, srv.URL+"/api/v1/observations/evaluate", nil)
	if err != nil {
		t.Fatalf("GET request create failed: %v", err)
	}
	getResp, err := http.DefaultClient.Do(getReq)
	if err != nil {
		t.Fatalf("GET failed: %v", err)
	}
	getResp.Body.Close()
	if getResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("expected 405 on GET, got %d", getResp.StatusCode)
	}
	if allow := getResp.Header.Get("Allow"); allow != "POST, OPTIONS" {
		t.Errorf("expected Allow: POST, OPTIONS on GET, got %q", allow)
	}
}
