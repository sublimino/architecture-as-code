// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"bytes"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Step 5: the reconciler never thaws a correlator freeze without an
// authorised resume.

const holdPodUID = "e02fe214-5d7c-423b-9fa9-f933932d6679"

type holdHarness struct {
	t     *testing.T
	r     *stunReconciler
	holds *stunHolds
	cg    string
	live  *corev1.Pod // what the API server returns
	log   *bytes.Buffer
	// tcDeletes counts drop-filter removals: the network quarantine lifting.
	tcDeletes int
}

func newHoldHarness(t *testing.T) *holdHarness {
	t.Helper()
	root := t.TempDir()
	cg := filepath.Join(root, "kubelet.slice", "kubelet-kubepods.slice", "kubelet-kubepods-burstable.slice",
		"kubelet-kubepods-burstable-pod"+strings.ReplaceAll(holdPodUID, "-", "_")+".slice")
	mockFreezableCgroup(t, cg, false)
	simulateKernel(t, cg)

	h := &holdHarness{t: t, cg: cg}
	h.live = &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Namespace: "fe-signalloom-agents", Name: "agent-kusari-5685ff664b-kv25k", UID: holdPodUID,
			Labels: map[string]string{"app.kubernetes.io/name": "kusari-agent", "signalloom.ai/agent": "true"}},
		Status: corev1.PodStatus{Phase: corev1.PodRunning},
	}
	tc := newTCDropFilter()
	tc.run = func(_ string, args ...string) ([]byte, error) {
		if len(args) > 1 && args[0] == "filter" && args[1] == "del" {
			h.tcDeletes++
		}
		return nil, nil
	}
	tc.pidForCgroup = func(string) (int, error) { return 100, nil }
	tc.peerIndex = func(int, string) (int, error) { return 42, nil }
	tc.interfaces = func() ([]net.Interface, error) { return []net.Interface{{Name: "veth42", Index: 42}}, nil }

	// The deadline is raised for the FAKE kernel's benefit, not the product's:
	// simulateKernel() below mirrors cgroup.freeze into cgroup.events from a
	// goroutine on a 1ms poll, and under host load that goroutine is not
	// scheduled inside the 50ms production default. Freeze latency itself is
	// tested in pkg/cgroup/freezer_test.go with explicit deadlines.
	freezer := newCgroupFreezer(root, false, "token", "token", cgroup.WithDeadline(harnessFreezeDeadline()))
	h.r = newStunReconciler(freezer, tc, newProbePreserver())
	h.holds = newStunHolds(freezer)
	h.holds.getPod = func(string, string) (*corev1.Pod, error) { return h.live.DeepCopy(), nil }
	h.r.holds = h.holds

	h.log = &bytes.Buffer{}
	SetAuditOutput(h.log)
	t.Cleanup(func() { SetAuditOutput(os.Stdout) })
	return h
}

// simulateKernel mirrors cgroup.freeze into cgroup.events, as the kernel does.
func simulateKernel(t *testing.T, cg string) {
	t.Helper()
	stop, done := make(chan struct{}), make(chan struct{})
	t.Cleanup(func() { close(stop); <-done })
	go func() {
		defer close(done)
		for {
			select {
			case <-stop:
				return
			default:
			}
			if b, err := os.ReadFile(filepath.Join(cg, "cgroup.freeze")); err == nil {
				ev := "populated 1\nfrozen 0\n"
				if strings.TrimSpace(string(b)) == "1" {
					ev = "populated 1\nfrozen 1\n"
				}
				_ = os.WriteFile(filepath.Join(cg, "cgroup.events"), []byte(ev), 0o644)
			}
			time.Sleep(time.Millisecond)
		}
	}()
}

func (h *holdHarness) frozen() bool {
	h.t.Helper()
	b, err := os.ReadFile(filepath.Join(h.cg, "cgroup.freeze"))
	if err != nil {
		h.t.Fatal(err)
	}
	return strings.TrimSpace(string(b)) == "1"
}

