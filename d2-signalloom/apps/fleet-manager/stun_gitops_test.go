package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"
	k8stesting "k8s.io/client-go/testing"
	"sigs.k8s.io/yaml"
)

// ── What this suite pins (kusari-e2e W1) ─────────────────────────────────────
//
//  1. A caller-supplied stun reason reaches all three provenance annotations,
//     is bounded, and is echoed in the gitops plane's details.
//  2. A stun that froze the pod also switches Flux off for the pod and its
//     owning Deployment, and says so as a `gitops` PlaneResult per target.
//  3. A recovery switches Flux back on AFTER credentials and BEFORE the state
//     label is cleared.
//  4. The Kusari agent is in the fleet ConfigMap that is actually deployed.
//
// Every assertion is on Targets[] / Planes[] or on the API objects themselves,
// never on Events[], which is the lossy dashboard view.

const (
	gitopsAgent      = "agent-solo"
	gitopsDeployment = "agent-solo"
	fluxReconcileKey = "kustomize.toolkit.fluxcd.io/reconcile"
)

// credOKClient is the real k8s client with only the two credential calls
// stubbed to succeed. Credentials are not under test here; stubbing them lets a
// target reach `contained`, so a gitops failure is visible as a downgrade.
// Embedding keeps every other method — including the optional capabilities the
// orchestrator type-asserts for — promoted from the real client.
type credOKClient struct {
	*k8sFleetClient
	onRestore func()
}

func (c credOKClient) RevokeCredentials(context.Context, string) error { return nil }
func (c credOKClient) RestoreCredentials(context.Context, string) error {
	if c.onRestore != nil {
		c.onRestore()
	}
	return nil
}

func isController() *bool { b := true; return &b }

// ownedChain builds Deployment -> ReplicaSet -> Pod exactly as the live Kusari
// workload is shaped (agent-kusari -> agent-kusari-5685ff664b -> pod).
func ownedChain(podState string, podAnnotations, deployAnnotations map[string]string) []runtime.Object {
	return ownedChainFor(gitopsAgent, podState, podAnnotations, deployAnnotations)
}

// ownedChainFor names the Deployment after the agent and the ReplicaSet after
// the Deployment plus a pod-template hash, as the Deployment controller does.
func ownedChainFor(agentID, podState string, podAnnotations, deployAnnotations map[string]string) []runtime.Object {
	rsName := agentID + "-5685ff664b"
	dep := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name: agentID, Namespace: testNamespace, UID: "dep-uid",
			Annotations: deployAnnotations,
		},
		Spec: appsv1.DeploymentSpec{
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Annotations: map[string]string{"template": "untouched"}},
			},
		},
	}
	rs := &appsv1.ReplicaSet{
		ObjectMeta: metav1.ObjectMeta{
			Name: rsName, Namespace: testNamespace, UID: "rs-uid",
			OwnerReferences: []metav1.OwnerReference{{
				APIVersion: "apps/v1", Kind: "Deployment", Name: agentID, UID: "dep-uid", Controller: isController(),
			}},
		},
	}
	pod := agentPod(agentID, podState, nil)
	pod.Annotations = podAnnotations
	pod.OwnerReferences = []metav1.OwnerReference{{
		APIVersion: "apps/v1", Kind: "ReplicaSet", Name: rsName, UID: "rs-uid", Controller: isController(),
	}}
	return []runtime.Object{dep, rs, pod}
}

func newGitopsServer(t *testing.T, objects ...runtime.Object) (*server, *fake.Clientset, credOKClient) {
	t.Helper()
	real, cs := newTestK8sClient(objects...)
	client := credOKClient{k8sFleetClient: real}
	dag := singleAgentDAG(t, testNamespace)
	return &server{dag: dag, orchestrator: NewCascadeOrchestrator(dag, client, 0)}, cs, client
}

func postStun(t *testing.T, s *server, body string) (*httptest.ResponseRecorder, CascadeResult) {
	t.Helper()
	var rdr *bytes.Reader
	if body == "" {
		rdr = bytes.NewReader(nil)
	} else {
		rdr = bytes.NewReader([]byte(body))
	}
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/"+gitopsAgent, rdr)
	w := httptest.NewRecorder()
	s.handleStun(w, req)
	var res CascadeResult
	if w.Code < 400 {
		if err := json.Unmarshal(w.Body.Bytes(), &res); err != nil {
			t.Fatalf("decode CascadeResult: %v\n%s", err, w.Body.String())
		}
	}
	return w, res
}

