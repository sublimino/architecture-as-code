package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	spiretypes "github.com/spiffe/spire-api-sdk/proto/spire/api/types"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"
)

// ── Fakes ────────────────────────────────────────────────────────────────────

// fakeTokenCounter stands in for OpenBaoClient.ActiveTokensBySubject. The HTTP
// behaviour of the real method is pinned in openbao_token_test.go; one test
// below also drives the checker through a real OpenBaoClient + httptest server.
type fakeTokenCounter struct {
	configured bool
	counts     map[string]int
	err        error
	calls      int
}

func (f *fakeTokenCounter) TokenConfigured() bool { return f.configured }
func (f *fakeTokenCounter) ActiveTokensBySubject(context.Context) (map[string]int, error) {
	f.calls++
	return f.counts, f.err
}

type fakeEntryLister struct {
	entries map[string]int // spiffe id -> number of entries
	err     error
}

func (f *fakeEntryLister) ListEntriesBySPIFFEID(_ context.Context, id string) ([]*spiretypes.Entry, error) {
	if f.err != nil {
		return nil, f.err
	}
	out := make([]*spiretypes.Entry, f.entries[id])
	for i := range out {
		out[i] = &spiretypes.Entry{Id: "entry"}
	}
	return out, nil
}

const (
	consTestAgent  = "agent-cardvault"
	consTestSA     = "agent-cardvault"
	consTestSPIFFE = "spiffe://signalloom.demo/ns/" + testNamespace + "/sa/" + consTestSA
)

func consPod(stunned bool, podPinned bool) *corev1.Pod {
	state, mode, flag := "active", ContainmentModeNone, "false"
	if stunned {
		state, mode, flag = StateStunned, ContainmentModeFrozen, "true"
	}
	pod := agentPod(consTestAgent, state, map[string]string{ContainmentModeLabel: mode, StunnedLabel: flag})
	pod.Spec.ServiceAccountName = consTestSA
	if podPinned {
		pod.Annotations = map[string]string{consistencyPinAnnotation: consistencyPinValue}
	}
	return pod
}

func consDeployment(pinned bool) *appsv1.Deployment {
	d := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: consTestAgent, Namespace: testNamespace}}
	if pinned {
		d.Annotations = map[string]string{consistencyPinAnnotation: consistencyPinValue}
	}
	return d
}

func consDAG(t *testing.T, ids ...string) *DAG {
	t.Helper()
	agents := make([]Agent, 0, len(ids))
	for _, id := range ids {
		agents = append(agents, Agent{ID: id, Namespace: testNamespace})
	}
	dag, err := BuildDAG(agents)
	if err != nil {
		t.Fatal(err)
	}
	return dag
}

func newTestChecker(t *testing.T, bao consistencyTokenCounter, spire consistencyEntryLister, objects ...runtime.Object) (*consistencyChecker, *bytes.Buffer) {
	t.Helper()
	kc := newK8sFleetClient(fake.NewSimpleClientset(objects...), testNamespace)
	logBuf := &bytes.Buffer{}
	c := newConsistencyChecker(consDAG(t, consTestAgent), kc, bao, spire)
	c.logger = slog.New(slog.NewJSONHandler(logBuf, nil))
	c.now = func() time.Time { return time.Date(2026, 9, 29, 12, 0, 0, 0, time.UTC) }
	return c, logBuf
}

func getConsistency(t *testing.T, c *consistencyChecker, agentID string) (int, ConsistencyReport) {
	t.Helper()
	mux := http.NewServeMux()
	c.register(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/fleet/consistency/"+agentID, nil))
	var rep ConsistencyReport
	if rec.Code != http.StatusNotFound {
		if err := json.Unmarshal(rec.Body.Bytes(), &rep); err != nil {
			t.Fatalf("decode body %q: %v", rec.Body.String(), err)
		}
	}
	return rec.Code, rep
}

func splitBrainHas(rep ConsistencyReport, want string) bool {
	for _, s := range rep.SplitBrain {
		if s == want {
			return true
		}
	}
	return false
}

// ── Stunned pod ──────────────────────────────────────────────────────────────

func TestConsistency_StunnedPodWithLiveCredentialsIsSplitBrain(t *testing.T) {
	bao := &fakeTokenCounter{configured: true, counts: map[string]int{consTestSPIFFE: 2}}
	spire := &fakeEntryLister{entries: map[string]int{consTestSPIFFE: 1}}
	c, _ := newTestChecker(t, bao, spire, consPod(true, true), consDeployment(false))

	code, rep := getConsistency(t, c, consTestAgent)
	if code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (every plane answered; inconsistency is a finding, not an outage)", code)
	}
	if rep.Consistent {
		t.Fatalf("consistent = true, want false")
	}
	if !rep.Pod.Found || !rep.Pod.Stunned || rep.Pod.State != StateStunned || rep.Pod.ContainmentMode != ContainmentModeFrozen {
		t.Fatalf("pod = %+v, want found stunned frozen", rep.Pod)
	}
	if rep.Bao.ActiveTokens != 2 || !rep.Bao.Configured {
		t.Fatalf("bao = %+v, want configured with 2 active tokens", rep.Bao)
	}
	for _, want := range []string{
		"pod stunned but 2 openbao tokens active",
		"pod stunned but spire entry present",
		"pod stunned but deployment not pinned",
	} {
		if !splitBrainHas(rep, want) {
			t.Errorf("split_brain missing %q; got %q", want, rep.SplitBrain)
		}
	}
	if len(rep.SplitBrain) != 3 {
		t.Fatalf("split_brain = %q, want exactly 3 findings (pod IS pinned)", rep.SplitBrain)
	}
}

