// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package probe

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
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
								Command: []string{"check.sh"},
							},
						},
					},
				},
			},
		},
	}

	preserver := NewProbePreserver()
	probes := preserver.DetectProbes(pod)

	if len(probes) != 4 {
		t.Fatalf("DetectProbes returned %d probes, want 4", len(probes))
	}

	var foundHTTP, foundTCP, foundExec bool
	for _, p := range probes {
		switch p.Type {
		case ProbeTypeHTTPGet:
			if p.Port == 8080 && p.ContainerName == "agent" {
				foundHTTP = true
			}
		case ProbeTypeTCPSocket:
			if p.Port == 8080 && p.ContainerName == "agent" {
				foundTCP = true
			}
		case ProbeTypeExec:
			if len(p.Command) > 0 && p.Command[0] == "check.sh" && p.ContainerName == "sidecar" {
				foundExec = true
			}
		}
	}

	if !foundHTTP {
		t.Errorf("did not extract HTTPGet probe correctly")
	}
	if !foundTCP {
		t.Errorf("did not extract TCPSocket probe correctly")
	}
	if !foundExec {
		t.Errorf("did not extract Exec probe correctly")
	}
}

func TestPreserveAndReleaseLifecycle(t *testing.T) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "agent-1", Namespace: "fe-signalloom-agents", UID: "uid-abc"},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{
					Name: "main",
					LivenessProbe: &corev1.Probe{
						ProbeHandler: corev1.ProbeHandler{
							HTTPGet: &corev1.HTTPGetAction{Path: "/healthz", Port: intstr.FromInt32(8080)},
						},
					},
				},
			},
		},
	}

	p := NewProbePreserver()

	if p.IsPreserved("uid-abc") {
		t.Fatal("pod should not be preserved initially")
	}

	if err := p.Preserve(pod, "/sys/fs/cgroup/test", "veth123"); err != nil {
		t.Fatalf("Preserve failed: %v", err)
	}

	if !p.IsPreserved("uid-abc") {
		t.Fatal("pod should be preserved after Preserve call")
	}
	if p.CountPreserved() != 1 {
		t.Fatalf("CountPreserved = %d, want 1", p.CountPreserved())
	}

	state, ok := p.GetPreserved("uid-abc")
	if !ok || state.PodName != "agent-1" || state.HostVeth != "veth123" {
		t.Fatalf("GetPreserved returned unexpected state: %+v, ok=%v", state, ok)
	}

	// Re-preserving is idempotent
	if err := p.Preserve(pod, "/sys/fs/cgroup/test", "veth123"); err != nil {
		t.Fatalf("idempotent Preserve failed: %v", err)
	}

	if err := p.Release(pod, "/sys/fs/cgroup/test", "veth123"); err != nil {
		t.Fatalf("Release failed: %v", err)
	}

	if p.IsPreserved("uid-abc") {
		t.Fatal("pod should not be preserved after Release")
	}
	if p.CountPreserved() != 0 {
		t.Fatalf("CountPreserved = %d, want 0", p.CountPreserved())
	}
}

func TestSyntheticProbeHandlerReturns200WithHeaders(t *testing.T) {
	handler := SyntheticProbeHandler("test-pod", "fe-signalloom-agents")
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if val := rec.Header().Get("X-SignalLoom-Preserved"); val != "true" {
		t.Errorf("X-SignalLoom-Preserved = %q, want 'true'", val)
	}

	var body map[string]interface{}
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode JSON: %v", err)
	}
	if body["status"] != "frozen" || body["pod"] != "test-pod" {
		t.Errorf("unexpected body: %+v", body)
	}

	// Verify HEAD request suppresses response body
	headReq := httptest.NewRequest(http.MethodHead, "/healthz", nil)
	headRec := httptest.NewRecorder()
	handler.ServeHTTP(headRec, headReq)
	if headRec.Code != http.StatusOK {
		t.Fatalf("HEAD status = %d, want 200", headRec.Code)
	}
	if val := headRec.Header().Get("X-SignalLoom-Preserved"); val != "true" {
		t.Errorf("HEAD X-SignalLoom-Preserved = %q, want 'true'", val)
	}
	if headRec.Body.Len() != 0 {
		t.Errorf("HEAD got body %q, want empty", headRec.Body.String())
	}

	// Verify unsupported methods return 405 Method Not Allowed with Allow header
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch, "TRACE"} {
		mReq := httptest.NewRequest(method, "/healthz", nil)
		mRec := httptest.NewRecorder()
		handler.ServeHTTP(mRec, mReq)
		if mRec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s /healthz got status %d, want 405", method, mRec.Code)
		}
		if allow := mRec.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
			t.Errorf("%s Allow header = %q, want 'GET, HEAD, OPTIONS'", method, allow)
		}
		if ctype := mRec.Header().Get("Content-Type"); ctype != "application/json" {
			t.Errorf("%s Content-Type = %q, want 'application/json'", method, ctype)
		}
	}

	// Verify OPTIONS request returns 204 No Content with Allow header and empty body
	optsReq := httptest.NewRequest(http.MethodOptions, "/healthz", nil)
	optsRec := httptest.NewRecorder()
	handler.ServeHTTP(optsRec, optsReq)
	if optsRec.Code != http.StatusNoContent {
		t.Errorf("OPTIONS /healthz got status %d, want 204", optsRec.Code)
	}
	if allow := optsRec.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
		t.Errorf("OPTIONS /healthz Allow header = %q, want 'GET, HEAD, OPTIONS'", allow)
	}
	if optsRec.Body.Len() != 0 {
		t.Errorf("OPTIONS /healthz got body %q, want empty", optsRec.Body.String())
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
