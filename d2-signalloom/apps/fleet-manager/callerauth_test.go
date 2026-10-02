package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"k8s.io/client-go/kubernetes/fake"
	k8stesting "k8s.io/client-go/testing"
)

// The mutating fleet routes answer only a named caller key with the route's
// scope. Driven through s.routes(), the mux main serves.

const (
	sentinelKey = "sentinel-key-0123456789abcdef"
	feKey       = "fe-signalloom-key-0123456789ab"
	operatorKey = "operator-key-0123456789abcdef0"
)

func testCallerKeys(t *testing.T) *callerKeys {
	t.Helper()
	keys, err := loadCallerKeys([]string{
		"FLEET_MANAGER_KEY_STUN_SENTINEL=" + sentinelKey,
		"FLEET_MANAGER_KEY_STUN_SENTINEL_SCOPES=stun",
		"FLEET_MANAGER_KEY_FE_SIGNALLOOM=" + feKey,
		"FLEET_MANAGER_KEY_FE_SIGNALLOOM_SCOPES=stun",
		"FLEET_MANAGER_KEY_OPERATOR=" + operatorKey,
		"FLEET_MANAGER_KEY_OPERATOR_SCOPES=stun,resume,recover,deploy,scan,reset",
		"UNRELATED=1",
	})
	if err != nil {
		t.Fatal(err)
	}
	return keys
}

