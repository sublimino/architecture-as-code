package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/fake"
	k8stesting "k8s.io/client-go/testing"
)

// Live, 2026-10-03: an authorised release thawed kusari (probe_released
// 00:54:48) and within 2 s it opened /etc/passwd again, the resumed in-flight
// provocation, and was re-detected, held and re-stunned. Thawing a
// compromised process resumes the attack. So recover REPLACES a contained pod
// by default: delete it, and its controller starts a clean one from the
// declared template. Thaw in place stays available, only when asked for.

const replacedPodUID = types.UID("0f7d3c1e-kusari-frozen")

// containedChain is the live kusari shape, stunned and Flux-pinned.
func containedChain() []runtime.Object {
	pinned := map[string]string{fluxReconcileKey: "disabled"}
	objs := ownedChain(StateStunned, pinned, pinned)
	pod := objs[2].(*corev1.Pod)
	pod.UID = replacedPodUID
	pod.Labels[StunnedLabel] = "true"
	pod.Labels[ContainmentModeLabel] = ContainmentModeFrozen
	return objs
}

func podDeletes(cs *fake.Clientset) []k8stesting.DeleteActionImpl {
	var out []k8stesting.DeleteActionImpl
	for _, a := range cs.Actions() {
		if d, ok := a.(k8stesting.DeleteActionImpl); ok && a.GetResource().Resource == "pods" {
			out = append(out, d)
		}
	}
	return out
}

// releaseLabelWrites counts pod patches that write a released state.
func releaseLabelWrites(cs *fake.Clientset) int {
	n := 0
	for _, a := range cs.Actions() {
		if p, ok := a.(k8stesting.PatchAction); ok && a.GetResource().Resource == "pods" &&
			strings.Contains(string(p.GetPatch()), `"`+StunnedLabel+`":"false"`) {
			n++
		}
	}
	return n
}

func onlyTarget(t *testing.T, res *CascadeResult) TargetOutcome {
	t.Helper()
	if len(res.Targets) != 1 {
		t.Fatalf("targets = %d, want 1: %+v", len(res.Targets), res.Targets)
	}
	return res.Targets[0]
}

func TestRecoverReplacesAContainedPodByDefault(t *testing.T) {
	real, cs := newTestK8sClient(containedChain()...)
	res, err := NewCascadeOrchestrator(singleAgentDAG(t, testNamespace), credOKClient{k8sFleetClient: real}, 0).
		Recover(context.Background(), []string{gitopsAgent})
	if err != nil {
		t.Fatal(err)
	}

	if _, err := cs.CoreV1().Pods(testNamespace).Get(context.Background(), gitopsAgent, metav1.GetOptions{}); !apierrors.IsNotFound(err) {
		t.Fatalf("the contained pod still exists (err %v): recover must replace it", err)
	}
	dels := podDeletes(cs)
	if len(dels) != 1 {
		t.Fatalf("pod deletes = %d, want 1", len(dels))
	}
	opts := dels[0].GetDeleteOptions()
	if opts.Preconditions == nil || opts.Preconditions.UID == nil || *opts.Preconditions.UID != replacedPodUID {
		t.Fatalf("delete is not pinned to the contained pod's UID: %+v", opts.Preconditions)
	}
	if opts.GracePeriodSeconds == nil || *opts.GracePeriodSeconds != replaceGracePeriodSeconds {
		t.Fatalf("grace period = %v, want %d: a frozen process cannot use a grace period", opts.GracePeriodSeconds, replaceGracePeriodSeconds)
	}
	// The frozen process is never resumed: no released labels are written on
	// the contained pod, which is what the sentinel thaws on.
	if n := releaseLabelWrites(cs); n != 0 {
		t.Fatalf("%d release label writes on the contained pod: the sentinel would thaw it before it dies", n)
	}
	if _, ok := getDeployment(t, cs).Annotations[fluxReconcileKey]; ok {
		t.Fatal("the Deployment's Flux pin was left in place")
	}
	// Flux is switched back on before the pod goes, so the replacement is
	// reconciled to the declared template.
	depPatch, del := -1, -1
	for i, a := range cs.Actions() {
		if _, ok := a.(k8stesting.PatchAction); ok && a.GetResource().Resource == "deployments" && depPatch < 0 {
			depPatch = i
		}
		if _, ok := a.(k8stesting.DeleteActionImpl); ok && a.GetResource().Resource == "pods" {
			del = i
		}
	}
	if depPatch < 0 || del < 0 || depPatch > del {
		t.Fatalf("Flux resumed at action %d, pod deleted at %d: resume must come first", depPatch, del)
	}

	tgt := onlyTarget(t, res)
	if !tgt.StateWrite.Succeeded || tgt.ToState != StateReplaced || tgt.Outcome != OutcomeContained {
		t.Fatalf("target = %+v; want the release recorded as a replacement", tgt)
	}
	var found bool
	for _, p := range res.Planes {
		if p.Details["action"] == "replace_pod" {
			found = true
			if p.Details["pod"] != gitopsAgent || p.Details["pod_uid"] != string(replacedPodUID) || p.Details["agent_id"] != gitopsAgent {
				t.Fatalf("replace plane details = %v", p.Details)
			}
		}
	}
	if !found {
		t.Fatalf("no replace_pod plane: %+v", res.Planes)
	}
}

