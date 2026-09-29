package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// ── Fakes ────────────────────────────────────────────────────────────────────

type annotationPatch struct {
	namespace, name string
	annotations     map[string]string
}

// fakeKubeAPI records annotation patches and serves owner objects by name.
type fakeKubeAPI struct {
	patches     []annotationPatch
	patchErr    error
	replicaSets map[string]*appsv1.ReplicaSet
	deployments map[string]*appsv1.Deployment
	gets        int
}

func (f *fakeKubeAPI) PatchPodAnnotations(_ context.Context, namespace, name string, annotations map[string]string) error {
	if f.patchErr != nil {
		return f.patchErr
	}
	f.patches = append(f.patches, annotationPatch{namespace, name, annotations})
	return nil
}

func (f *fakeKubeAPI) GetReplicaSet(_ context.Context, namespace, name string) (*appsv1.ReplicaSet, error) {
	f.gets++
	if rs, ok := f.replicaSets[name]; ok {
		return rs, nil
	}
	return nil, apierrors.NewNotFound(schema.GroupResource{Group: "apps", Resource: "replicasets"}, name)
}

func (f *fakeKubeAPI) GetDeployment(_ context.Context, namespace, name string) (*appsv1.Deployment, error) {
	f.gets++
	if d, ok := f.deployments[name]; ok {
		return d, nil
	}
	return nil, apierrors.NewNotFound(schema.GroupResource{Group: "apps", Resource: "deployments"}, name)
}

const kernelTestUID = "0c5e2d4a-1111-2222-3333-444455556666"

type kernelHarness struct {
	reconciler *stunReconciler
	api        *fakeKubeAPI
	audit      *bytes.Buffer
	cgroup     string
	clock      *time.Time
}