func gitopsPlanes(r CascadeResult) []PlaneResult {
	var out []PlaneResult
	for _, p := range r.Planes {
		if p.Plane == "gitops" {
			out = append(out, p)
		}
	}
	return out
}

func soleGitops(t *testing.T, r CascadeResult) PlaneResult {
	t.Helper()
	g := gitopsPlanes(r)
	if len(g) != 1 {
		t.Fatalf("expected exactly one gitops PlaneResult, got %d: %+v", len(g), r.Planes)
	}
	return g[0]
}

func getPod(t *testing.T, cs *fake.Clientset) *corev1.Pod {
	t.Helper()
	p, err := cs.CoreV1().Pods(testNamespace).Get(context.Background(), gitopsAgent, metav1.GetOptions{})
	if err != nil {
		t.Fatalf("re-read pod: %v", err)
	}
	return p
}

func getDeployment(t *testing.T, cs *fake.Clientset) *appsv1.Deployment {
	t.Helper()
	d, err := cs.AppsV1().Deployments(testNamespace).Get(context.Background(), gitopsDeployment, metav1.GetOptions{})
	if err != nil {
		t.Fatalf("re-read deployment: %v", err)
	}
	return d
}

// ── 1. Reason plumbing ──────────────────────────────────────────────────────

func TestHandleStun_BodyReasonIsWrittenToAllThreeProvenanceAnnotations(t *testing.T) {
	s, cs, _ := newGitopsServer(t, ownedChain("active", nil, nil)...)
	const reason = "kusari: hostile write to /etc/passwd detected"

	w, res := postStun(t, s, `{"agent_id":"agent-solo","reason":"`+reason+`"}`)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	pod := getPod(t, cs)
	for _, key := range []string{StunReasonAnnotationAI, StunReasonAnnotationIO} {
		if got := pod.Annotations[key]; got != reason {
			t.Errorf("%s = %q, want the caller's reason %q", key, got, reason)
		}
	}
	if pod.Annotations[StunnedAtAnnotation] == "" {
		t.Errorf("%s must still be stamped", StunnedAtAnnotation)
	}
	if got := soleGitops(t, res).Details["reason"]; got != reason {
		t.Errorf("response must echo the reason in the gitops plane details, got %v", got)
	}
}

func TestHandleStun_EmptyBodyKeepsTheDefaultReason(t *testing.T) {
	// Regression guard: callers that send no body (every caller before this
	// change) must see exactly the old annotation value.
	s, cs, _ := newGitopsServer(t, ownedChain("active", nil, nil)...)

	w, _ := postStun(t, s, "")
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 for an empty body, got %d: %s", w.Code, w.Body.String())
	}
	if got := getPod(t, cs).Annotations[StunReasonAnnotationAI]; got != StunReason {
		t.Fatalf("empty body must default to %q, got %q", StunReason, got)
	}
}

func TestHandleStun_ReasonAtTheBoundIsAccepted(t *testing.T) {
	s, cs, _ := newGitopsServer(t, ownedChain("active", nil, nil)...)
	reason := strings.Repeat("é", 256) // 256 runes, 512 bytes: the bound is runes

	w, _ := postStun(t, s, `{"reason":"`+reason+`"}`)
	if w.Code != http.StatusOK {
		t.Fatalf("a 256-rune reason must be accepted, got %d: %s", w.Code, w.Body.String())
	}
	if got := getPod(t, cs).Annotations[StunReasonAnnotationIO]; got != reason {
		t.Fatalf("256-rune reason not written verbatim")
	}
}

