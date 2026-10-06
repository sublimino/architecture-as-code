package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"
)

// ── What this suite pins (kusari-e2e FIX-A item 2) ───────────────────────────
//
// The dashboard and the integration proxy identify agents by POD NAME
// (agent-cardvault-bb57657-jlf8w). fe-signalloom passes that straight through,
// and handleStun answered 404 because the DAG only knows agent-cardvault.
// resolveAgentID maps what the caller sent onto a DAG id:
//
//	(a) exact DAG id
//	(b) the pod's signalloom.ai/agent-name=<n> label, when agent-<n> is in the DAG
//	(c) the pod name minus its two trailing -<hash> segments (ReplicaSet pod)
//	(d) otherwise 404 {"error":"unknown agent","tried":[...]}
//
// The live cardvault pod carries NO agent-name label (checked read-only on
// kind-osramp), so branch (c) is what makes the dashboard's stun work.

// The live pod names, verbatim.
const (
	livePodCardvault = "agent-cardvault-bb57657-jlf8w"
	livePodKusari    = "agent-kusari-5685ff664b-46q85"
)

func resolutionDAG(t *testing.T) *DAG {
	t.Helper()
	dag, err := BuildDAG([]Agent{
		{ID: "agent-cardvault", Type: "service", Namespace: testNamespace, State: StateRunning},
		{ID: kusariAgentID, Type: "service", Namespace: testNamespace, State: StateRunning},
	})
	if err != nil {
		t.Fatalf("BuildDAG: %v", err)
	}
	return dag
}

// livePod builds a pod as it exists on the cluster: an agent-name label only
// when one is given.
func livePod(name, agentNameLabel string) *corev1.Pod {
	labels := map[string]string{AgentLabel: "true"}
	if agentNameLabel != "" {
		labels[AgentNameLabel] = agentNameLabel
	}
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: testNamespace, Labels: labels},
		Spec:       corev1.PodSpec{ServiceAccountName: "sa-" + name},
	}
}

func resolutionServer(t *testing.T, objects ...runtime.Object) (*server, *fake.Clientset) {
	t.Helper()
	real, cs := newTestK8sClient(objects...)
	client := credOKClient{k8sFleetClient: real}
	dag := resolutionDAG(t)
	return &server{dag: dag, orchestrator: NewCascadeOrchestrator(dag, client, 0)}, cs
}

func TestResolveAgentID_ExactDAGID(t *testing.T) {
	s, cs := resolutionServer(t)
	got, err := s.resolveAgentID(context.Background(), "agent-cardvault")
	if err != nil || got.ID != "agent-cardvault" || got.By != "exact" {
		t.Fatalf("resolve = %+v, %v; want agent-cardvault", got, err)
	}
	if n := len(cs.Actions()); n != 0 {
		t.Fatalf("an exact DAG id must not touch the API server, saw %d actions", n)
	}
}

func TestResolveAgentID_AgentNameLabel(t *testing.T) {
	s, _ := resolutionServer(t, livePod(livePodKusari, "kusari-agent"))
	got, err := s.resolveAgentID(context.Background(), livePodKusari)
	if err != nil || got.ID != kusariAgentID || got.By != "label" {
		t.Fatalf("resolve = %+v, %v; want %s via the agent-name label", got, err, kusariAgentID)
	}
}

func TestResolveAgentID_ReplicaSetPodNameWithoutLabel(t *testing.T) {
	s, _ := resolutionServer(t, livePod(livePodCardvault, ""))
	got, err := s.resolveAgentID(context.Background(), livePodCardvault)
	if err != nil || got.ID != "agent-cardvault" || got.By != "replicaset-pattern" {
		t.Fatalf("resolve = %+v, %v; want agent-cardvault via the ReplicaSet name pattern", got, err)
	}
}

func TestResolveAgentID_LabelNotInDAGFallsThroughToReplicaSetPattern(t *testing.T) {
	// A label that names no DAG agent must not stop resolution.
	s, _ := resolutionServer(t, livePod(livePodCardvault, "something-else"))
	got, err := s.resolveAgentID(context.Background(), livePodCardvault)
	if err != nil || got.ID != "agent-cardvault" {
		t.Fatalf("resolve = %+v, %v; want agent-cardvault", got, err)
	}
}