// Deleting a pod nothing controls removes the agent; it does not replace it.
func TestRecoverRefusesToReplaceAPodNoControllerOwns(t *testing.T) {
	objs := containedChain()
	pod := objs[2].(*corev1.Pod)
	pod.OwnerReferences = nil
	real, cs := newTestK8sClient(pod)
	res, err := NewCascadeOrchestrator(singleAgentDAG(t, testNamespace), credOKClient{k8sFleetClient: real}, 0).
		Recover(context.Background(), []string{gitopsAgent})
	if err != nil {
		t.Fatal(err)
	}
	if got := getPod(t, cs); got.Labels[PodStateLabel] != StateStunned {
		t.Fatalf("the uncontrolled pod was released: %v", got.Labels)
	}
	if len(podDeletes(cs)) != 0 {
		t.Fatal("deleted a pod no controller would replace")
	}
	tgt := onlyTarget(t, res)
	if tgt.StateWrite.Succeeded || !strings.Contains(tgt.StateWrite.Error, "mode=thaw") || tgt.Outcome == OutcomeContained {
		t.Fatalf("target = %+v; want a refused release that names mode=thaw", tgt)
	}
}

func TestRecoverThawModeReleasesInPlace(t *testing.T) {
	real, cs := newTestK8sClient(containedChain()...)
	res, err := NewCascadeOrchestrator(singleAgentDAG(t, testNamespace), credOKClient{k8sFleetClient: real}, 0).
		RecoverWithMode(context.Background(), []string{gitopsAgent}, RecoverThaw)
	if err != nil {
		t.Fatal(err)
	}
	if len(podDeletes(cs)) != 0 {
		t.Fatal("thaw mode deleted the pod")
	}
	if got := getPod(t, cs); got.Labels[StunnedLabel] != "false" || got.Labels[PodStateLabel] != PodStateLabelValue(StateRunning) {
		t.Fatalf("thaw mode did not release in place: %v", got.Labels)
	}
	if tgt := onlyTarget(t, res); tgt.ToState != StateRunning || !tgt.StateWrite.Succeeded {
		t.Fatalf("target = %+v", tgt)
	}
}

// A client that cannot replace must not quietly thaw instead: that is the
// resumed-attack path this default exists to close.
// noReplaceClient hides the mock's PodReplacer: only FleetClient is promoted.
type noReplaceClient struct{ FleetClient }

func TestRecoverReplaceFailsClosedWithoutTheCapability(t *testing.T) {
	client := newMockClient()
	client.states["agent-cardvault"] = StateStunned
	res, err := NewCascadeOrchestrator(mustBuildTestDAG(t), noReplaceClient{client}, 0).
		RecoverWithMode(context.Background(), []string{"agent-cardvault"}, RecoverReplace)
	if err != nil {
		t.Fatal(err)
	}
	if got := client.states["agent-cardvault"]; got != StateStunned {
		t.Fatalf("state = %q: a client without replacement thawed in place", got)
	}
	tgt := onlyTarget(t, res)
	if tgt.StateWrite.Succeeded || !strings.Contains(tgt.StateWrite.Error, "mode=thaw") {
		t.Fatalf("target = %+v; want the release refused, naming mode=thaw", tgt)
	}
}

