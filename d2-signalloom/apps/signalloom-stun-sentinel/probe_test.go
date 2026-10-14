package main

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
)

func TestDetectProbesExtractsAllProbeTypes(t *testing.T) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "cardvault", Namespace: "fe-signalloom-agents", UID: "uid-123"},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{
					Name: "agent",
					Ports: []corev1.ContainerPort{
						{Name: "http", ContainerPort: 8080},
					},
					LivenessProbe: &corev1.Probe{
						ProbeHandler: corev1.ProbeHandler{
							HTTPGet: &corev1.HTTPGetAction{
								Path: "/healthz",
								Port: intstr.FromString("http"),
							},
						},
						PeriodSeconds:    10,
						TimeoutSeconds:   2,
						FailureThreshold: 3,
					},
					ReadinessProbe: &corev1.Probe{
						ProbeHandler: corev1.ProbeHandler{
							HTTPGet: &corev1.HTTPGetAction{
								Path: "/readyz",
								Port: intstr.FromInt32(8080),
							},
						},
					},
					StartupProbe: &corev1.Probe{
						ProbeHandler: corev1.ProbeHandler{
							TCPSocket: &corev1.TCPSocketAction{
								Port: intstr.FromInt32(8080),
							},
						},
					},
				},
				{
					Name: "sidecar",
					LivenessProbe: &corev1.Probe{
						ProbeHandler: corev1.ProbeHandler{
							Exec: &corev1.ExecAction{
								Command: []string{"/bin/sh", "-c", "echo ok"},
							},
						},
					},
				},
			},
		},
	}

	p := newProbePreserver()
	probes := p.detectProbes(pod)

	if len(probes) != 4 {
		t.Fatalf("detectProbes() returned %d probes; want 4", len(probes))
	}

	// Probe 1: Liveness HTTPGet on agent (resolved named port http -> 8080)
	p1 := probes[0]
	if p1.ContainerName != "agent" || p1.Purpose != ProbePurposeLiveness || p1.Type != ProbeTypeHTTPGet || p1.Port != 8080 || p1.Path != "/healthz" {
		t.Errorf("p1 mismatch: %+v", p1)
	}

	// Probe 2: Readiness HTTPGet on agent
	p2 := probes[1]
	if p2.ContainerName != "agent" || p2.Purpose != ProbePurposeReadiness || p2.Type != ProbeTypeHTTPGet || p2.Port != 8080 || p2.Path != "/readyz" {
		t.Errorf("p2 mismatch: %+v", p2)
	}

	// Probe 3: Startup TCPSocket on agent
	p3 := probes[2]
	if p3.ContainerName != "agent" || p3.Purpose != ProbePurposeStartup || p3.Type != ProbeTypeTCPSocket || p3.Port != 8080 {
		t.Errorf("p3 mismatch: %+v", p3)
	}

	// Probe 4: Liveness Exec on sidecar
	p4 := probes[3]
	if p4.ContainerName != "sidecar" || p4.Purpose != ProbePurposeLiveness || p4.Type != ProbeTypeExec || len(p4.Command) != 3 {
		t.Errorf("p4 mismatch: %+v", p4)
	}
}

func TestSyntheticProbeHandlerReturns200(t *testing.T) {
	handler := syntheticProbeHandler("agent-cardvault", "fe-signalloom-agents")
	req := httptest.NewRequest("GET", "/healthz", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d; want 200", rec.Code)
	}
	if rec.Header().Get("X-SignalLoom-Preserved") != "true" {
		t.Errorf("X-SignalLoom-Preserved header missing")
	}

	var body map[string]interface{}
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode json body: %v", err)
	}
	if body["status"] != "frozen" || body["preserved"] != true || body["pod"] != "agent-cardvault" {
		t.Errorf("unexpected body payload: %+v", body)
	}
}

func TestSyntheticProbeHandlerHEADSuppressesBody(t *testing.T) {
	handler := syntheticProbeHandler("agent-cardvault", "fe-signalloom-agents")
	req := httptest.NewRequest(http.MethodHead, "/healthz", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d; want 200", rec.Code)
	}
	if rec.Header().Get("X-SignalLoom-Preserved") != "true" {
		t.Errorf("X-SignalLoom-Preserved header missing")
	}
	if rec.Header().Get("Content-Type") != "application/json" {
		t.Errorf("Content-Type = %q; want application/json", rec.Header().Get("Content-Type"))
	}
	if rec.Body.Len() != 0 {
		t.Errorf("expected empty body for HEAD request, got %q", rec.Body.String())
	}
}

