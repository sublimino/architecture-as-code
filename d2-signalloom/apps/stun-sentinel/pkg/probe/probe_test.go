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
}