// Nothing frozen, nothing to discard: an already-released pod keeps running.
func TestRecoverReplaceLeavesAnUncontainedPodRunning(t *testing.T) {
	real, cs := newTestK8sClient(ownedChain(PodStateLabelValue(StateRunning), nil, nil)...)
	res, err := NewCascadeOrchestrator(singleAgentDAG(t, testNamespace), credOKClient{k8sFleetClient: real}, 0).
		Recover(context.Background(), []string{gitopsAgent})
	if err != nil {
		t.Fatal(err)
	}
	if len(podDeletes(cs)) != 0 {
		t.Fatal("replaced a pod that was not contained")
	}
	if tgt := onlyTarget(t, res); !tgt.StateWrite.Succeeded || tgt.ToState != StateRunning {
		t.Fatalf("target = %+v", tgt)
	}
}

// The pod went between the read and the delete: replaced all the same.
func TestRecoverReplaceAcceptsAPodAlreadyGone(t *testing.T) {
	real, cs := newTestK8sClient(containedChain()...)
	cs.PrependReactor("delete", "pods", func(k8stesting.Action) (bool, runtime.Object, error) {
		return true, nil, apierrors.NewNotFound(schema.GroupResource{Resource: "pods"}, gitopsAgent)
	})
	res, err := NewCascadeOrchestrator(singleAgentDAG(t, testNamespace), credOKClient{k8sFleetClient: real}, 0).
		Recover(context.Background(), []string{gitopsAgent})
	if err != nil {
		t.Fatal(err)
	}
	if tgt := onlyTarget(t, res); !tgt.StateWrite.Succeeded || tgt.ToState != StateReplaced {
		t.Fatalf("target = %+v", tgt)
	}
}

func postRecover(t *testing.T, s *server, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/recover", strings.NewReader(body))
	w := httptest.NewRecorder()
	s.handleRecover(w, req)
	return w
}

func TestRecoverHandlerRejectsAnUnknownMode(t *testing.T) {
	s, cs, _ := newGitopsServer(t, containedChain()...)
	w := postRecover(t, s, `{"agent_ids":["`+gitopsAgent+`"],"mode":"resume"}`)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status %d, want 400: %s", w.Code, w.Body.String())
	}
	if len(cs.Actions()) != 0 {
		t.Fatalf("an invalid mode reached the cluster: %v", cs.Actions())
	}
}

func TestRecoverHandlerHonoursTheMode(t *testing.T) {
	for _, tc := range []struct {
		body     string
		deletes  int
		toState  string
		fromBody string
	}{
		{`{"agent_ids":["` + gitopsAgent + `"]}`, 1, StateReplaced, "default"},
		{`{"agent_ids":["` + gitopsAgent + `"],"mode":"replace"}`, 1, StateReplaced, "replace"},
		{`{"agent_ids":["` + gitopsAgent + `"],"mode":"thaw"}`, 0, StateRunning, "thaw"},
	} {
		t.Run(tc.fromBody, func(t *testing.T) {
			s, cs, _ := newGitopsServer(t, containedChain()...)
			w := postRecover(t, s, tc.body)
			if w.Code != http.StatusOK {
				t.Fatalf("status %d: %s", w.Code, w.Body.String())
			}
			var res CascadeResult
			if err := json.Unmarshal(w.Body.Bytes(), &res); err != nil {
				t.Fatal(err)
			}
			if got := len(podDeletes(cs)); got != tc.deletes {
				t.Fatalf("pod deletes = %d, want %d", got, tc.deletes)
			}
			if tgt := onlyTarget(t, &res); tgt.ToState != tc.toState {
				t.Fatalf("to_state = %q, want %q", tgt.ToState, tc.toState)
			}
		})
	}
}