func TestSyntheticProbeHandlerMethodNotAllowed(t *testing.T) {
	handler := syntheticProbeHandler("agent-cardvault", "fe-signalloom-agents")
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch, "TRACE"} {
		req := httptest.NewRequest(method, "/healthz", nil)
		rec := httptest.NewRecorder()

		handler.ServeHTTP(rec, req)

		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("method %s status = %d; want 405", method, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
			t.Errorf("method %s Allow = %q; want GET, HEAD, OPTIONS", method, allow)
		}
		if ctype := rec.Header().Get("Content-Type"); ctype != "application/json" {
			t.Errorf("method %s Content-Type = %q; want application/json", method, ctype)
		}
	}

	// Verify HEAD request on non-existent path suppresses response body (RFC 9110 Section 6.4.1)
	mux := http.NewServeMux()
	mux.Handle("/healthz", handler)
	wrappedMux := headBodySuppressingMiddleware(mux)

	head404Req := httptest.NewRequest(http.MethodHead, "/nonexistent", nil)
	head404Rec := httptest.NewRecorder()
	wrappedMux.ServeHTTP(head404Rec, head404Req)
	if head404Rec.Code != http.StatusNotFound {
		t.Errorf("HEAD /nonexistent status = %d, want 404", head404Rec.Code)
	}
	if head404Rec.Body.Len() != 0 {
		t.Errorf("HEAD /nonexistent got body %q, want empty", head404Rec.Body.String())
	}

	// Verify HEAD request on route returning 405 suppresses response body
	postOnlyHandler := headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_, _ = w.Write([]byte(`{"error":"Method Not Allowed"}`))
			return
		}
	}))
	head405Req := httptest.NewRequest(http.MethodHead, "/submit", nil)
	head405Rec := httptest.NewRecorder()
	postOnlyHandler.ServeHTTP(head405Rec, head405Req)
	if head405Rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("HEAD /submit status = %d, want 405", head405Rec.Code)
	}
	if head405Rec.Body.Len() != 0 {
		t.Errorf("HEAD /submit got body %q, want empty", head405Rec.Body.String())
	}
}

func TestSyntheticProbeHandlerOPTIONS(t *testing.T) {
	handler := syntheticProbeHandler("agent-cardvault", "fe-signalloom-agents")
	req := httptest.NewRequest(http.MethodOptions, "/healthz", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("OPTIONS /healthz status = %d, want 204", rec.Code)
	}
	if allow := rec.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
		t.Errorf("OPTIONS /healthz Allow = %q, want 'GET, HEAD, OPTIONS'", allow)
	}
	if rec.Body.Len() != 0 {
		t.Errorf("OPTIONS /healthz expected 0 body bytes, got %d", rec.Body.Len())
	}
}

func TestProbePreserverLifecycleAndIdempotency(t *testing.T) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "agent-test", Namespace: "fe-signalloom-agents", UID: "uid-abc"},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{
					Name: "agent",
					LivenessProbe: &corev1.Probe{
						ProbeHandler: corev1.ProbeHandler{
							HTTPGet: &corev1.HTTPGetAction{Path: "/healthz", Port: intstr.FromInt32(8080)},
						},
					},
				},
			},
		},
	}

	p := newProbePreserver()

	if p.isPreserved("uid-abc") {
		t.Fatal("expected not preserved initially")
	}

	if err := p.preserve(pod, "/cgroup/pod", "veth-test"); err != nil {
		t.Fatalf("preserve failed: %v", err)
	}

	if !p.isPreserved("uid-abc") {
		t.Fatal("expected preserved after preserve()")
	}

	state, ok := p.getPreserved("uid-abc")
	if !ok || state.PodName != "agent-test" || len(state.Probes) != 1 {
		t.Fatalf("getPreserved() = %+v, %v", state, ok)
	}

	// Idempotency: second preserve is no-op
	if err := p.preserve(pod, "/cgroup/pod", "veth-test"); err != nil {
		t.Fatalf("second preserve failed: %v", err)
	}
	if p.countPreserved() != 1 {
		t.Fatalf("countPreserved() = %d; want 1", p.countPreserved())
	}

	// Release
	if err := p.release(pod, "/cgroup/pod", "veth-test"); err != nil {
		t.Fatalf("release failed: %v", err)
	}
	if p.isPreserved("uid-abc") {
		t.Fatal("expected not preserved after release()")
	}

	// Idempotency: second release is safe no-op
	if err := p.release(pod, "/cgroup/pod", "veth-test"); err != nil {
		t.Fatalf("second release failed: %v", err)
	}
}

