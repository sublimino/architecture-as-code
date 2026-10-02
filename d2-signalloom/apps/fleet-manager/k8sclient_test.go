package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/kubernetes/fake"
	"k8s.io/client-go/rest"
	k8stesting "k8s.io/client-go/testing"
)

// ── What this suite is for ───────────────────────────────────────────────────
//
// The healthy path is the easy half and is covered below, but it is not why this
// file exists. The path that matters is the one the proposal never mentions: the
// API server is unreachable, so the client knows NOTHING about the target. Every
// fail-closed test here asserts three things together, because any one of them
// alone can pass while the contract is broken:
//
//  1. the returned error satisfies errors.Is(err, ErrEnforcementUnavailable)
//  2. the returned state is not a plausible lie (never StateRunning)
//  3. the injected fault actually fired — asserted by looking for the literal
//     injected message inside the returned error
//
// (3) is not ceremony. A reactor that never fires leaves the call succeeding and
// every "expected an error" assertion failing loudly — but a reactor that fires
// for the WRONG verb leaves a DIFFERENT error propagating, and a test that only
// checks errors.Is would go green against a fault it never injected.

const testNamespace = "fe-signalloom-agents"

// Distinct literals per fault so no assertion can be satisfied by a constant it
// shares with the thing it is testing.
const (
	injectedGetFault   = "INJECTED-GET-FAULT-dial-tcp-refused"
	injectedListFault  = "INJECTED-LIST-FAULT-context-deadline"
	injectedPatchFault = "INJECTED-PATCH-FAULT-etcd-unreachable"
)

func agentPod(name, state string, extraLabels map[string]string) *corev1.Pod {
	labels := map[string]string{
		AgentLabel:     "true",
		AgentNameLabel: agentNameFromID(name),
	}
	if state != "" {
		labels[PodStateLabel] = state
	}
	for k, v := range extraLabels {
		labels[k] = v
	}
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: testNamespace,
			Labels:    labels,
		},
		// Every real pod has a ServiceAccount (the API server defaults it), and
		// the credential planes now read the SPIFFE subject from it. Swarm
		// agents like agent-cardvault use their own name as the SA.
		Spec: corev1.PodSpec{ServiceAccountName: name},
	}
}

func newTestK8sClient(objects ...runtime.Object) (*k8sFleetClient, *fake.Clientset) {
	cs := fake.NewSimpleClientset(objects...)
	return newK8sFleetClient(cs, testNamespace), cs
}

// newTestK8sClientAt pins the clock so a timestamp assertion is about the code
// rather than about how fast the test ran.
func newTestK8sClientAt(at time.Time, objects ...runtime.Object) (*k8sFleetClient, *fake.Clientset) {
	c, cs := newTestK8sClient(objects...)
	c.now = func() time.Time { return at }
	return c, cs
}

// failOn installs a reactor that makes the named verb fail with a literal we can
// look for later.
func failOn(cs *fake.Clientset, verb, message string) {
	cs.PrependReactor(verb, "pods", func(k8stesting.Action) (bool, runtime.Object, error) {
		return true, nil, errors.New(message)
	})
}

// outage is a switchable fault, used where a test needs the plane to fail and
// then recover.
//
// Note for anyone tempted by `cs.ReactionChain = nil` to "turn the fault off":
// that also removes the fake's DEFAULT object reaction, so every subsequent call
// returns an empty object with a nil error. The suite then reads green for a
// client that was never exercised — the fake is broken, not the code. Toggle a
// captured flag instead.
type outage struct{ active bool }

func newOutage(cs *fake.Clientset, verbs []string, message string) *outage {
	o := &outage{active: true}
	for _, verb := range verbs {
		cs.PrependReactor(verb, "pods", func(k8stesting.Action) (bool, runtime.Object, error) {
			if !o.active {
				return false, nil, nil // fall through to the tracker
			}
			return true, nil, errors.New(message)
		})
	}
	return o
}

func (o *outage) heal() { o.active = false }

func assertUnavailable(t *testing.T, err error, injected string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected an error, got nil — the fail-closed path did not fire")
	}
	if !errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("expected ErrEnforcementUnavailable, got %#v (%v)", err, err)
	}
	if errors.Is(err, ErrTargetNotFound) {
		t.Fatalf("unavailability must not also report ErrTargetNotFound: %v", err)
	}
	if injected != "" && !strings.Contains(err.Error(), injected) {
		t.Fatalf("injected fault %q never reached the caller; got %v — the reactor did not fire on the verb under test", injected, err)
	}
}

// ── Healthy path ─────────────────────────────────────────────────────────────

func TestK8sGetPodStateHealthy(t *testing.T) {
	c, _ := newTestK8sClient(agentPod("agent-monitor", "idle", nil))

	state, err := c.GetPodState(context.Background(), testNamespace, "agent-monitor")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if state != "idle" {
		t.Fatalf("expected idle, got %q", state)
	}
	if c.IsDegraded(testNamespace, "agent-monitor") {
		t.Fatal("a successful read must not leave the target degraded")
	}
}

func TestK8sGetPodStateNoLabelIsUnknownNotAnError(t *testing.T) {
	c, _ := newTestK8sClient(agentPod("agent-monitor", "", nil))

	state, err := c.GetPodState(context.Background(), testNamespace, "agent-monitor")
	if err != nil {
		t.Fatalf("a pod with no state label is a definite answer, not a failure: %v", err)
	}
	if state != StateUnknown {
		t.Fatalf("expected %q, got %q — an absent label must not be defaulted to a real state", StateUnknown, state)
	}
	if state == StateRunning {
		t.Fatal("StateUnknown must never equal StateRunning")
	}
}