func TestResolveAgentID_UnknownIsNotFoundWithTried(t *testing.T) {
	cases := map[string]struct {
		id      string
		objects []runtime.Object
	}{
		"no such pod":            {id: "agent-ghost-abc123-xyz45"},
		"pod matches no DAG id":  {id: "zulip-chat-agent-97b66db85-8dvqk", objects: []runtime.Object{livePod("zulip-chat-agent-97b66db85-8dvqk", "")}},
		"pod name too short (c)": {id: "agent-cardvault-x", objects: []runtime.Object{livePod("agent-cardvault-x", "")}},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			s, _ := resolutionServer(t, tc.objects...)
			got, err := s.resolveAgentID(context.Background(), tc.id)
			if !errors.Is(err, errUnknownAgent) {
				t.Fatalf("resolve = %+v, %v; want errUnknownAgent", got, err)
			}
			if len(got.Tried) == 0 || got.Tried[0] != "dag:"+tc.id {
				t.Fatalf("tried = %q, want it to start with the exact DAG lookup", got.Tried)
			}
		})
	}
}

func TestHandleStun_PodNameResolvesToDAGAgent(t *testing.T) {
	s, _ := resolutionServer(t, livePod(livePodCardvault, ""))
	body := `{"agent_id":"` + livePodCardvault + `","reason":"agent_resolution_test: pod name stun"}`
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/"+livePodCardvault, strings.NewReader(body))
	w := httptest.NewRecorder()
	s.handleStun(w, req)

	if w.Code == http.StatusNotFound || w.Code == http.StatusBadRequest {
		t.Fatalf("status = %d, want the stun to run against the resolved agent: %s", w.Code, w.Body.String())
	}
	var res CascadeResult
	if err := json.Unmarshal(w.Body.Bytes(), &res); err != nil {
		t.Fatalf("decode: %v\n%s", err, w.Body.String())
	}
	if res.TargetAgent != "agent-cardvault" {
		t.Fatalf("target_agent = %q, want the resolved DAG id agent-cardvault", res.TargetAgent)
	}
	assertRequestedID(t, w, livePodCardvault, "replicaset-pattern")
}