// detect freezes the pod exactly as the correlator does.
func (h *holdHarness) detect() {
	h.t.Helper()
	if err := newCorrelatorFreezeManager(h.holds).FreezePodFor(h.live.DeepCopy(), "sys_enter_openat", "/etc/passwd"); err != nil {
		h.t.Fatalf("correlator freeze: %v", err)
	}
	if !h.frozen() {
		h.t.Fatal("correlator freeze did not freeze the cgroup")
	}
}

// setLabels writes labels as some other principal would; "" deletes a key.
// The returned copy is what the informer then caches.
func (h *holdHarness) setLabels(kv map[string]string) *corev1.Pod {
	for k, v := range kv {
		if v == "" {
			delete(h.live.Labels, k)
		} else {
			h.live.Labels[k] = v
		}
	}
	return h.live.DeepCopy()
}

var (
	stunTriple   = map[string]string{labelStunnedAI: stunnedValue, labelStunnedIO: "true", labelContainmentMode: "frozen"}
	resumeTriple = map[string]string{labelStunnedAI: "active", labelStunnedIO: "false", labelContainmentMode: "none"}
	stripTriple  = map[string]string{labelStunnedAI: "", labelStunnedIO: "", labelContainmentMode: ""}
)

func (h *holdHarness) reconcile(pod *corev1.Pod) {
	h.t.Helper()
	if err := h.r.reconcile(pod); err != nil {
		h.t.Fatalf("reconcile: %v", err)
	}
}

func TestCorrelatorFreezeSurvivesReconcilerResync(t *testing.T) {
	h := newHoldHarness(t)
	h.detect()
	for i := 0; i < 2; i++ { // the resync that used to thaw it, and the next
		h.reconcile(h.live.DeepCopy())
		if !h.frozen() {
			t.Fatalf("resync %d thawed a correlator freeze", i)
		}
	}
	if !strings.Contains(h.log.String(), `"event":"thaw_refused_correlator_hold"`) {
		t.Fatalf("a refused thaw must be visible in the log:\n%s", h.log.String())
	}
}

func TestForgedResumeCannotThawAnUnrecordedFreeze(t *testing.T) {
	h := newHoldHarness(t)
	h.detect()
	// The resume triple, written before anyone recorded the stun: forged.
	h.reconcile(h.setLabels(resumeTriple))
	if !h.frozen() {
		t.Fatal("a resume written over an unrecorded freeze thawed it")
	}
}

func TestStaleCachedResumeCannotThawARecordedFreeze(t *testing.T) {
	h := newHoldHarness(t)
	h.detect()
	h.reconcile(h.setLabels(stunTriple)) // the stun is recorded
	cached := h.live.DeepCopy()
	cached.Labels = map[string]string{"signalloom.ai/agent": "true", labelStunnedIO: "false"} // pre-record cache
	h.reconcile(cached)
	if !h.frozen() {
		t.Fatal("an informer cache older than the stun record thawed the pod")
	}
}

func TestRemovingStunLabelsIsNotAResume(t *testing.T) {
	h := newHoldHarness(t)
	h.detect()
	h.reconcile(h.setLabels(stunTriple))
	h.reconcile(h.setLabels(stripTriple))
	if !h.frozen() || h.tcDeletes != 0 {
		t.Fatalf("stripping the stun labels released the pod (frozen=%v, tc filter deletes=%d)", h.frozen(), h.tcDeletes)
	}
}

func TestAuthorisedResumeThawsAndDropsTheHold(t *testing.T) {
	h := newHoldHarness(t)
	h.detect()
	h.reconcile(h.setLabels(stunTriple))
	h.reconcile(h.setLabels(resumeTriple))
	if h.frozen() {
		t.Fatal("an authorised resume of a recorded stun left the pod frozen")
	}
	h.holds.mu.Lock()
	_, held := h.holds.held[holdPodUID]
	h.holds.mu.Unlock()
	if held {
		t.Fatal("the hold survived its resume")
	}
}