func TestHandleStun_RejectsMalformedBodiesWithoutTouchingThePod(t *testing.T) {
	cases := map[string]string{
		"reason over 256 runes":     `{"reason":"` + strings.Repeat("a", 257) + `"}`,
		"control character":         `{"reason":"bell\u0007"}`,
		"newline":                   `{"reason":"line1\nline2"}`,
		"not json":                  `reason=because`,
		"agent_id contradicts path": `{"agent_id":"agent-other","reason":"x"}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			s, cs, _ := newGitopsServer(t, ownedChain("active", nil, nil)...)
			w, _ := postStun(t, s, body)
			if w.Code != http.StatusBadRequest {
				t.Fatalf("expected 400, got %d: %s", w.Code, w.Body.String())
			}
			for _, a := range cs.Actions() {
				if a.GetVerb() == "patch" {
					t.Fatalf("a rejected request must not patch anything, saw %s %s", a.GetVerb(), a.GetResource().Resource)
				}
			}
		})
	}
}

// ── 2. gitops plane on stun ─────────────────────────────────────────────────

func TestStun_GitOpsPlaneDisablesFluxOnPodAndOwningDeployment(t *testing.T) {
	s, cs, _ := newGitopsServer(t, ownedChain("active", nil, nil)...)

	w, res := postStun(t, s, "")
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	if got := getPod(t, cs).Annotations[fluxReconcileKey]; got != "disabled" {
		t.Errorf("pod %s = %q, want disabled", fluxReconcileKey, got)
	}
	dep := getDeployment(t, cs)
	if got := dep.Annotations[fluxReconcileKey]; got != "disabled" {
		t.Errorf("deployment %s = %q, want disabled", fluxReconcileKey, got)
	}
	// Annotating spec.template would roll the frozen pod away. Only object
	// metadata may change.
	if tpl := dep.Spec.Template.Annotations; len(tpl) != 1 || tpl["template"] != "untouched" {
		t.Errorf("deployment pod template must be untouched, got %v", tpl)
	}

	g := soleGitops(t, res)
	if g.Outcome != OutcomeContained {
		t.Errorf("gitops outcome = %q, want contained (error %q)", g.Outcome, g.Error)
	}
	want := map[string]any{
		"deployment": gitopsDeployment,
		"pod":        gitopsAgent,
		"annotation": "kustomize.toolkit.fluxcd.io/reconcile=disabled",
	}
	for k, v := range want {
		if g.Details[k] != v {
			t.Errorf("details[%q] = %v, want %v", k, g.Details[k], v)
		}
	}
	if g.Timestamp == "" {
		t.Error("gitops PlaneResult must carry a timestamp")
	}
	if len(res.Targets) != 1 || res.Targets[0].Outcome != OutcomeContained {
		t.Errorf("target outcome must stay contained when every step succeeded: %+v", res.Targets)
	}
}

func TestStun_GitOpsPlaneOnABarePodAnnotatesThePodAndSaysThereIsNoDeployment(t *testing.T) {
	s, cs, _ := newGitopsServer(t, agentPod(gitopsAgent, "active", nil))

	_, res := postStun(t, s, "")

	if got := getPod(t, cs).Annotations[fluxReconcileKey]; got != "disabled" {
		t.Errorf("bare pod must still be annotated, got %q", got)
	}
	g := soleGitops(t, res)
	if g.Outcome != OutcomeContained {
		t.Errorf("bare pod is not a failure: outcome = %q (%s)", g.Outcome, g.Error)
	}
	if g.Details["deployment"] != "" {
		t.Errorf("no Deployment exists, details must not name one: %v", g.Details["deployment"])
	}
	if g.Details["owner_kind"] != "none" {
		t.Errorf("details must say the pod has no owner, got owner_kind=%v", g.Details["owner_kind"])
	}
}

func TestStun_GitOpsDeploymentPatchFailureIsPartialNeverSilent(t *testing.T) {
	const injected = "INJECTED-DEPLOYMENT-PATCH-FORBIDDEN"
	s, cs, _ := newGitopsServer(t, ownedChain("active", nil, nil)...)
	cs.PrependReactor("patch", "deployments", func(k8stesting.Action) (bool, runtime.Object, error) {
		return true, nil, errors.New(injected)
	})

	w, res := postStun(t, s, "")

	g := soleGitops(t, res)
	if g.Outcome != OutcomePartial {
		t.Errorf("pod annotated but deployment not: gitops outcome = %q, want partial", g.Outcome)
	}
	if !strings.Contains(g.Error, injected) {
		t.Errorf("gitops error must carry the real cause, got %q", g.Error)
	}
	if res.Targets[0].Outcome != OutcomePartial {
		t.Errorf("target must be downgraded to partial, got %q", res.Targets[0].Outcome)
	}
	if res.OverallOutcome != OutcomePartial || w.Code != http.StatusMultiStatus {
		t.Errorf("overall = %q / HTTP %d, want partial / 207", res.OverallOutcome, w.Code)
	}
}

func TestStun_GitOpsIsNotAttemptedWhenTheFreezeFailed(t *testing.T) {
	// A pod the sentinel does not watch fails the state write. Switching Flux
	// off for a workload that was never frozen would be a change with no
	// containment behind it.
	objs := ownedChain("active", nil, nil)
	delete(objs[2].(*corev1.Pod).Labels, AgentLabel)
	s, cs, _ := newGitopsServer(t, objs...)

	_, res := postStun(t, s, "")

	if _, ok := getDeployment(t, cs).Annotations[fluxReconcileKey]; ok {
		t.Error("deployment must not be annotated when the freeze failed")
	}
	g := soleGitops(t, res)
	if g.Outcome != OutcomeUnavailable || !strings.Contains(g.Error, "not attempted") {
		t.Errorf("want unavailable/not attempted, got %q / %q", g.Outcome, g.Error)
	}
}

// ── 3. gitops plane on recover ──────────────────────────────────────────────

func TestRecover_RemovesFluxAnnotationAfterCredentialsAndBeforeTheStateLabelClears(t *testing.T) {
	disabled := map[string]string{fluxReconcileKey: "disabled"}
	real, cs := newTestK8sClient(ownedChain(StateStunned, disabled, disabled)...)

	restoreAt := -1
	client := credOKClient{k8sFleetClient: real, onRestore: func() { restoreAt = len(cs.Actions()) }}
	dag := singleAgentDAG(t, testNamespace)

	res, err := NewCascadeOrchestrator(dag, client, 0).Recover(context.Background(), []string{gitopsAgent})
	if err != nil {
		t.Fatalf("recover: %v", err)
	}

	if _, ok := getDeployment(t, cs).Annotations[fluxReconcileKey]; ok {
		t.Error("deployment annotation must be REMOVED, not blanked")
	}
	if _, ok := getPod(t, cs).Annotations[fluxReconcileKey]; ok {
		t.Error("pod annotation must be REMOVED, not blanked")
	}

	depPatch, statePatch := patchOrder(cs)
	if restoreAt < 0 || depPatch < 0 || statePatch < 0 {
		t.Fatalf("missing step: restore@%d deploymentPatch@%d statePatch@%d", restoreAt, depPatch, statePatch)
	}
	if !(restoreAt <= depPatch && depPatch < statePatch) {
		t.Fatalf("order must be credentials -> gitops -> state label; got restore@%d deploymentPatch@%d statePatch@%d",
			restoreAt, depPatch, statePatch)
	}

	g := soleGitops(t, *res)
	if g.Outcome != OutcomeContained {
		t.Errorf("recover gitops outcome = %q (%s), want contained", g.Outcome, g.Error)
	}
	if res.Targets[0].Outcome != OutcomeContained {
		t.Errorf("target outcome = %q, want contained", res.Targets[0].Outcome)
	}
}

// patchOrder returns the action index of the first Deployment patch and of the
// pod patch that writes the state label, or -1 for either that never happened.
func patchOrder(cs *fake.Clientset) (depPatch, statePatch int) {
	depPatch, statePatch = -1, -1
	for i, a := range cs.Actions() {
		p, ok := a.(k8stesting.PatchAction)
		if !ok {
			continue
		}
		switch {
		case a.GetResource().Resource == "deployments" && depPatch < 0:
			depPatch = i
		case a.GetResource().Resource == "pods" && strings.Contains(string(p.GetPatch()), PodStateLabel):
			statePatch = i
		}
	}
	return depPatch, statePatch
}

func TestEnforceResume_RemovesFluxAnnotationBeforeTheUnfreeze(t *testing.T) {
	token, reg := liveDualSignedToken(t)
	spire := newCountingRotateSpireClient(OutcomeContained)
	bao := newRotateBaoServer(http.StatusOK)
	defer bao.Close()

	disabled := map[string]string{fluxReconcileKey: "disabled"}
	cs := fake.NewSimpleClientset(ownedChainFor(token.AgentID, StateStunned, disabled, disabled)...)
	client := newK8sFleetClientWithSpire(cs, testNamespace, spire)
	client.baoClient = NewOpenBaoClient(OpenBaoConfig{Address: bao.URL, Token: "test-token", Timeout: 2 * time.Second})

	resp, err := EnforceResume(context.Background(), ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "idem-gitops-resume",
		AgentID:        token.AgentID,
		Namespace:      token.Namespace,
		Token:          token,
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}, reg, dualPolicy(), NewReplayLedger(), client)
	if err != nil || !resp.Success {
		t.Fatalf("resume must succeed: err=%v resp=%+v", err, resp)
	}
	if resp.Error != "" {
		t.Errorf("a clean resume must carry no error, got %q", resp.Error)
	}

	dep, err := cs.AppsV1().Deployments(testNamespace).Get(context.Background(), token.AgentID, metav1.GetOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := dep.Annotations[fluxReconcileKey]; ok {
		t.Error("governed resume must remove the Flux annotation from the Deployment")
	}
	depPatch, statePatch := patchOrder(cs)
	if depPatch < 0 || statePatch < 0 || depPatch > statePatch {
		t.Fatalf("Flux must be re-enabled before the unfreeze: deploymentPatch@%d statePatch@%d", depPatch, statePatch)
	}
}

func TestRecover_ClearsTheCallerReason(t *testing.T) {
	s, cs, _ := newGitopsServer(t, ownedChain("active", nil, nil)...)
	postStun(t, s, `{"reason":"kusari incident 42"}`)

	if _, err := s.orchestrator.Recover(context.Background(), []string{gitopsAgent}); err != nil {
		t.Fatalf("recover: %v", err)
	}
	pod := getPod(t, cs)
	for _, key := range []string{StunReasonAnnotationAI, StunReasonAnnotationIO} {
		if got := pod.Annotations[key]; got != "" {
			t.Errorf("%s = %q after recover, want blanked", key, got)
		}
	}
}

// ── 4. The contract enum ────────────────────────────────────────────────────

func TestGitOpsPlaneIsValidButNotADispatchedContainmentPlane(t *testing.T) {
	if !EnforcementPlane("gitops").IsValid() {
		t.Fatal(`EnforcementPlane("gitops") must be a valid wire value`)
	}
	for _, p := range AllEnforcementPlanes() {
		if p == "gitops" {
			t.Fatal("gitops must not join the five dispatched containment planes")
		}
	}
}

// ── 5. Kusari in the deployed DAG ───────────────────────────────────────────

func TestKusariAgentIsInTheDeployedFleetConfig(t *testing.T) {
	raw, err := os.ReadFile("base/configmap.yaml")
	if err != nil {
		t.Fatalf("read deployed configmap: %v", err)
	}
	var cm corev1.ConfigMap
	if err := yaml.Unmarshal(raw, &cm); err != nil {
		t.Fatalf("parse configmap: %v", err)
	}
	path := t.TempDir() + "/fleet.yaml"
	if err := os.WriteFile(path, []byte(cm.Data["fleet.yaml"]), 0o600); err != nil {
		t.Fatal(err)
	}
	dag, err := LoadFleet(path)
	if err != nil {
		t.Fatalf("deployed fleet config must load: %v", err)
	}

	a := dag.GetAgent("agent-kusari-agent")
	if a == nil {
		t.Fatal("agent-kusari-agent missing from the deployed fleet config")
	}
	if got := agentNameFromID(a.ID); got != "kusari-agent" {
		t.Errorf("label selector value = %q, want kusari-agent (the live pod's signalloom.ai/agent-name)", got)
	}
	checks := map[string][2]string{
		"type":         {a.Type, "supply-chain"},
		"team":         {a.Team, "kusari"},
		"trustProfile": {a.TrustProfile, "low"},
		"riskClass":    {a.RiskClass, "high"},
		"gracePeriod":  {a.GracePeriod, "0h"},
		"namespace":    {a.Namespace, "fe-signalloom-agents"},
	}
	for k, v := range checks {
		if v[0] != v[1] {
			t.Errorf("%s = %q, want %q", k, v[0], v[1])
		}
	}
	if len(a.Dependencies) != 0 {
		t.Errorf("dependencies = %v, want none", a.Dependencies)
	}
	targets, err := dag.CascadeTargets("agent-kusari-agent")
	if err != nil {
		t.Fatalf("cascade targets: %v", err)
	}
	if len(targets) != 1 || targets[0] != "agent-kusari-agent" {
		t.Errorf("a leaf with no dependents must cascade to itself only, got %v", targets)
	}
}