func TestK8sSetPodStateWritesBothLabels(t *testing.T) {
	c, cs := newTestK8sClient(agentPod("agent-cardvault", "active", map[string]string{StunnedLabel: "false"}))

	if err := c.SetPodState(context.Background(), testNamespace, "agent-cardvault", StateStunned); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	pod, err := cs.CoreV1().Pods(testNamespace).Get(context.Background(), "agent-cardvault", metav1.GetOptions{})
	if err != nil {
		t.Fatalf("re-read failed: %v", err)
	}
	if got := pod.Labels[PodStateLabel]; got != StateStunned {
		t.Fatalf("%s: expected %q, got %q", PodStateLabel, StateStunned, got)
	}
	if got := pod.Labels[StunnedLabel]; got != "true" {
		t.Fatalf("%s must track the state label in the same patch: expected \"true\", got %q", StunnedLabel, got)
	}
}

func TestK8sSetPodStateRunningClearsStunnedLabel(t *testing.T) {
	c, cs := newTestK8sClient(agentPod("agent-cardvault", StateStunned, map[string]string{StunnedLabel: "true"}))

	if err := c.SetPodState(context.Background(), testNamespace, "agent-cardvault", StateRunning); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	pod, _ := cs.CoreV1().Pods(testNamespace).Get(context.Background(), "agent-cardvault", metav1.GetOptions{})
	if got := pod.Labels[StunnedLabel]; got != "false" {
		t.Fatalf("expected stunned=false after restoring to running, got %q", got)
	}
}

// Containment must be idempotent under retry — a hard blocker named by the card.
func TestK8sSetPodStateIsIdempotent(t *testing.T) {
	c, cs := newTestK8sClient(agentPod("agent-monitor", "active", nil))
	ctx := context.Background()

	if err := c.SetPodState(ctx, testNamespace, "agent-monitor", StateStunned); err != nil {
		t.Fatalf("first apply failed: %v", err)
	}
	if err := c.SetPodState(ctx, testNamespace, "agent-monitor", StateStunned); err != nil {
		t.Fatalf("second apply must be a no-op, not an error: %v", err)
	}

	pod, _ := cs.CoreV1().Pods(testNamespace).Get(ctx, "agent-monitor", metav1.GetOptions{})
	if pod.Labels[PodStateLabel] != StateStunned || pod.Labels[StunnedLabel] != "true" {
		t.Fatalf("end state diverged under retry: %v", pod.Labels)
	}
}

func TestK8sHealthHealthy(t *testing.T) {
	c, _ := newTestK8sClient(agentPod("agent-monitor", "idle", nil))
	if err := c.Health(context.Background()); err != nil {
		t.Fatalf("expected healthy, got %v", err)
	}
}

// Pod name and agent id diverge in the agent-swarm manifests, so the label
// selector fallback is a real code path, not defensive padding.
func TestK8sResolvesByAgentNameSelectorWhenPodNameDiffers(t *testing.T) {
	pod := agentPod("agent-monitor", "idle", nil)
	pod.Name = "monitor-7d9f8b5c4-xk2lm" // Deployment-generated name
	c, _ := newTestK8sClient(pod)

	state, err := c.GetPodState(context.Background(), testNamespace, "agent-monitor")
	if err != nil {
		t.Fatalf("selector fallback failed: %v", err)
	}
	if state != "idle" {
		t.Fatalf("expected idle via selector fallback, got %q", state)
	}
}

// Acting on the wrong pod is worse than declining to act.
func TestK8sAmbiguousTargetFailsClosed(t *testing.T) {
	a := agentPod("agent-monitor", "idle", nil)
	a.Name = "monitor-aaa"
	b := agentPod("agent-monitor", "idle", nil)
	b.Name = "monitor-bbb"
	c, _ := newTestK8sClient(a, b)

	state, err := c.GetPodState(context.Background(), testNamespace, "agent-monitor")
	assertUnavailable(t, err, "")
	if !strings.Contains(err.Error(), "ambiguous") {
		t.Fatalf("expected an ambiguity message, got %v", err)
	}
	if state != StateUnknown {
		t.Fatalf("expected %q for an ambiguous target, got %q", StateUnknown, state)
	}
}

// ── "The plane answered, and the answer is no" ───────────────────────────────

func TestK8sMissingPodIsNotFoundNotUnavailable(t *testing.T) {
	c, _ := newTestK8sClient() // empty cluster

	state, err := c.GetPodState(context.Background(), testNamespace, "agent-ghost")
	if err == nil {
		t.Fatal("expected an error for a pod that does not exist")
	}
	if !errors.Is(err, ErrTargetNotFound) {
		t.Fatalf("expected ErrTargetNotFound, got %v", err)
	}
	if errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("an absent pod is a definite answer; the plane is reachable: %v", err)
	}
	if state != StateUnknown {
		t.Fatalf("expected %q, got %q", StateUnknown, state)
	}
	if c.IsDegraded(testNamespace, "agent-ghost") {
		t.Fatal("NotFound must not mark the target degraded — that would report blindness we do not have")
	}
}