func TestHandleStun_UnknownAgentAnswers404WithTried(t *testing.T) {
	s, _ := resolutionServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/agent-ghost-abc123-xyz45",
		strings.NewReader(`{"reason":"agent_resolution_test: unknown"}`))
	w := httptest.NewRecorder()
	s.handleStun(w, req)

	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404: %s", w.Code, w.Body.String())
	}
	var body struct {
		Error string   `json:"error"`
		Tried []string `json:"tried"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || body.Error != "unknown agent" || len(body.Tried) == 0 {
		t.Fatalf("body = %s, want {\"error\":\"unknown agent\",\"tried\":[...]}", w.Body.String())
	}
}

func TestHandleResume_PodNameResolvesToTheTokensAgent(t *testing.T) {
	token, reg := liveDualSignedToken(t) // bound to agent-llm-classifier
	spire := newCountingRotateSpireClient(OutcomeContained)
	bao := newRotateBaoServer(http.StatusOK)
	defer bao.Close()
	client := newResumeFleetClient(t, spire, bao.URL)
	const podName = "agent-llm-classifier-5d8f9c7b6-x2x9z"
	if _, err := client.clientset.CoreV1().Pods("fe-signalloom-agents").Create(context.Background(),
		livePod(podName, ""), metav1.CreateOptions{}); err != nil {
		t.Fatalf("seed pod: %v", err)
	}

	srv := &server{
		dag:          mustBuildTestDAG(t),
		keyRegistry:  reg,
		resumePolicy: dualPolicy(),
		replayLedger: NewReplayLedger(),
		enforcement:  &fleetClientSelection{Kind: fleetClientKubernetes, Client: client, Enforcing: true},
	}
	reqBody, _ := json.Marshal(ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "resolve-idem-001",
		Namespace:      token.Namespace,
		Token:          token,
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/resume/"+podName, bytes.NewReader(reqBody))
	w := httptest.NewRecorder()
	srv.handleResume(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (pod name resolved to the token's agent): %s", w.Code, w.Body.String())
	}
	var resp ResumeResponse
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp.AgentID != token.AgentID {
		t.Fatalf("agent_id = %q, want the resolved DAG id %s", resp.AgentID, token.AgentID)
	}
}

func TestHandleResume_UnknownAgentAnswers404BeforeTokenChecks(t *testing.T) {
	srv := &server{dag: mustBuildTestDAG(t)}
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/resume/agent-ghost-abc123-xyz45",
		strings.NewReader(`{"token":{}}`))
	w := httptest.NewRecorder()
	srv.handleResume(w, req)
	if w.Code != http.StatusNotFound || !strings.Contains(w.Body.String(), `"unknown agent"`) {
		t.Fatalf("status = %d body = %s, want 404 unknown agent", w.Code, w.Body.String())
	}
}

// assertRequestedID checks the response records what the caller sent without
// any change to the frozen CascadeResult: in every freeze plane's details
// (requested_id, resolved_by) and in the X-Requested-Agent-Id header.
func assertRequestedID(t *testing.T, w *httptest.ResponseRecorder, want, wantBy string) {
	t.Helper()
	if got := w.Header().Get("X-Requested-Agent-Id"); got != want {
		t.Fatalf("X-Requested-Agent-Id = %q, want %q", got, want)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(w.Body.Bytes(), &raw); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if _, ok := raw["details"]; ok {
		t.Fatalf("CascadeResult carries a top-level details key; the frozen contract has none")
	}
	var res CascadeResult
	_ = json.Unmarshal(w.Body.Bytes(), &res)
	freezes := 0
	for _, p := range res.Planes {
		if p.Plane != PlaneFreeze {
			continue
		}
		freezes++
		if p.Details["requested_id"] != want || p.Details["resolved_by"] != wantBy {
			t.Fatalf("freeze details requested_id=%v resolved_by=%v, want %q and %q",
				p.Details["requested_id"], p.Details["resolved_by"], want, wantBy)
		}
	}
	if freezes == 0 {
		t.Fatalf("no freeze plane in %+v", res.Planes)
	}
}

func TestResolveAgentID_PrefixedBareName(t *testing.T) {
	// fe passes ids through unchanged, so a bare agent name must resolve to its
	// agent-<name> DAG id without an API call.
	s, cs := resolutionServer(t)
	got, err := s.resolveAgentID(context.Background(), "kusari-agent")
	if err != nil || got.ID != kusariAgentID || got.By != "prefixed" {
		t.Fatalf("resolve = %+v, %v; want %s resolved_by=prefixed", got, err, kusariAgentID)
	}
	if n := len(cs.Actions()); n != 0 {
		t.Fatalf("a prefixed DAG id must not touch the API server, saw %d actions", n)
	}
}

// ── Identity-map spoof rejection (sldc/sa-identity) ──────────────────────────
//
// hosted-daytona-coder holds pod-create RBAC in fe-signalloom-agents
// (infra/agent-swarm/hosted-daytona-coder/rolebinding.yaml). Without the
// identity map, a pod it creates carrying signalloom.ai/agent-name=kusari-agent
// would resolve via the label branch exactly as the real agent does. These
// tests pin that a registered identity map closes that gap: the label branch
// must also require the pod's ServiceAccount to match the one registered for
// that agent name.

// resolutionServerWithIdentity is resolutionServer plus a wired identity map,
// so the label branch's namespace/ServiceAccount check actually runs.
func resolutionServerWithIdentity(t *testing.T, identity map[string]AgentIdentity, objects ...runtime.Object) (*server, *fake.Clientset) {
	t.Helper()
	real, cs := newTestK8sClient(objects...)
	im := NewAgentIdentityMap(identity)
	real.identityMap = im
	client := credOKClient{k8sFleetClient: real}
	dag := resolutionDAG(t)
	return &server{dag: dag, orchestrator: NewCascadeOrchestrator(dag, client, 0), identityMap: im}, cs
}

// spoofedPod carries the real kusari-agent's discovery labels but runs as a
// different ServiceAccount, as a pod hosted-daytona-coder created would.
func spoofedPod(name, agentNameLabel, serviceAccount string) *corev1.Pod {
	p := livePod(name, agentNameLabel)
	p.Spec.ServiceAccountName = serviceAccount
	return p
}

// kusariIdentity registers kusari-agent at testNamespace, matching every
// livePod/spoofedPod fixture pod's actual namespace in this file.
func kusariIdentity() map[string]AgentIdentity {
	return map[string]AgentIdentity{
		"kusari-agent": {Namespace: testNamespace, ServiceAccount: "kusari-agent"},
	}
}

func TestResolveAgentID_LabelSpoofWithWrongServiceAccountIsRejected(t *testing.T) {
	decoy := spoofedPod(livePodKusari, "kusari-agent", "hosted-daytona-coder")
	s, _ := resolutionServerWithIdentity(t, kusariIdentity(), decoy)

	got, err := s.resolveAgentID(context.Background(), livePodKusari)
	if !errors.Is(err, errUnknownAgent) {
		t.Fatalf("resolve = %+v, %v; want errUnknownAgent: a pod running as hosted-daytona-coder must never resolve as kusari-agent merely by carrying its label", got, err)
	}
	found := false
	for _, step := range got.Tried {
		if strings.Contains(step, "rejected") && strings.Contains(step, "hosted-daytona-coder") {
			found = true
		}
	}
	if !found {
		t.Fatalf("tried = %q, want an entry recording the rejected ServiceAccount mismatch", got.Tried)
	}
}

func TestResolveAgentID_LabelSpoofWithRightServiceAccountNameButWrongNamespaceIsRejected(t *testing.T) {
	// A ServiceAccount name is only unique within its namespace. This pod's
	// ServiceAccountName is literally "kusari-agent" -- exactly the
	// registered name -- but the identity map registers that name for a
	// DIFFERENT namespace than where this pod actually runs (testNamespace).
	decoy := spoofedPod(livePodKusari, "kusari-agent", "kusari-agent")
	s, _ := resolutionServerWithIdentity(t, map[string]AgentIdentity{
		"kusari-agent": {Namespace: "hosted-daytona-coder-workspace", ServiceAccount: "kusari-agent"},
	}, decoy)

	got, err := s.resolveAgentID(context.Background(), livePodKusari)
	if !errors.Is(err, errUnknownAgent) {
		t.Fatalf("resolve = %+v, %v; want errUnknownAgent: the right ServiceAccount name in the wrong namespace must not resolve as kusari-agent", got, err)
	}
}

func TestResolveAgentID_LabelWithMatchingServiceAccountStillResolves(t *testing.T) {
	legit := spoofedPod(livePodKusari, "kusari-agent", "kusari-agent")
	s, _ := resolutionServerWithIdentity(t, kusariIdentity(), legit)

	got, err := s.resolveAgentID(context.Background(), livePodKusari)
	if err != nil || got.ID != kusariAgentID || got.By != resolvedByLabel {
		t.Fatalf("resolve = %+v, %v; want %s via the agent-name label when the namespace and ServiceAccount match the registered identity", got, err, kusariAgentID)
	}
}

func TestResolveAgentID_UnregisteredAgentNameLabelIsUnaffectedByIdentityMap(t *testing.T) {
	// The identity map only registers kusari-agent; cardvault's label is
	// unregistered here, so the map must not turn into a second allow-list
	// that starts denying names it was never told about.
	pod := spoofedPod("agent-cardvault-bb57657-jlf8w", "cardvault", "anything-at-all")
	s, _ := resolutionServerWithIdentity(t, kusariIdentity(), pod)

	got, err := s.resolveAgentID(context.Background(), "agent-cardvault-bb57657-jlf8w")
	if err != nil || got.ID != "agent-cardvault" {
		t.Fatalf("resolve = %+v, %v; want agent-cardvault (unregistered agent name must still resolve)", got, err)
	}
}