func TestConsistency_StunnedPodFullyContainedIsConsistent(t *testing.T) {
	bao := &fakeTokenCounter{configured: true, counts: map[string]int{"spiffe://signalloom.demo/ns/x/sa/other": 4}}
	spire := &fakeEntryLister{entries: map[string]int{}}
	c, _ := newTestChecker(t, bao, spire, consPod(true, true), consDeployment(true))

	code, rep := getConsistency(t, c, consTestAgent)
	if code != http.StatusOK || !rep.Consistent || len(rep.SplitBrain) != 0 {
		t.Fatalf("code=%d consistent=%v split_brain=%q, want 200 true []", code, rep.Consistent, rep.SplitBrain)
	}
	if rep.Bao.ActiveTokens != 0 || rep.Spire.EntryPresent || !rep.GitOps.DeploymentPinned || !rep.GitOps.PodPinned {
		t.Fatalf("planes = %+v %+v %+v, want 0 tokens, no entry, both pinned", rep.Bao, rep.Spire, rep.GitOps)
	}
	if rep.AgentID != consTestAgent || rep.CheckedAt != "2026-09-29T12:00:00Z" {
		t.Fatalf("agent_id=%q checked_at=%q", rep.AgentID, rep.CheckedAt)
	}
}

// ── Active pod ───────────────────────────────────────────────────────────────

func TestConsistency_ActivePodExpectsTheOpposite(t *testing.T) {
	bao := &fakeTokenCounter{configured: true, counts: map[string]int{consTestSPIFFE: 1}}
	spire := &fakeEntryLister{entries: map[string]int{consTestSPIFFE: 1}}
	c, _ := newTestChecker(t, bao, spire, consPod(false, false), consDeployment(false))
	code, rep := getConsistency(t, c, consTestAgent)
	if code != http.StatusOK || !rep.Consistent || len(rep.SplitBrain) != 0 {
		t.Fatalf("code=%d consistent=%v split_brain=%q, want a consistent active agent", code, rep.Consistent, rep.SplitBrain)
	}
	if rep.Bao.ActiveTokens != 1 || !rep.Spire.EntryPresent {
		t.Fatalf("bao=%+v spire=%+v", rep.Bao, rep.Spire)
	}
}

func TestConsistency_ActivePodLeftPinnedAndUncredentialled(t *testing.T) {
	bao := &fakeTokenCounter{configured: true, counts: map[string]int{}}
	spire := &fakeEntryLister{entries: map[string]int{}}
	c, _ := newTestChecker(t, bao, spire, consPod(false, true), consDeployment(true))
	_, rep := getConsistency(t, c, consTestAgent)
	for _, want := range []string{
		"pod active but 0 openbao tokens active",
		"pod active but no spire entry",
		"pod active but deployment pinned",
		"pod active but pod pinned",
	} {
		if !splitBrainHas(rep, want) {
			t.Errorf("split_brain missing %q; got %q", want, rep.SplitBrain)
		}
	}
	if rep.Consistent || len(rep.SplitBrain) != 4 {
		t.Fatalf("consistent=%v split_brain=%q, want false and 4 findings", rep.Consistent, rep.SplitBrain)
	}
}

func TestConsistency_ContainmentLabelsDisagreeIsSplitBrain(t *testing.T) {
	// The sentinel ORs the three terms; a state label saying active while
	// containment-mode stays frozen is exactly the reassuring lie enforcement.go
	// warns about.
	pod := consPod(false, true)
	pod.Labels[ContainmentModeLabel] = ContainmentModeFrozen
	bao := &fakeTokenCounter{configured: true, counts: map[string]int{}}
	spire := &fakeEntryLister{entries: map[string]int{}}
	c, _ := newTestChecker(t, bao, spire, pod, consDeployment(true))
	_, rep := getConsistency(t, c, consTestAgent)
	if !rep.Pod.Stunned {
		t.Fatalf("pod.stunned = false; containment-mode=frozen alone freezes the pod")
	}
	want := `pod containment labels disagree: state="active" stunned="false" containment-mode="frozen"`
	if !splitBrainHas(rep, want) || len(rep.SplitBrain) != 1 {
		t.Fatalf("split_brain = %q, want exactly [%s]", rep.SplitBrain, want)
	}
}