// A definite negative answer clears stale blindness, because it proves the plane
// came back.
func TestK8sAnsweredNotFoundClearsPriorDegradation(t *testing.T) {
	c, cs := newTestK8sClient()
	ctx := context.Background()

	o := newOutage(cs, []string{"get", "list"}, injectedGetFault)
	_, err := c.GetPodState(ctx, testNamespace, "agent-ghost")
	assertUnavailable(t, err, injectedGetFault)
	if !c.IsDegraded(testNamespace, "agent-ghost") {
		t.Fatal("expected the target to be degraded after an unreachable plane")
	}

	// Plane comes back; the pod genuinely does not exist.
	o.heal()
	_, err = c.GetPodState(ctx, testNamespace, "agent-ghost")
	if !errors.Is(err, ErrTargetNotFound) {
		t.Fatalf("expected ErrTargetNotFound once the plane recovered, got %v", err)
	}
	if c.IsDegraded(testNamespace, "agent-ghost") {
		t.Fatal("a plane that answers must clear the degraded record, even when the answer is negative")
	}
}

// ── Fail-closed path: the reason this card exists ────────────────────────────

func TestK8sGetPodStateUnavailableFailsClosed(t *testing.T) {
	c, cs := newTestK8sClient(agentPod("agent-monitor", "idle", nil))
	failOn(cs, "get", injectedGetFault)
	failOn(cs, "list", injectedListFault)

	state, err := c.GetPodState(context.Background(), testNamespace, "agent-monitor")
	assertUnavailable(t, err, injectedGetFault)

	// The whole defect in one assertion: the old client answered StateRunning here.
	if state == StateRunning {
		t.Fatal("GetPodState returned StateRunning for a target it could not read — this is the noopFleetClient defect")
	}
	if state != StateUnknown {
		t.Fatalf("expected %q, got %q", StateUnknown, state)
	}
	if !c.IsDegraded(testNamespace, "agent-monitor") {
		t.Fatal("an unreachable plane must record the target in fail-closed degraded isolation")
	}
}

func TestK8sSetPodStateUnavailableFailsClosed(t *testing.T) {
	c, cs := newTestK8sClient(agentPod("agent-monitor", "idle", nil))
	failOn(cs, "patch", injectedPatchFault)

	err := c.SetPodState(context.Background(), testNamespace, "agent-monitor", StateStunned)
	assertUnavailable(t, err, injectedPatchFault)
	if !c.IsDegraded(testNamespace, "agent-monitor") {
		t.Fatal("a failed containment write must mark the target degraded")
	}
}

// An RBAC denial means we cannot enforce. It is unavailability, not a verdict.
func TestK8sForbiddenMapsToUnavailable(t *testing.T) {
	c, cs := newTestK8sClient(agentPod("agent-monitor", "idle", nil))
	forbidden := apierrors.NewForbidden(
		schema.GroupResource{Resource: "pods"}, "agent-monitor",
		fmt.Errorf("pods is forbidden: User cannot patch resource"))
	cs.PrependReactor("patch", "pods", func(k8stesting.Action) (bool, runtime.Object, error) {
		return true, nil, forbidden
	})

	err := c.SetPodState(context.Background(), testNamespace, "agent-monitor", StateStunned)
	if !errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("a Forbidden response must be unavailability, not a verdict about the target: %v", err)
	}
	if errors.Is(err, ErrTargetNotFound) {
		t.Fatalf("Forbidden must not be reported as NotFound: %v", err)
	}
	// ...and separably identifiable, because a policy denial is permanent while
	// an unreachable plane is transient. A caller that retries the first forever
	// is retrying a decision that will never change.
	if !errors.Is(err, ErrEnforcementDenied) {
		t.Fatalf("a Forbidden response must also satisfy ErrEnforcementDenied: %v", err)
	}
}

// A plain connection failure must NOT be reported as a policy denial — the
// separation only buys anything if it runs both ways.
func TestK8sTransientFailureIsNotReportedAsDenial(t *testing.T) {
	c, cs := newTestK8sClient(agentPod("agent-monitor", "idle", nil))
	failOn(cs, "patch", injectedPatchFault)

	err := c.SetPodState(context.Background(), testNamespace, "agent-monitor", StateStunned)
	assertUnavailable(t, err, injectedPatchFault)
	if errors.Is(err, ErrEnforcementDenied) {
		t.Fatalf("a transient plane failure must not be classified as a permanent denial: %v", err)
	}
}

// ── Per-plane degradation ────────────────────────────────────────────────────
//
// Added after review found the registry keyed by target alone. The credential
// stubs always fail, so every target was permanently degraded — and then the
// next successful SetPodState, which proves something only about the FREEZE
// plane, cleared a record whose subject was the BAO plane and which was still
// true. One plane's partial success vouching for its siblings.

func TestDegradedRegistryIsKeyedPerPlane(t *testing.T) {
	c, _ := newTestK8sClient(agentPod("agent-monitor", "idle", nil))
	ctx := context.Background()

	// Bao plane fails (typed P2-1 stub); freeze plane is healthy.
	_ = c.RevokeCredentials(ctx, "agent-monitor")
	if !c.degraded.isDegradedOnPlane(PlaneBao, testNamespace, "agent-monitor") {
		t.Fatal("expected the bao plane to be degraded after the credential stub failed")
	}

	if err := c.SetPodState(ctx, testNamespace, "agent-monitor", StateStunned); err != nil {
		t.Fatalf("the freeze plane should be healthy: %v", err)
	}

	// The freeze-plane success must NOT retract the bao-plane claim.
	if !c.degraded.isDegradedOnPlane(PlaneBao, testNamespace, "agent-monitor") {
		t.Fatal("a freeze-plane success erased a bao-plane degradation that is still true — " +
			"one plane's partial success must never vouch for its siblings")
	}
	if c.degraded.isDegradedOnPlane(PlaneFreeze, testNamespace, "agent-monitor") {
		t.Fatal("the freeze plane answered and should not be degraded")
	}
	// And the target as a whole is still not fully contained.
	if !c.IsDegraded(testNamespace, "agent-monitor") {
		t.Fatal("a target degraded on ANY plane is not fully contained")
	}
}