func call(t *testing.T, h http.Handler, method, path, body string, headers ...string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	for _, v := range headers {
		req.Header.Add("Authorization", v)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	return w
}

// pinWrites counts the gitops plane's reconcile=disabled patches per kind.
func pinWrites(cs *fake.Clientset) (pods, deployments int) {
	for _, a := range cs.Actions() {
		p, ok := a.(k8stesting.PatchAction)
		if !ok || !strings.Contains(string(p.GetPatch()), fluxReconcileKey) {
			continue
		}
		switch p.GetResource().Resource {
		case "pods":
			pods++
		case "deployments":
			deployments++
		}
	}
	return
}

const sentinelStunBody = `{"reason":"stun-sentinel detection: sys_enter_openat /etc/passwd"}`

func TestStunWithoutACallerKeyIs401AndContainsNothing(t *testing.T) {
	s, cs, _ := newGitopsServer(t, ownedChain("active", nil, nil)...)
	s.callerKeys = testCallerKeys(t)
	for name, hdrs := range map[string][]string{
		"no header":        nil,
		"empty bearer":     {"Bearer "},
		"basic scheme":     {"Basic " + sentinelKey},
		"lowercase bearer": {"bearer " + sentinelKey},
		"two headers":      {"Bearer " + sentinelKey, "Bearer " + sentinelKey},
		"unknown key":      {"Bearer not-a-key-anyone-holds-0000"},
		"key prefix":       {"Bearer " + sentinelKey[:len(sentinelKey)-1]},
		"key plus suffix":  {"Bearer " + sentinelKey + "x"},
	} {
		w := call(t, s.routes(), http.MethodPost, "/api/v1/fleet/stun/"+gitopsAgent, sentinelStunBody, hdrs...)
		if w.Code != http.StatusUnauthorized || !strings.Contains(w.Header().Get("WWW-Authenticate"), "Bearer") {
			t.Errorf("%s: status %d, WWW-Authenticate %q; want 401 with a Bearer challenge", name, w.Code, w.Header().Get("WWW-Authenticate"))
		}
	}
	if len(cs.Actions()) != 0 {
		t.Fatalf("an unauthenticated stun reached the API server: %d actions", len(cs.Actions()))
	}
}

func TestNoConfiguredKeysMeansNoAnonymousStun(t *testing.T) {
	s, cs, _ := newGitopsServer(t, ownedChain("active", nil, nil)...)
	w := call(t, s.routes(), http.MethodPost, "/api/v1/fleet/stun/"+gitopsAgent, sentinelStunBody, "Bearer "+sentinelKey)
	if w.Code != http.StatusUnauthorized || len(cs.Actions()) != 0 {
		t.Fatalf("status %d, %d API actions; want 401 and none", w.Code, len(cs.Actions()))
	}
}

func TestEveryMutatingRouteNeedsAKeyAndReadsDoNot(t *testing.T) {
	s := newTestServer(t)
	s.callerKeys = testCallerKeys(t)
	h := s.routes()
	for _, p := range []string{"/api/v1/fleet/stun/a", "/api/v1/fleet/resume", "/api/v1/fleet/resume/a",
		"/api/v1/fleet/recover", "/api/v1/fleet/deploy", "/api/v1/fleet/scan", "/api/v1/fleet/reset"} {
		if w := call(t, h, http.MethodPost, p, "{}"); w.Code != http.StatusUnauthorized {
			t.Errorf("POST %s without a key: %d, want 401", p, w.Code)
		}
	}
	for _, p := range []string{"/health", "/api/v1/fleet/topology"} {
		if w := call(t, h, http.MethodGet, p, ""); w.Code != http.StatusOK {
			t.Errorf("GET %s: %d, want 200 (reads stay open)", p, w.Code)
		}
	}
}

func TestAStunOnlyKeyCannotRecoverResumeOrReset(t *testing.T) {
	s, cs, _ := newGitopsServer(t, ownedChain("stunned", nil, nil)...)
	s.callerKeys = testCallerKeys(t)
	for _, key := range []string{sentinelKey, feKey} {
		for _, p := range []string{"/api/v1/fleet/recover", "/api/v1/fleet/resume/" + gitopsAgent,
			"/api/v1/fleet/reset", "/api/v1/fleet/deploy", "/api/v1/fleet/scan"} {
			w := call(t, s.routes(), http.MethodPost, p, `{"agent_ids":["`+gitopsAgent+`"]}`, "Bearer "+key)
			if w.Code != http.StatusForbidden {
				t.Errorf("stun-only key on %s: %d, want 403", p, w.Code)
			}
		}
	}
	if len(cs.Actions()) != 0 {
		t.Fatalf("a refused call reached the API server: %d actions", len(cs.Actions()))
	}
}

func TestSentinelKeyRunsTheStunCascadeOnceWithOnePinWriter(t *testing.T) {
	s, cs, _ := newGitopsServer(t, ownedChain("active", nil, nil)...)
	s.callerKeys = testCallerKeys(t)
	w := call(t, s.routes(), http.MethodPost, "/api/v1/fleet/stun/"+gitopsAgent, sentinelStunBody, "Bearer "+sentinelKey)
	if w.Code != http.StatusOK {
		t.Fatalf("sentinel stun: %d %s", w.Code, w.Body.String())
	}
	if got := w.Header().Get(callerHeader); got != "stun-sentinel" {
		t.Fatalf("%s = %q, want stun-sentinel", callerHeader, got)
	}
	if pods, deps := pinWrites(cs); pods != 1 || deps != 1 {
		t.Fatalf("reconcile=disabled writes: pod %d, deployment %d; want exactly one each", pods, deps)
	}
	pod, dep := getPod(t, cs), getDeployment(t, cs)
	if pod.Annotations[fluxReconcileKey] != "disabled" || dep.Annotations[fluxReconcileKey] != "disabled" {
		t.Fatalf("pins: pod %q deployment %q", pod.Annotations[fluxReconcileKey], dep.Annotations[fluxReconcileKey])
	}
	if got := pod.Annotations[StunReasonAnnotationIO]; got != "stun-sentinel detection: sys_enter_openat /etc/passwd" {
		t.Fatalf("stun reason on the pod = %q", got)
	}
}

func TestADuplicateSentinelStunIsIdempotent(t *testing.T) {
	s, cs, client := newGitopsServer(t, ownedChain("active", nil, nil)...)
	s.callerKeys = testCallerKeys(t)
	h := s.routes()
	clock := time.Date(2026, 10, 2, 21, 0, 0, 0, time.UTC)
	client.now = func() time.Time { return clock }
	first := call(t, h, http.MethodPost, "/api/v1/fleet/stun/"+gitopsAgent, sentinelStunBody, "Bearer "+sentinelKey)
	stunnedAt := getPod(t, cs).Annotations[StunnedAtAnnotation]
	clock = clock.Add(time.Hour) // the replay arrives later: a restamp would show
	replay := call(t, h, http.MethodPost, "/api/v1/fleet/stun/"+gitopsAgent, sentinelStunBody, "Bearer "+sentinelKey)
	if first.Code != http.StatusOK || replay.Code != http.StatusOK {
		t.Fatalf("first %d, replay %d; want 200 both", first.Code, replay.Code)
	}
	pod, dep := getPod(t, cs), getDeployment(t, cs)
	if pod.Annotations[StunnedAtAnnotation] != stunnedAt || stunnedAt == "" {
		t.Fatalf("a replayed stun restamped stunned-at: %q -> %q", stunnedAt, pod.Annotations[StunnedAtAnnotation])
	}
	if pod.Labels[StunnedLabel] != "true" || pod.Annotations[fluxReconcileKey] != "disabled" || dep.Annotations[fluxReconcileKey] != "disabled" {
		t.Fatalf("replay left a different end state: labels %v, pod pin %q, deployment pin %q",
			pod.Labels, pod.Annotations[fluxReconcileKey], dep.Annotations[fluxReconcileKey])
	}
}

func TestCallerKeyConfigurationDefectsAreRefused(t *testing.T) {
	for name, env := range map[string][]string{
		"no scopes":          {"FLEET_MANAGER_KEY_A=" + sentinelKey},
		"empty scopes":       {"FLEET_MANAGER_KEY_A=" + sentinelKey, "FLEET_MANAGER_KEY_A_SCOPES= "},
		"unknown scope":      {"FLEET_MANAGER_KEY_A=" + sentinelKey, "FLEET_MANAGER_KEY_A_SCOPES=stun,admin"},
		"short key":          {"FLEET_MANAGER_KEY_A=short", "FLEET_MANAGER_KEY_A_SCOPES=stun"},
		"shared key":         {"FLEET_MANAGER_KEY_A=" + sentinelKey, "FLEET_MANAGER_KEY_A_SCOPES=stun", "FLEET_MANAGER_KEY_B=" + sentinelKey, "FLEET_MANAGER_KEY_B_SCOPES=recover"},
		"scopes without key": {"FLEET_MANAGER_KEY_A_SCOPES=stun"},
	} {
		if _, err := loadCallerKeys(env); err == nil {
			t.Errorf("%s: accepted; want a configuration error", name)
		} else if strings.Contains(err.Error(), sentinelKey) {
			t.Errorf("%s: the error leaks the key: %v", name, err)
		}
	}
}