// ── Unknown agents and unqueried planes ──────────────────────────────────────

func TestConsistency_UnknownAgentIs404(t *testing.T) {
	c, _ := newTestChecker(t, &fakeTokenCounter{configured: true}, &fakeEntryLister{})
	code, _ := getConsistency(t, c, "agent-nobody")
	if code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", code)
	}
}

func TestConsistency_UnqueryablePlaneIs503AndNeverConsistent(t *testing.T) {
	// Pod stunned, SPIRE clean, GitOps pinned: every plane that answered agrees.
	// OpenBao did not answer, so the verdict must not be "consistent".
	bao := &fakeTokenCounter{configured: true, err: errors.New("dial tcp: connection refused")}
	spire := &fakeEntryLister{entries: map[string]int{}}
	c, _ := newTestChecker(t, bao, spire, consPod(true, true), consDeployment(true))
	code, rep := getConsistency(t, c, consTestAgent)
	if code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", code)
	}
	if rep.Consistent {
		t.Fatalf("consistent = true with an unqueried OpenBao plane")
	}
	if !strings.Contains(rep.Bao.Error, "connection refused") || rep.Bao.ActiveTokens != 0 {
		t.Fatalf("bao = %+v, want the error surfaced", rep.Bao)
	}
	if len(rep.SplitBrain) != 0 {
		t.Fatalf("split_brain = %q; an unqueried plane is not evidence of a split", rep.SplitBrain)
	}
}

func TestConsistency_UnconfiguredPlanesAre503(t *testing.T) {
	c, _ := newTestChecker(t, &fakeTokenCounter{configured: false}, nil, consPod(true, true), consDeployment(true))
	code, rep := getConsistency(t, c, consTestAgent)
	if code != http.StatusServiceUnavailable || rep.Consistent {
		t.Fatalf("code=%d consistent=%v, want 503 false", code, rep.Consistent)
	}
	if rep.Bao.Configured || rep.Spire.Configured {
		t.Fatalf("bao.configured=%v spire.configured=%v, want both false", rep.Bao.Configured, rep.Spire.Configured)
	}
	if rep.Bao.Error == "" || rep.Spire.Error == "" {
		t.Fatalf("bao.error=%q spire.error=%q, want both to say why", rep.Bao.Error, rep.Spire.Error)
	}
}

func TestConsistency_AbsentPodWithLiveTokens(t *testing.T) {
	bao := &fakeTokenCounter{configured: true, counts: map[string]int{consTestSPIFFE: 3}}
	c, _ := newTestChecker(t, bao, &fakeEntryLister{entries: map[string]int{consTestSPIFFE: 1}})
	code, rep := getConsistency(t, c, consTestAgent)
	if code != http.StatusOK || rep.Pod.Found || rep.Pod.State != "absent" {
		t.Fatalf("code=%d pod=%+v, want 200 with found=false state=absent", code, rep.Pod)
	}
	if !splitBrainHas(rep, "pod absent but 3 openbao tokens active") || len(rep.SplitBrain) != 1 {
		t.Fatalf("split_brain = %q, want only the token finding", rep.SplitBrain)
	}
}

func TestConsistency_DeploymentResolvedThroughReplicaSetOwner(t *testing.T) {
	pod := consPod(true, true)
	pod.Name = "agent-cardvault-bb57657-jlf8w"
	pod.OwnerReferences = []metav1.OwnerReference{{Kind: "ReplicaSet", Name: "cardvault-deploy-bb57657"}}
	dep := consDeployment(true)
	dep.Name = "cardvault-deploy"
	bao := &fakeTokenCounter{configured: true, counts: map[string]int{}}
	c, _ := newTestChecker(t, bao, &fakeEntryLister{entries: map[string]int{}}, pod, dep)
	_, rep := getConsistency(t, c, consTestAgent)
	if !rep.GitOps.DeploymentFound || rep.GitOps.Deployment != "cardvault-deploy" || !rep.GitOps.DeploymentPinned {
		t.Fatalf("gitops = %+v, want deployment cardvault-deploy found and pinned", rep.GitOps)
	}
	if !rep.Consistent {
		t.Fatalf("split_brain = %q", rep.SplitBrain)
	}
}

// ── Through a real OpenBaoClient ─────────────────────────────────────────────