// ── Review round 2 ───────────────────────────────────────────────────────────

// A stun must not land on a pod the sentinel does not watch. Labelling such a
// pod returns nil — full success — for a workload that will never be frozen.
func TestK8sRefusesPodTheSentinelDoesNotWatch(t *testing.T) {
	pod := agentPod("agent-rogue", "idle", nil)
	delete(pod.Labels, AgentLabel) // present in fleet-config, missing the discovery label
	c, cs := newTestK8sClient(pod)

	err := c.SetPodState(context.Background(), testNamespace, "agent-rogue", StateStunned)
	if err == nil {
		t.Fatal("labelled a pod outside the sentinel's informer and reported success — " +
			"the agent would keep running at full privilege with every layer showing 'contained'")
	}
	assertUnavailable(t, err, "")
	if !strings.Contains(err.Error(), AgentLabel) {
		t.Fatalf("the refusal must name the missing label, got %v", err)
	}

	after, _ := cs.CoreV1().Pods(testNamespace).Get(context.Background(), "agent-rogue", metav1.GetOptions{})
	if after.Labels[PodStateLabel] == StateStunned {
		t.Fatal("the pod was patched despite the refusal")
	}
	if !c.IsDegraded(testNamespace, "agent-rogue") {
		t.Fatal("an unenforceable target must be recorded as degraded")
	}
}

// Retrying a containment must not restamp the forensic timestamp.
func TestK8sRetryPreservesTheContainmentTimestamp(t *testing.T) {
	first := time.Date(2026, 9, 15, 9, 0, 0, 0, time.UTC)
	c, cs := newTestK8sClientAt(first, agentPod("agent-monitor", "idle", nil))
	ctx := context.Background()

	if err := c.SetPodState(ctx, testNamespace, "agent-monitor", StateStunned); err != nil {
		t.Fatalf("first stun failed: %v", err)
	}
	pod, _ := cs.CoreV1().Pods(testNamespace).Get(ctx, "agent-monitor", metav1.GetOptions{})
	original := pod.Annotations[StunnedAtAnnotation]
	if original != first.Format(time.RFC3339) {
		t.Fatalf("expected %q, got %q", first.Format(time.RFC3339), original)
	}

	// An operator retries four minutes later, or a second cascade covers the
	// same target.
	c.now = func() time.Time { return first.Add(4 * time.Minute) }
	if err := c.SetPodState(ctx, testNamespace, "agent-monitor", StateStunned); err != nil {
		t.Fatalf("retry failed: %v", err)
	}

	pod, _ = cs.CoreV1().Pods(testNamespace).Get(ctx, "agent-monitor", metav1.GetOptions{})
	if got := pod.Annotations[StunnedAtAnnotation]; got != original {
		t.Fatalf("a retry overwrote the containment timestamp: %q -> %q. That value is what an "+
			"incident timeline and the attested record are built on; a retry must not reset it to "+
			"'when someone last pressed the button'", original, got)
	}
}

// A fresh stun re-stamps, because it is a new containment.
func TestK8sNewContainmentStampsANewTimestamp(t *testing.T) {
	first := time.Date(2026, 9, 15, 9, 0, 0, 0, time.UTC)
	c, cs := newTestK8sClientAt(first, agentPod("agent-monitor", "idle", nil))
	ctx := context.Background()

	_ = c.SetPodState(ctx, testNamespace, "agent-monitor", StateStunned)
	_ = c.SetPodState(ctx, testNamespace, "agent-monitor", StateRunning) // blanks the annotation

	later := first.Add(time.Hour)
	c.now = func() time.Time { return later }
	_ = c.SetPodState(ctx, testNamespace, "agent-monitor", StateStunned)

	pod, _ := cs.CoreV1().Pods(testNamespace).Get(ctx, "agent-monitor", metav1.GetOptions{})
	if got := pod.Annotations[StunnedAtAnnotation]; got != later.Format(time.RFC3339) {
		t.Fatalf("a NEW containment must carry a new timestamp; expected %q, got %q",
			later.Format(time.RFC3339), got)
	}
}

// Caller cancellation is not plane unavailability. We hung up; the plane was fine.
func TestK8sCallerCancellationIsNotPlaneUnavailability(t *testing.T) {
	c, cs := newTestK8sClient(agentPod("agent-monitor", "idle", nil))
	cs.PrependReactor("patch", "pods", func(k8stesting.Action) (bool, runtime.Object, error) {
		return true, nil, context.Canceled
	})

	err := c.SetPodState(context.Background(), testNamespace, "agent-monitor", StateStunned)
	if err == nil {
		t.Fatal("expected an error")
	}
	if errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("the caller cancelled; the plane was healthy. Reporting that as blindness marks "+
			"a target degraded on no evidence: %v", err)
	}
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("the cancellation must remain inspectable, got %v", err)
	}
	if c.IsDegraded(testNamespace, "agent-monitor") {
		t.Fatal("a cancelled request must not mark the target degraded")
	}
}

// Two %w verbs, so the cause survives for errors.Is downstream.
func TestK8sErrorChainPreservesTheCause(t *testing.T) {
	c, cs := newTestK8sClient(agentPod("agent-monitor", "idle", nil))
	cs.PrependReactor("patch", "pods", func(k8stesting.Action) (bool, runtime.Object, error) {
		return true, nil, context.DeadlineExceeded
	})

	err := c.SetPodState(context.Background(), testNamespace, "agent-monitor", StateStunned)
	if !errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("expected ErrEnforcementUnavailable, got %v", err)
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("flattening the cause with %%v would leave a caller unable to tell a timeout from "+
			"a dead API server: %v", err)
	}
}