// newKernelHarness builds a NON-dry-run reconciler over a fake cgroup tree
// whose veth lookup fails exactly as it does live (cross-uid /proc/<pid>/ns/net
// denied), so every test also proves the kernel read happens before the veth
// step.
func newKernelHarness(t *testing.T, eventsBody string) *kernelHarness {
	t.Helper()
	root := t.TempDir()
	cg := filepath.Join(root, "kubepods.slice", "kubepods-burstable.slice",
		"kubepods-burstable-pod"+strings.ReplaceAll(kernelTestUID, "-", "_")+".slice")
	if err := os.MkdirAll(cg, 0o755); err != nil {
		t.Fatal(err)
	}
	for file, body := range map[string]string{"cgroup.freeze": "0", "cgroup.procs": "4242\n"} {
		if err := os.WriteFile(filepath.Join(cg, file), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if eventsBody != "" {
		if err := os.WriteFile(filepath.Join(cg, "cgroup.events"), []byte(eventsBody), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	tc := newTCDropFilter()
	tc.pidForCgroup = func(string) (int, error) {
		return 0, errors.New("open /proc/4242/ns/net: permission denied")
	}
	r := newStunReconciler(newCgroupFreezer(root, false, "token", "token"), tc, newProbePreserver())
	r.reconcileCount = &atomic.Int64{}
	api := &fakeKubeAPI{replicaSets: map[string]*appsv1.ReplicaSet{}, deployments: map[string]*appsv1.Deployment{}}
	clock := time.Date(2026, 9, 29, 22, 0, 0, 0, time.UTC)
	r.kernel = newKernelPublisher(api, 30*time.Second, false)
	h := &kernelHarness{reconciler: r, api: api, audit: &bytes.Buffer{}, cgroup: cg, clock: &clock}
	r.kernel.now = func() time.Time { return *h.clock }
	SetAuditOutput(h.audit)
	t.Cleanup(func() { SetAuditOutput(nil) })
	return h
}

func kernelTestPod(labels, annotations map[string]string) *corev1.Pod {
	return &corev1.Pod{ObjectMeta: metav1.ObjectMeta{
		Name: "agent-sir-lancelot", Namespace: "fe-signalloom-agents", UID: kernelTestUID,
		Labels: labels, Annotations: annotations,
	}}
}

func (h *kernelHarness) events(t *testing.T, name string) []stunEvent {
	t.Helper()
	var out []stunEvent
	for _, line := range bytes.Split(bytes.TrimSpace(h.audit.Bytes()), []byte("\n")) {
		if len(line) == 0 {
			continue
		}
		var ev stunEvent
		if err := json.Unmarshal(line, &ev); err != nil {
			t.Fatalf("audit line %q: %v", line, err)
		}
		if ev.Event == name {
			out = append(out, ev)
		}
	}
	return out
}

// ── (a) frozen 1 + no stun label ─────────────────────────────────────────────

func TestKernelTruth_FrozenUnlabelledPublishesTrueBeforeVethStep(t *testing.T) {
	h := newKernelHarness(t, "populated 1\nfrozen 1\n")
	// The static fake never settles a thaw (events stay frozen 1), so the
	// unstun path's unfreeze fails: the kernel read must already have
	// published, ahead of every containment step (unfreeze, veth, tc).
	err := h.reconciler.reconcile(kernelTestPod(map[string]string{labelStunnedAI: "idle"}, nil))
	if err == nil || !strings.Contains(err.Error(), "unfreeze") {
		t.Fatalf("reconcile err = %v, want the unsettled-thaw failure", err)
	}
	if len(h.api.patches) != 1 {
		t.Fatalf("patches = %+v, want exactly one despite the containment failure", h.api.patches)
	}
	p := h.api.patches[0]
	if p.namespace != "fe-signalloom-agents" || p.name != "agent-sir-lancelot" || p.annotations[annotationKernelFrozen] != "true" {
		t.Fatalf("patch = %+v, want kernel-frozen=true on the pod", p)
	}
	if _, perr := time.Parse(time.RFC3339, p.annotations[annotationKernelObservedAt]); perr != nil {
		t.Fatalf("kernel-observed-at %q is not RFC3339: %v", p.annotations[annotationKernelObservedAt], perr)
	}
	if got := h.events(t, "kernel_state"); len(got) != 1 || got[0].Details["frozen"] != true {
		t.Fatalf("kernel_state events = %+v, want one with frozen=true", got)
	}
	if got := h.events(t, "frozen_unlabelled"); len(got) != 1 || got[0].CgroupPath != h.cgroup {
		t.Fatalf("frozen_unlabelled events = %+v, want one naming the cgroup", got)
	}
	if n := h.reconciler.kernel.frozenUnlabelledCount(); n != 1 {
		t.Fatalf("frozen-unlabelled gauge = %d, want 1", n)
	}

	// Same resync window: the warning is rate-limited to once per pod.
	_ = h.reconciler.reconcile(kernelTestPod(map[string]string{labelStunnedAI: "idle"},
		map[string]string{annotationKernelFrozen: "true"}))
	if got := h.events(t, "frozen_unlabelled"); len(got) != 1 {
		t.Fatalf("frozen_unlabelled repeated inside one resync: %d events", len(got))
	}
	*h.clock = h.clock.Add(31 * time.Second)
	_ = h.reconciler.reconcile(kernelTestPod(map[string]string{labelStunnedAI: "idle"},
		map[string]string{annotationKernelFrozen: "true"}))
	if got := h.events(t, "frozen_unlabelled"); len(got) != 2 {
		t.Fatalf("frozen_unlabelled after a full resync = %d events, want 2", len(got))
	}
}

// ── (b) frozen 0 ─────────────────────────────────────────────────────────────

func TestKernelTruth_ThawedPublishesFalseWithoutWarning(t *testing.T) {
	h := newKernelHarness(t, "populated 1\nfrozen 0\n")
	_ = h.reconciler.reconcile(kernelTestPod(nil, nil))
	if len(h.api.patches) != 1 || h.api.patches[0].annotations[annotationKernelFrozen] != "false" {
		t.Fatalf("patches = %+v, want one kernel-frozen=false", h.api.patches)
	}
	if got := h.events(t, "frozen_unlabelled"); len(got) != 0 {
		t.Fatalf("frozen_unlabelled emitted for a thawed pod: %+v", got)
	}
	if n := h.reconciler.kernel.frozenUnlabelledCount(); n != 0 {
		t.Fatalf("gauge = %d, want 0", n)
	}
}

// ── (c) unchanged value ──────────────────────────────────────────────────────

func TestKernelTruth_UnchangedValueIsNotPatched(t *testing.T) {
	h := newKernelHarness(t, "populated 1\nfrozen 0\n")
	_ = h.reconciler.reconcile(kernelTestPod(nil, map[string]string{annotationKernelFrozen: "false"}))
	if len(h.api.patches) != 0 {
		t.Fatalf("patches = %+v, want none: annotation already matches the kernel", h.api.patches)
	}
	if got := h.events(t, "kernel_state"); len(got) != 0 {
		t.Fatalf("kernel_state emitted without a change: %+v", got)
	}
}

// ── unreadable cgroup.events: never assume ───────────────────────────────────

func TestKernelTruth_UnreadableEventsPublishesNothing(t *testing.T) {
	for name, body := range map[string]string{"missing": "", "no-frozen-key": "populated 1\n", "substring-trap": "unfrozen 1\n"} {
		t.Run(name, func(t *testing.T) {
			h := newKernelHarness(t, body)
			_ = h.reconciler.reconcile(kernelTestPod(nil, nil))
			if len(h.api.patches) != 0 {
				t.Fatalf("patches = %+v, want none when the kernel state is unknown", h.api.patches)
			}
			if got := h.events(t, "kernel_state_unreadable"); len(got) != 1 {
				t.Fatalf("kernel_state_unreadable events = %d, want 1", len(got))
			}
		})
	}
}

// ── (d) stun record on the owner ─────────────────────────────────────────────

func ownedPod() *corev1.Pod {
	pod := kernelTestPod(map[string]string{labelStunnedAI: "idle"}, nil)
	pod.Name = "agent-cardvault-bb57657-jlf8w"
	pod.OwnerReferences = []metav1.OwnerReference{{APIVersion: "apps/v1", Kind: "ReplicaSet", Name: "agent-cardvault-bb57657", Controller: boolPtr(true)}}
	return pod
}

func boolPtr(b bool) *bool { return &b }

func seedOwners(api *fakeKubeAPI, deploymentAnnotations map[string]string) {
	api.replicaSets["agent-cardvault-bb57657"] = &appsv1.ReplicaSet{ObjectMeta: metav1.ObjectMeta{
		Name: "agent-cardvault-bb57657", Namespace: "fe-signalloom-agents",
		OwnerReferences: []metav1.OwnerReference{{APIVersion: "apps/v1", Kind: "Deployment", Name: "agent-cardvault", Controller: boolPtr(true)}},
	}}
	api.deployments["agent-cardvault"] = &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{
		Name: "agent-cardvault", Namespace: "fe-signalloom-agents", Annotations: deploymentAnnotations,
	}}
}

func TestKernelTruth_DeploymentStunRecordMakesPodStunned(t *testing.T) {
	h := newKernelHarness(t, "populated 1\nfrozen 1\n")
	seedOwners(h.api, map[string]string{annotationOwnerStunned: "true"})
	pod := ownedPod()

	if !isPodStunned(pod, h.reconciler.kernel) {
		t.Fatal("pod whose Deployment carries signalloom.io/stunned=true is not treated as stunned")
	}
	err := h.reconciler.reconcile(pod)
	if err == nil || !strings.Contains(err.Error(), "after freezing pod") {
		t.Fatalf("reconcile err = %v, want the stun path (freeze, then veth failure)", err)
	}
	if got := h.events(t, "frozen_unlabelled"); len(got) != 0 {
		t.Fatalf("frozen_unlabelled emitted for an owner-stunned pod: %+v", got)
	}

	// The owner lookup is cached per pod UID for the resync period.
	gets := h.api.gets
	_ = h.reconciler.reconcile(pod)
	if h.api.gets != gets {
		t.Fatalf("owner lookup not cached: %d gets after second reconcile, want %d", h.api.gets, gets)
	}
	*h.clock = h.clock.Add(31 * time.Second)
	_ = h.reconciler.reconcile(pod)
	if h.api.gets == gets {
		t.Fatal("owner cache never expires")
	}
}

func TestKernelTruth_UnannotatedOwnerAndBarePodAreNotStunned(t *testing.T) {
	h := newKernelHarness(t, "populated 1\nfrozen 0\n")
	seedOwners(h.api, map[string]string{annotationOwnerStunned: "false"})
	if isPodStunned(ownedPod(), h.reconciler.kernel) {
		t.Fatal("stunned=false on the Deployment treated as stunned")
	}
	if isPodStunned(kernelTestPod(nil, nil), h.reconciler.kernel) {
		t.Fatal("bare pod without labels treated as stunned")
	}
	if isPodStunned(ownedPod(), nil) {
		t.Fatal("nil owner lookup must fall back to the three label terms")
	}
	if !isPodStunned(kernelTestPod(map[string]string{labelContainmentMode: "frozen"}, nil), nil) {
		t.Fatal("label terms regressed")
	}
}

// ── /metrics ─────────────────────────────────────────────────────────────────

func TestKernelTruth_MetricsExposesFrozenUnlabelledGauge(t *testing.T) {
	h := newKernelHarness(t, "populated 1\nfrozen 1\n")
	_ = h.reconciler.reconcile(kernelTestPod(nil, nil))
	srv := &HealthServer{frozenUnlabelled: h.reconciler.kernel.frozenUnlabelledCount}
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := rec.Body.String()
	if rec.Code != http.StatusOK || !strings.Contains(body, "# TYPE sentinel_frozen_unlabelled_pods gauge\n") ||
		!strings.Contains(body, "\nsentinel_frozen_unlabelled_pods 1\n") {
		t.Fatalf("GET /metrics = %d %q", rec.Code, body)
	}

	// Pod deletion drops it from the gauge.
	h.reconciler.forget("fe-signalloom-agents/agent-sir-lancelot")
	if n := h.reconciler.kernel.frozenUnlabelledCount(); n != 0 {
		t.Fatalf("gauge after forget = %d, want 0", n)
	}
}

// simulateKernel mirrors cgroup.freeze into cgroup.events the way the kernel
// settles a freeze or thaw, until the test ends.
func (h *kernelHarness) simulateKernel(t *testing.T) {
	t.Helper()
	done := make(chan struct{})
	stopped := make(chan struct{})
	t.Cleanup(func() { close(done); <-stopped })
	go func() {
		defer close(stopped)
		for {
			select {
			case <-done:
				return
			case <-time.After(200 * time.Microsecond):
			}
			b, err := os.ReadFile(filepath.Join(h.cgroup, "cgroup.freeze"))
			if err != nil {
				continue
			}
			_ = os.WriteFile(filepath.Join(h.cgroup, "cgroup.events"),
				[]byte("populated 1\nfrozen "+strings.TrimSpace(string(b))+"\n"), 0o644)
		}
	}()
}

// W6: a replacement frozen by the owner record before its sandbox joined a
// netns has its only PID in the node netns, so the veth lookup fails forever.
// Unstun used to look the veth up BEFORE thawing, so that pod could never be
// released. The release must never be blocked by the network layer.
func TestUnstunThawsEvenWhenVethCannotBeResolved(t *testing.T) {
	h := newKernelHarness(t, "populated 1\nfrozen 1\n")
	if err := os.WriteFile(filepath.Join(h.cgroup, "cgroup.freeze"), []byte("1"), 0o644); err != nil {
		t.Fatal(err)
	}
	h.simulateKernel(t)

	err := h.reconciler.reconcile(kernelTestPod(map[string]string{labelStunnedAI: "idle"}, nil))

	if b, _ := os.ReadFile(filepath.Join(h.cgroup, "cgroup.freeze")); strings.TrimSpace(string(b)) != "0" {
		t.Fatalf("pod left frozen (cgroup.freeze=%q) because the veth lookup failed; reconcile err = %v", b, err)
	}
	partial := h.events(t, "unstun_partial")
	if len(partial) != 1 || !strings.Contains(partial[0].Error, "permission denied") {
		t.Fatalf("unstun_partial events = %+v, want one carrying the veth error", partial)
	}
	if got := h.events(t, "unstun"); len(got) != 0 {
		t.Fatalf("full unstun reported although tc detach never ran: %+v", got)
	}
	if err == nil || !strings.Contains(err.Error(), "veth") {
		t.Fatalf("reconcile err = %v, want the veth error returned so the detach is retried", err)
	}
}