func TestStunReconcilerPreservesProbesOnStunAndReleasesOnUnstun(t *testing.T) {
	dir := t.TempDir()
	cgroupPath := filepath.Join(dir, "kubelet.slice", "kubelet-kubepods.slice", "kubelet-kubepods-burstable-podtest_uid.slice")
	mockFreezableCgroup(t, cgroupPath, false)
	// The fake kernel answers before it is asked, so no goroutine races the
	// freezer's 50ms confirmation deadline. The previous fake mirrored
	// cgroup.freeze into cgroup.events from a goroutine on a 2ms sleep, and
	// under host load that goroutine was not scheduled inside the deadline:
	// the test failed with ErrFreezeDeadline for a scheduling reason. Freeze
	// confirmation timing is pkg/cgroup's subject (freezer_test.go there); this
	// test's subject is what the reconciler does around it. cgroup.freeze is
	// still asserted after each reconcile, so a reconciler that skips the
	// write still fails here.
	kernelSettles := func(frozen bool) {
		t.Helper()
		ev := "populated 1\nfrozen 0\n"
		if frozen {
			ev = "populated 1\nfrozen 1\n"
		}
		if err := replaceFile(filepath.Join(t.TempDir(), "cgroup.events"), filepath.Join(cgroupPath, "cgroup.events"), ev); err != nil {
			t.Fatal(err)
		}
	}

	var tcCalls []string
	tc := newTCDropFilter()
	tc.run = func(name string, args ...string) ([]byte, error) {
		tcCalls = append(tcCalls, args[0]+" "+args[1])
		return nil, nil
	}
	tc.pidForCgroup = func(string) (int, error) { return 100, nil }
	tc.peerIndex = func(int, string) (int, error) { return 42, nil }
	tc.interfaces = func() ([]net.Interface, error) {
		return []net.Interface{{Name: "veth42", Index: 42}}, nil
	}

	freezer := newCgroupFreezer(dir, false, "token", "token")
	probes := newProbePreserver()
	reconciler := newStunReconciler(freezer, tc, probes)

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "agent-cardvault",
			Namespace: "fe-signalloom-agents",
			UID:       "test-uid",
			Labels:    map[string]string{labelStunned: stunnedValue},
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{
					Name: "cardvault",
					LivenessProbe: &corev1.Probe{
						ProbeHandler: corev1.ProbeHandler{
							HTTPGet: &corev1.HTTPGetAction{Path: "/healthz", Port: intstr.FromInt32(8080)},
						},
					},
				},
			},
		},
	}

	// Reconcile stun
	kernelSettles(true)
	if err := reconciler.reconcile(pod); err != nil {
		t.Fatalf("stun reconcile: %v", err)
	}

	// Verify frozen
	freezeData, _ := os.ReadFile(filepath.Join(cgroupPath, "cgroup.freeze"))
	if string(freezeData) != "1" {
		t.Fatalf("cgroup.freeze = %q; want 1", string(freezeData))
	}

	// Verify probe preserved
	if !probes.isPreserved("test-uid") {
		t.Fatal("probe was not preserved during stun")
	}

	// Reconcile un-stun
	pod.Labels[labelStunned] = "idle"
	kernelSettles(false)
	if err := reconciler.reconcile(pod); err != nil {
		t.Fatalf("unstun reconcile: %v", err)
	}

	// Verify unfrozen
	freezeData, _ = os.ReadFile(filepath.Join(cgroupPath, "cgroup.freeze"))
	if string(freezeData) != "0" {
		t.Fatalf("cgroup.freeze = %q; want 0", string(freezeData))
	}

	// Verify probe released
	if probes.isPreserved("test-uid") {
		t.Fatal("probe was not released during un-stun")
	}
}