// The snapshot's Details map must be a copy, not a shared header.
func TestDegradedSnapshotDeepCopiesDetails(t *testing.T) {
	c, cs := newTestK8sClient(agentPod("agent-monitor", "idle", nil))
	failOn(cs, "patch", injectedPatchFault)
	_ = c.SetPodState(context.Background(), testNamespace, "agent-monitor", StateStunned)

	snap := c.DegradedTargets()
	for k := range snap {
		snap[k].Result.Details["operation"] = "MUTATED-THROUGH-THE-SNAPSHOT"
	}

	fresh := c.DegradedTargets()
	for k, entry := range fresh {
		if entry.Result.Details["operation"] == "MUTATED-THROUGH-THE-SNAPSHOT" {
			t.Fatalf("entry %q: writing through the snapshot reached the live registry — an "+
				"unsynchronised concurrent map write, which Go turns into a runtime throw", k)
		}
	}
}

// A slow verdict must not overwrite a fresher one.
func TestDegradedRegistryRejectsStaleVerdicts(t *testing.T) {
	r := newDegradedRegistry()
	target := TargetRef{AgentID: "agent-monitor", Namespace: testNamespace}

	stale := r.nextSeq() // request A's ticket, taken first
	fresh := r.nextSeq() // request B's ticket, taken second

	// B (fresh) records unavailability; A (stale) then returns success and tries
	// to clear. The clear must be refused.
	r.mark(fresh, PlaneFreeze, target, "set_pod_state",
		fmt.Errorf("boom: %w", ErrEnforcementUnavailable))
	r.clear(stale, PlaneFreeze, testNamespace, "agent-monitor")

	if !r.isDegradedOnPlane(PlaneFreeze, testNamespace, "agent-monitor") {
		t.Fatal("a slow success erased a fresher failure — the target is reported healthy while " +
			"the plane genuinely could not be reached")
	}

	// The reverse ordering must clear normally.
	r.clear(r.nextSeq(), PlaneFreeze, testNamespace, "agent-monitor")
	if r.isDegradedOnPlane(PlaneFreeze, testNamespace, "agent-monitor") {
		t.Fatal("a genuinely later success failed to clear the record")
	}
}

// Concurrent operations against one client must not corrupt the registry.
// Meaningful only under -race, which CI must run.
func TestDegradedRegistryUnderConcurrentOperations(t *testing.T) {
	c, _ := newTestK8sClient(agentPod("agent-monitor", "idle", nil))
	ctx := context.Background()

	var wg sync.WaitGroup
	for i := 0; i < 24; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			switch i % 4 {
			case 0:
				_, _ = c.GetPodState(ctx, testNamespace, "agent-monitor")
			case 1:
				_ = c.SetPodState(ctx, testNamespace, "agent-monitor", StateStunned)
			case 2:
				_ = c.RevokeCredentials(ctx, "agent-monitor")
			case 3:
				_ = len(c.DegradedTargets())
			}
		}(i)
	}
	wg.Wait()

	// The bao plane always fails, so it must still be recorded after the storm.
	if !c.degraded.isDegradedOnPlane(PlaneBao, testNamespace, "agent-monitor") {
		t.Fatal("the credential plane is known-broken but the registry lost the record")
	}
}

func TestDegradedSnapshotDistinguishesPlanes(t *testing.T) {
	c, cs := newTestK8sClient(agentPod("agent-monitor", "idle", nil))
	ctx := context.Background()
	failOn(cs, "patch", injectedPatchFault)

	_ = c.RevokeCredentials(ctx, "agent-monitor")
	_ = c.SetPodState(ctx, testNamespace, "agent-monitor", StateStunned)

	snapshot := c.DegradedTargets()
	if len(snapshot) != 2 {
		t.Fatalf("expected one entry per failing plane, got %d: %v", len(snapshot), snapshot)
	}
	planes := map[EnforcementPlane]bool{}
	for _, entry := range snapshot {
		planes[entry.Result.Plane] = true
		if entry.Result.Outcome != OutcomeUnavailable {
			t.Fatalf("expected %q, got %q", OutcomeUnavailable, entry.Result.Outcome)
		}
	}
	for _, want := range []EnforcementPlane{PlaneBao, PlaneFreeze} {
		if !planes[want] {
			t.Fatalf("plane %q missing from the degraded snapshot: %v", want, planes)
		}
	}
}

func TestK8sHealthUnavailable(t *testing.T) {
	c, cs := newTestK8sClient()
	failOn(cs, "list", injectedListFault)

	err := c.Health(context.Background())
	assertUnavailable(t, err, injectedListFault)
}

// ── Typed credential stubs (P2-1 / P2-2) ─────────────────────────────────────

func TestK8sCredentialStubsFailClosed(t *testing.T) {
	c, _ := newTestK8sClient()
	ctx := context.Background()

	for name, call := range map[string]func() error{
		"RevokeCredentials":  func() error { return c.RevokeCredentials(ctx, "agent-monitor") },
		"RestoreCredentials": func() error { return c.RestoreCredentials(ctx, "agent-monitor") },
	} {
		err := call()
		if err == nil {
			t.Fatalf("%s returned nil — nil is what a WORKING revocation returns, so an unimplemented "+
				"stub returning it recreates the exact silent-success defect this card removes", name)
		}
		if !errors.Is(err, ErrEnforcementUnavailable) {
			t.Fatalf("%s: expected ErrEnforcementUnavailable, got %v", name, err)
		}
	}

	if !c.IsDegraded(testNamespace, "agent-monitor") {
		t.Fatal("a credential stub failure must record the target as degraded")
	}
}