func TestThawLosesToADetectionLandingAfterTheReleaseDecision(t *testing.T) {
	h := newHoldHarness(t)
	verdict, gen, err := h.holds.decide(h.live.DeepCopy()) // no hold yet: the legacy path would thaw
	if verdict != verdictNone || err != nil {
		t.Fatalf("decide = %v, %v; want verdictNone", verdict, err)
	}
	h.detect()
	thawed, err := h.holds.thaw(holdPodUID, false, gen, func() error { return h.r.freezer.unfreeze(h.cg) })
	if err != nil || thawed || !h.frozen() {
		t.Fatalf("thawed=%v err=%v frozen=%v: a detection after the decision must win", thawed, err, h.frozen())
	}
}

func TestResumeLosesToADetectionLandingAfterTheResumeDecision(t *testing.T) {
	h := newHoldHarness(t)
	h.detect()
	h.reconcile(h.setLabels(stunTriple))
	verdict, gen, err := h.holds.decide(h.setLabels(resumeTriple))
	if verdict != verdictRelease || err != nil {
		t.Fatalf("decide = %v, %v; want verdictRelease", verdict, err)
	}
	h.detect() // a new sensitive syscall before the thaw runs
	thawed, err := h.holds.thaw(holdPodUID, true, gen, func() error { return h.r.freezer.unfreeze(h.cg) })
	if err != nil || thawed || !h.frozen() {
		t.Fatalf("thawed=%v err=%v frozen=%v: a resume decided before a fresh detection must not thaw it", thawed, err, h.frozen())
	}
}

func TestReplacementPodUnderTheSameNameIsNotAResume(t *testing.T) {
	h := newHoldHarness(t)
	h.detect()
	h.reconcile(h.setLabels(stunTriple))
	cached := h.setLabels(resumeTriple)
	h.live.UID = "11111111-2222-3333-4444-555555555555" // the API now serves a same-named replacement
	h.reconcile(cached)
	if !h.frozen() {
		t.Fatal("a resumed replacement pod released the original pod's hold")
	}
}

func TestUnconfirmableResumeKeepsTheFreezeAndRequeues(t *testing.T) {
	h := newHoldHarness(t)
	h.detect()
	h.reconcile(h.setLabels(stunTriple))
	h.holds.getPod = func(string, string) (*corev1.Pod, error) { return nil, errors.New("apiserver unavailable") }
	err := h.r.reconcile(h.setLabels(resumeTriple))
	if err == nil || !strings.Contains(err.Error(), "apiserver unavailable") {
		t.Fatalf("reconcile err = %v; want the failed confirmation returned so the resume is retried", err)
	}
	if !h.frozen() {
		t.Fatal("a resume the API server could not confirm thawed the pod")
	}
}

// Release order, on its merits (W6): thaw FIRST, then lift the network drop.
// A release reached through the hold set is an authorised resume, so the only
// question left is which failure mode a partial release leaves behind. Thaw
// first leaves a running pod that is still network-isolated until the detach
// retries; detach first can leave a frozen pod that never comes back (no veth
// before its sandbox joined a netns). So: the cgroup is already thawed when
// the drop filter is removed, and the filter IS removed when the veth resolves.
func TestReleaseThawsBeforeItLiftsTheNetworkDrop(t *testing.T) {
	h := newHoldHarness(t)
	var thawedAtDetach []bool
	run := h.r.tc.run
	h.r.tc.run = func(name string, args ...string) ([]byte, error) {
		if len(args) > 1 && args[0] == "filter" && args[1] == "del" {
			thawedAtDetach = append(thawedAtDetach, !h.frozen())
		}
		return run(name, args...)
	}
	h.reconcile(h.setLabels(stunTriple))   // stunned: frozen and network-dropped
	h.reconcile(h.setLabels(resumeTriple)) // authorised resume
	if h.frozen() {
		t.Fatal("an authorised resume left the pod frozen")
	}
	if len(thawedAtDetach) != 2 {
		t.Fatalf("drop filter deletes = %d, want ingress and egress removed once the veth resolves", len(thawedAtDetach))
	}
	for i, thawed := range thawedAtDetach {
		if !thawed {
			t.Fatalf("filter delete %d ran while the pod was still frozen: the network release came before the thaw", i)
		}
	}
}