func TestConsistency_RealOpenBaoClientCounts(t *testing.T) {
	srv, _ := newFakeBaoAccessorServer(t, map[string]*fakeBaoToken{
		"a1": {displayName: "jwt-" + consTestSPIFFE},
	}, []string{"a1"})
	defer srv.Close()
	bao := NewOpenBaoClient(OpenBaoConfig{Address: srv.URL, Token: "s.fleet", LogWriter: io.Discard})
	c, _ := newTestChecker(t, bao, &fakeEntryLister{entries: map[string]int{}}, consPod(true, true), consDeployment(true))
	_, rep := getConsistency(t, c, consTestAgent)
	if rep.Bao.ActiveTokens != 1 || !splitBrainHas(rep, "pod stunned but 1 openbao tokens active") {
		t.Fatalf("bao=%+v split_brain=%q", rep.Bao, rep.SplitBrain)
	}
}

// ── Reconciler and metrics ───────────────────────────────────────────────────

func TestConsistency_ReconcileOnceLogsAndCounts(t *testing.T) {
	bao := &fakeTokenCounter{configured: true, counts: map[string]int{consTestSPIFFE: 2}}
	spire := &fakeEntryLister{entries: map[string]int{consTestSPIFFE: 1}}
	c, logBuf := newTestChecker(t, bao, spire, consPod(true, true), consDeployment(true))
	c.dag = consDAG(t, consTestAgent, "agent-absent")

	c.reconcileOnce(context.Background())
	c.reconcileOnce(context.Background())

	if bao.calls != 2 {
		t.Fatalf("OpenBao enumerated %d times for 2 rounds over 2 agents, want 2 (one snapshot per round)", bao.calls)
	}

	var events []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(logBuf.String()), "\n") {
		var ev map[string]any
		if json.Unmarshal([]byte(line), &ev) == nil && ev["event"] == "split_brain" {
			events = append(events, ev)
		}
	}
	if len(events) != 4 {
		t.Fatalf("split_brain events = %d, want 4 (2 findings x 2 rounds); log:\n%s", len(events), logBuf.String())
	}
	if events[0]["agent_id"] != consTestAgent || events[0]["finding"] != "pod stunned but 2 openbao tokens active" {
		t.Fatalf("first event = %v", events[0])
	}

	mux := http.NewServeMux()
	c.register(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := rec.Body.String()
	for _, want := range []string{
		"# TYPE fleet_consistency_checks_total counter\nfleet_consistency_checks_total 4\n",
		"# TYPE fleet_split_brain_total counter\n",
		`fleet_split_brain_total{agent="agent-cardvault"} 4` + "\n",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("/metrics missing %q; body:\n%s", want, body)
		}
	}
	if strings.Contains(body, `fleet_split_brain_total{agent="agent-absent"}`) {
		t.Errorf("absent agent with no findings must not appear in split_brain_total:\n%s", body)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/plain") {
		t.Errorf("Content-Type = %q, want text/plain", ct)
	}
}

func TestConsistencyIntervalFromEnv(t *testing.T) {
	cases := map[string]time.Duration{
		"":      60 * time.Second,
		"0":     0,
		"30s":   30 * time.Second,
		"45":    45 * time.Second,
		"bogus": 60 * time.Second,
		"-5s":   60 * time.Second,
	}
	for in, want := range cases {
		t.Setenv("CONSISTENCY_INTERVAL", in)
		if got := consistencyIntervalFromEnv(); got != want {
			t.Errorf("CONSISTENCY_INTERVAL=%q -> %v, want %v", in, got, want)
		}
	}
}

func TestRegisterConsistencyRoutes_WiresRealClientPlanes(t *testing.T) {
	kc := newK8sFleetClient(fake.NewSimpleClientset(), testNamespace)
	kc.spireClient = &countingSpireClient{}
	s := &server{dag: consDAG(t, consTestAgent), enforcement: &fleetClientSelection{Client: kc}}
	t.Setenv("CONSISTENCY_INTERVAL", "0")
	c := registerConsistencyRoutes(http.NewServeMux(), s)
	if c.bao == nil || c.spire == nil || c.clientset == nil {
		t.Fatalf("checker planes bao=%v spire=%v clientset=%v, want all wired from the k8s fleet client", c.bao, c.spire, c.clientset)
	}

	// A non-kubernetes client (noop / unavailable) leaves the pod plane unqueried.
	s2 := &server{dag: consDAG(t, consTestAgent), enforcement: &fleetClientSelection{Client: &noopFleetClient{}}}
	c2 := registerConsistencyRoutes(http.NewServeMux(), s2)
	code, rep := getConsistency(t, c2, consTestAgent)
	if code != http.StatusServiceUnavailable || rep.Consistent || rep.Pod.Error == "" {
		t.Fatalf("code=%d consistent=%v pod=%+v, want 503 with a pod-plane error", code, rep.Consistent, rep.Pod)
	}
}