// ── The degraded registry ────────────────────────────────────────────────────

func TestK8sDegradedRegistryCarriesP12Schema(t *testing.T) {
	c, cs := newTestK8sClient(agentPod("agent-monitor", "idle", nil))
	failOn(cs, "patch", injectedPatchFault)

	_ = c.SetPodState(context.Background(), testNamespace, "agent-monitor", StateStunned)

	snapshot := c.DegradedTargets()
	entry, ok := snapshot[degradedKey(PlaneFreeze, testNamespace, "agent-monitor")]
	if !ok {
		t.Fatalf("expected a degraded entry; snapshot had %d", len(snapshot))
	}
	if entry.Result.Outcome != OutcomeUnavailable {
		t.Fatalf("expected %q, got %q", OutcomeUnavailable, entry.Result.Outcome)
	}
	if !entry.Result.Outcome.IsValid() {
		t.Fatal("the recorded outcome must be a valid member of the P1-2 enum")
	}
	if entry.Target.AgentID != "agent-monitor" || entry.Target.Namespace != testNamespace {
		t.Fatalf("target not recorded: %+v", entry.Target)
	}
	if entry.Result.Timestamp == "" {
		t.Fatal("a degraded record with no timestamp cannot be placed on an incident timeline")
	}

	// The snapshot must be a copy, not the live map.
	delete(snapshot, degradedKey(PlaneFreeze, testNamespace, "agent-monitor"))
	if !c.IsDegraded(testNamespace, "agent-monitor") {
		t.Fatal("DegradedTargets leaked the live registry — a caller can erase containment state")
	}
}

func TestK8sSuccessClearsDegradedRegistry(t *testing.T) {
	c, cs := newTestK8sClient(agentPod("agent-monitor", "idle", nil))
	ctx := context.Background()

	o := newOutage(cs, []string{"get", "list"}, injectedGetFault)
	_, _ = c.GetPodState(ctx, testNamespace, "agent-monitor")
	if !c.IsDegraded(testNamespace, "agent-monitor") {
		t.Fatal("expected degraded after the injected fault")
	}

	o.heal() // plane recovers
	if _, err := c.GetPodState(ctx, testNamespace, "agent-monitor"); err != nil {
		t.Fatalf("unexpected error after recovery: %v", err)
	}
	if c.IsDegraded(testNamespace, "agent-monitor") {
		t.Fatal("a successful read must clear the fail-closed record")
	}
}

// ── unavailableFleetClient: no method may return nil ─────────────────────────

func TestUnavailableClientNeverReturnsNil(t *testing.T) {
	u := newUnavailableFleetClient(errors.New("no kubeconfig and not in a cluster"), testNamespace)
	ctx := context.Background()

	state, err := u.GetPodState(ctx, testNamespace, "agent-monitor")
	assertUnavailable(t, err, "")
	if state != StateUnknown {
		t.Fatalf("expected %q, got %q", StateUnknown, state)
	}
	if state == StateRunning {
		t.Fatal("the fail-closed client must never report a plausible running state")
	}

	for name, err := range map[string]error{
		"SetPodState":        u.SetPodState(ctx, testNamespace, "agent-monitor", StateStunned),
		"RevokeCredentials":  u.RevokeCredentials(ctx, "agent-monitor"),
		"RestoreCredentials": u.RestoreCredentials(ctx, "agent-monitor"),
		"Health":             u.Health(ctx),
	} {
		if err == nil {
			t.Fatalf("%s returned nil — the fail-closed client must never claim success", name)
		}
		if !errors.Is(err, ErrEnforcementUnavailable) {
			t.Fatalf("%s: expected ErrEnforcementUnavailable, got %v", name, err)
		}
	}

	if len(u.DegradedTargets()) == 0 {
		t.Fatal("the fail-closed client must record the targets it could not act on")
	}
}

// ── Selection: the no-op must be unreachable without the exact literal ───────

// okLoader/okBuilder stand in for a reachable cluster; failLoader for one that
// is not configured at all.
func okLoader() (*rest.Config, string, error) {
	return &rest.Config{Host: "https://test"}, "test loader", nil
}

func failLoader() (*rest.Config, string, error) {
	return nil, "test loader", errors.New("no in-cluster config and KUBECONFIG is unset")
}

func fakeBuilder(*rest.Config) (kubernetes.Interface, error) {
	return fake.NewSimpleClientset(), nil
}

// The central guarantee of this card: nothing but the exact literal reaches the
// no-op. Near-misses, typos and case variants must fall to the real client.
func TestSelectFleetClientNeverDefaultsToNoop(t *testing.T) {
	nearMisses := []string{
		"", "auto", "kubernetes", "noop", "NOOP-TEST-ONLY", "Noop-Test-Only",
		"none", "test", "noop-test-only ", " noop-test-only", "no-op-test-only", "disabled", "  ",
	}

	for _, requested := range nearMisses {
		t.Run("requested="+strconv.Quote(requested), func(t *testing.T) {
			sel := selectFleetClient(requested, testNamespace, okLoader, fakeBuilder)
			if sel.Kind == fleetClientNoopTestOnly {
				t.Fatalf("value %q reached the no-op double; only the exact literal %q may",
					requested, fleetClientNoopTestOnly)
			}
			if sel.Kind != fleetClientKubernetes {
				t.Fatalf("expected the real client for %q, got %q", requested, sel.Kind)
			}
			if _, isNoop := sel.Client.(*noopFleetClient); isNoop {
				t.Fatalf("value %q produced a *noopFleetClient instance", requested)
			}
			if sel.Client == nil {
				t.Fatal("selection must never return a nil Client")
			}
			if !sel.Enforcing {
				t.Fatalf("the real client must report Enforcing=true, got false for %q", requested)
			}
		})
	}
}

// The environment must not be able to disarm enforcement. Injecting an env var
// is a far lower bar than rewriting a container's argv: `kubectl set env`, an
// envFrom ConfigMap merge, or a mutating webhook all reach it.
func TestSelectFleetClientRefusesTheNoopFromTheEnvironment(t *testing.T) {
	sel := selectFleetClientFrom(string(fleetClientNoopTestOnly), requestSourceEnv,
		testNamespace, okLoader, fakeBuilder)

	if sel.Kind == fleetClientNoopTestOnly {
		t.Fatal("FLEET_CLIENT=noop-test-only disarmed enforcement from the environment; " +
			"the double must require the command line")
	}
	if sel.Kind != fleetClientKubernetes {
		t.Fatalf("expected the real client, got %q", sel.Kind)
	}
	if !sel.Enforcing {
		t.Fatal("refusing the env request must leave the process ENFORCING, not degraded")
	}
}

// ...while the same value on the command line still works.
func TestSelectFleetClientAcceptsTheNoopFromTheFlag(t *testing.T) {
	sel := selectFleetClientFrom(string(fleetClientNoopTestOnly), requestSourceFlag,
		testNamespace, okLoader, fakeBuilder)
	if sel.Kind != fleetClientNoopTestOnly {
		t.Fatalf("the command-line route must still reach the double, got %q", sel.Kind)
	}
}

// The environment may still ask for the real client.
func TestSelectFleetClientAcceptsRealClientFromTheEnvironment(t *testing.T) {
	for _, requested := range []string{"", "auto", "kubernetes"} {
		sel := selectFleetClientFrom(requested, requestSourceEnv, testNamespace, okLoader, fakeBuilder)
		if sel.Kind != fleetClientKubernetes {
			t.Fatalf("env value %q should select the real client, got %q", requested, sel.Kind)
		}
	}
}

func TestSelectFleetClientExactLiteralReachesNoop(t *testing.T) {
	sel := selectFleetClient(string(fleetClientNoopTestOnly), testNamespace, okLoader, fakeBuilder)
	if sel.Kind != fleetClientNoopTestOnly {
		t.Fatalf("expected the no-op double, got %q", sel.Kind)
	}
	if _, ok := sel.Client.(*noopFleetClient); !ok {
		t.Fatalf("expected *noopFleetClient, got %T", sel.Client)
	}
	if sel.Enforcing {
		t.Fatal("the no-op double must never report Enforcing=true — it enforces nothing")
	}
}

// No cluster config must produce the FAIL-CLOSED client, never the no-op. This
// is the substitution the original code got exactly backwards.
func TestSelectFleetClientUnconfiguredFailsClosedNotNoop(t *testing.T) {
	sel := selectFleetClient("", testNamespace, failLoader, fakeBuilder)

	if sel.Kind == fleetClientNoopTestOnly {
		t.Fatal("an unreachable cluster must NOT fall back to the no-op — that is the original defect")
	}
	if sel.Kind != fleetClientUnavailable {
		t.Fatalf("expected %q, got %q", fleetClientUnavailable, sel.Kind)
	}
	if sel.Enforcing {
		t.Fatal("the fail-closed client must report Enforcing=false")
	}
	if err := sel.Client.Health(context.Background()); !errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("expected ErrEnforcementUnavailable from the fallback client, got %v", err)
	}
}

func TestSelectFleetClientClientsetFailureFailsClosed(t *testing.T) {
	sel := selectFleetClient("kubernetes", testNamespace, okLoader,
		func(*rest.Config) (kubernetes.Interface, error) {
			return nil, errors.New("INJECTED-CLIENTSET-FAULT")
		})

	if sel.Kind != fleetClientUnavailable {
		t.Fatalf("expected %q, got %q", fleetClientUnavailable, sel.Kind)
	}
	if !strings.Contains(sel.Reason, "INJECTED-CLIENTSET-FAULT") {
		t.Fatalf("the construction failure must be carried in the selection reason, got %q", sel.Reason)
	}
}

// ── The full containment field set ───────────────────────────────────────────
//
// Folded in after an independent derivation of the label contract found that the
// sentinel ORs three terms, not one, and that no writer in the repo clears the
// provenance annotations on recover.

func TestK8sSetPodStateWritesAllThreeSentinelTerms(t *testing.T) {
	c, cs := newTestK8sClient(agentPod("agent-monitor", "idle", nil))

	if err := c.SetPodState(context.Background(), testNamespace, "agent-monitor", StateStunned); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	pod, _ := cs.CoreV1().Pods(testNamespace).Get(context.Background(), "agent-monitor", metav1.GetOptions{})
	for label, want := range map[string]string{
		PodStateLabel:        StateStunned,
		StunnedLabel:         "true",
		ContainmentModeLabel: ContainmentModeFrozen,
	} {
		if got := pod.Labels[label]; got != want {
			t.Fatalf("%s: expected %q, got %q — the sentinel ORs all three, so all three must be written together",
				label, want, got)
		}
	}
	if pod.Annotations[StunnedAtAnnotation] == "" {
		t.Fatal("a containment with no timestamp cannot be placed on an incident timeline")
	}
	if pod.Annotations[StunReasonAnnotationAI] == "" || pod.Annotations[StunReasonAnnotationIO] == "" {
		t.Fatalf("both stun-reason annotations must be written; got ai=%q io=%q",
			pod.Annotations[StunReasonAnnotationAI], pod.Annotations[StunReasonAnnotationIO])
	}
}

// Restoring must leave NO term of the sentinel's OR true, or the pod stays
// frozen while the dashboard reports it healthy.
func TestK8sRestoreClearsEveryContainmentTerm(t *testing.T) {
	c, cs := newTestK8sClient(agentPod("agent-monitor", "idle", nil))
	ctx := context.Background()

	if err := c.SetPodState(ctx, testNamespace, "agent-monitor", StateStunned); err != nil {
		t.Fatalf("stun failed: %v", err)
	}
	if err := c.SetPodState(ctx, testNamespace, "agent-monitor", StateRunning); err != nil {
		t.Fatalf("restore failed: %v", err)
	}

	pod, _ := cs.CoreV1().Pods(testNamespace).Get(ctx, "agent-monitor", metav1.GetOptions{})

	// Mirror of signalloom-stun-sentinel/main.go:31-43.
	stillStunned := pod.Labels[PodStateLabel] == StateStunned ||
		pod.Labels[StunnedLabel] == "true" ||
		pod.Labels[ContainmentModeLabel] == ContainmentModeFrozen
	if stillStunned {
		t.Fatalf("the sentinel would still consider this pod stunned after a restore: %v", pod.Labels)
	}

	for _, key := range []string{StunnedAtAnnotation, StunReasonAnnotationAI, StunReasonAnnotationIO} {
		got, present := pod.Annotations[key]
		if !present {
			t.Fatalf("%s was REMOVED rather than blanked; a path Flux cannot substitute into is dropped "+
				"from the ignore surface and wiped on the next reconcile", key)
		}
		if got != "" {
			t.Fatalf("%s: expected \"\" after restore, got %q — stale provenance survives the recovery", key, got)
		}
	}
}

// StateRunning is a Go constant, not a label value. Writing it verbatim would
// put a token outside AgentStateValue onto a live pod.
func TestK8sRestoreWritesALabelValueTheVocabularyAdmits(t *testing.T) {
	c, cs := newTestK8sClient(agentPod("agent-monitor", StateStunned, nil))

	if err := c.SetPodState(context.Background(), testNamespace, "agent-monitor", StateRunning); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	pod, _ := cs.CoreV1().Pods(testNamespace).Get(context.Background(), "agent-monitor", metav1.GetOptions{})
	got := pod.Labels[PodStateLabel]
	if got == "running" {
		t.Fatal("wrote the Go constant \"running\" onto a pod; it is in no manifest and in no client union, " +
			"so the dashboard's phase switch falls through to \"deployed\"")
	}
	if got != "active" {
		t.Fatalf("expected \"active\" (what every other un-stun path in the repo writes), got %q", got)
	}

	// The client-known vocabulary, from this module's own contract test.
	known := map[string]bool{
		"absent": true, "deploying": true, "active": true,
		"non-compliant": true, "grace-period": true, "stunned": true, "idle": true,
	}
	if !known[got] {
		t.Fatalf("%q is not a member of the client state vocabulary", got)
	}
}

// Match the field manager every other writer of these fields uses.
//
// client-go's fake clientset does not surface PatchOptions on the recorded
// action, so the manager itself cannot be asserted through the tracker. The
// check is therefore split: the constant's value, and a source read proving the
// Patch call site actually passes it. A test that only asserted the constant
// would pass against a call site that silently dropped it.
func TestK8sPatchCarriesTheRepoFieldManager(t *testing.T) {
	if PodPatchFieldManager != "flux-client-side-apply" {
		t.Fatalf("field manager drifted from the repo convention asserted by test/flux-drift-ignore.bats: %q",
			PodPatchFieldManager)
	}

	src, err := os.ReadFile("k8sclient.go")
	if err != nil {
		t.Fatalf("cannot read the client source: %v", err)
	}
	if !strings.Contains(string(src), "FieldManager: PodPatchFieldManager") {
		t.Fatal("the Patch call site does not pass PodPatchFieldManager; this client would be the first " +
			"writer of these fields to use a different manager, outside what .spec.ignore was validated against")
	}
}

// The patch must reach the API server as a strategic merge — a full replace
// would drop every label the client did not name.
func TestK8sPatchIsAStrategicMergeThatPreservesOtherLabels(t *testing.T) {
	pod := agentPod("agent-monitor", "idle", map[string]string{
		"signalloom.ai/team":  "sre",
		"signalloom.ai/fleet": "supercred",
	})
	c, cs := newTestK8sClient(pod)

	var sawPatch bool
	cs.PrependReactor("patch", "pods", func(action k8stesting.Action) (bool, runtime.Object, error) {
		if pa, ok := action.(k8stesting.PatchAction); ok {
			sawPatch = true
			if pa.GetPatchType() != types.StrategicMergePatchType {
				t.Errorf("expected a strategic merge patch, got %v", pa.GetPatchType())
			}
		}
		return false, nil, nil // fall through to the tracker
	})

	if err := c.SetPodState(context.Background(), testNamespace, "agent-monitor", StateStunned); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !sawPatch {
		t.Fatal("no patch action reached the fake clientset — the assertions above never ran")
	}

	updated, _ := cs.CoreV1().Pods(testNamespace).Get(context.Background(), "agent-monitor", metav1.GetOptions{})
	for _, key := range []string{AgentLabel, AgentNameLabel, "signalloom.ai/team", "signalloom.ai/fleet"} {
		if updated.Labels[key] == "" {
			t.Fatalf("label %q was dropped by the containment patch", key)
		}
	}
}
