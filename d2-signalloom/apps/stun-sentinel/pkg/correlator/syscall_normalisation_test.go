// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestAllFourSyscallsNormalisation(t *testing.T) {
	tenants, err := ParseTenantMap("tenant-kusari=kusari")
	if err != nil {
		t.Fatal(err)
	}
	mgr := NewSentinelProbeManager(nil, unreachableIngestURL, nil, WithTenantMap(tenants))

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "agent-kusari-77",
			Namespace: "tenant-kusari",
			UID:       "11111111-2222-3333-4444-555555555555",
			Labels: map[string]string{
				"signalloom.ai/agent": "true",
				"tenant":              "kusari",
			},
		},
		Spec: corev1.PodSpec{
			ServiceAccountName: "kusari-sa",
		},
	}

	testCases := []struct {
		name         string
		rawEvent     SyscallEvent
		wantSyscall  string
		wantTarget   string
		wantSeverity string
	}{
		{
			name: "openat sensitive path",
			rawEvent: func() SyscallEvent {
				var fn [256]byte
				copy(fn[:], "/etc/passwd\x00")
				return SyscallEvent{
					PID:      1001,
					TGID:     1001,
					Type:     SyscallTypeOpenat,
					Filename: fn,
				}
			}(),
			wantSyscall:  SyscallNameOpenat,
			wantTarget:   "/etc/passwd",
			wantSeverity: SeverityCritical,
		},
		{
			name: "openat2 direct invocation",
			rawEvent: func() SyscallEvent {
				var fn [256]byte
				copy(fn[:], "/etc/shadow\x00")
				return SyscallEvent{
					PID:      1002,
					TGID:     1002,
					Type:     SyscallTypeOpenat2,
					Filename: fn,
				}
			}(),
			wantSyscall:  SyscallNameOpenat2,
			wantTarget:   "/etc/shadow",
			wantSeverity: SeverityCritical,
		},
		{
			name: "execve binary invocation",
			rawEvent: func() SyscallEvent {
				var fn [256]byte
				copy(fn[:], "/bin/bash\x00")
				return SyscallEvent{
					PID:      1003,
					TGID:     1003,
					Type:     SyscallTypeExecve,
					Filename: fn,
				}
			}(),
			wantSyscall:  SyscallNameExecve,
			wantTarget:   "/bin/bash",
			wantSeverity: SeverityCritical,
		},
		{
			name: "connect IPv4 outbound",
			rawEvent: SyscallEvent{
				PID:      1004,
				TGID:     1004,
				Type:     SyscallTypeConnect,
				Family:   ebpf.AF_INET,
				DestPort: 53,
				DestAddr: net.IPv4(10, 96, 0, 10),
			},
			wantSyscall:  SyscallNameConnect,
			wantTarget:   "10.96.0.10:53",
			wantSeverity: SeverityWarn,
		},
		{
			name: "connect IPv6 outbound",
			rawEvent: SyscallEvent{
				PID:      1005,
				TGID:     1005,
				Type:     SyscallTypeConnect,
				Family:   ebpf.AF_INET6,
				DestPort: 8443,
				DestAddr: net.ParseIP("2001:db8::1"),
			},
			wantSyscall:  SyscallNameConnect,
			wantTarget:   "[2001:db8::1]:8443",
			wantSeverity: SeverityWarn,
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			obs := mgr.NormalizeObservation(tc.rawEvent, pod)

			if obs.Syscall != tc.wantSyscall {
				t.Errorf("Syscall = %q, want %q", obs.Syscall, tc.wantSyscall)
			}
			if obs.Target != tc.wantTarget {
				t.Errorf("Target = %q, want %q", obs.Target, tc.wantTarget)
			}
			if obs.Severity != tc.wantSeverity {
				t.Errorf("Severity = %q, want %q", obs.Severity, tc.wantSeverity)
			}
			if obs.PodName != "agent-kusari-77" {
				t.Errorf("PodName = %q, want agent-kusari-77", obs.PodName)
			}
			if obs.Namespace != "tenant-kusari" {
				t.Errorf("Namespace = %q, want tenant-kusari", obs.Namespace)
			}
			if obs.ActorID != "kusari-sa" {
				t.Errorf("ActorID = %q, want kusari-sa", obs.ActorID)
			}
			if obs.TenantID != "kusari" {
				t.Errorf("TenantID = %q, want kusari", obs.TenantID)
			}

			// Validate toIngest wire schema
			ingest := obs.toIngest()
			if ingest.Layer != "endpoint_host" {
				t.Errorf("toIngest().Layer = %q, want endpoint_host", ingest.Layer)
			}
			if ingest.Fidelity != "strong" {
				t.Errorf("toIngest().Fidelity = %q, want strong", ingest.Fidelity)
			}
			if ingest.Source != "stun-sentinel" {
				t.Errorf("toIngest().Source = %q, want stun-sentinel", ingest.Source)
			}
			if ingest.Confidence != 0.95 {
				t.Errorf("toIngest().Confidence = %f, want 0.95", ingest.Confidence)
			}
			if ingest.Labels["syscall"] != tc.wantSyscall {
				t.Errorf("Labels[syscall] = %q, want %q", ingest.Labels["syscall"], tc.wantSyscall)
			}
			if ingest.Labels["target"] != tc.wantTarget {
				t.Errorf("Labels[target] = %q, want %q", ingest.Labels["target"], tc.wantTarget)
			}
			if ingest.Labels["tenant_id"] != "kusari" {
				t.Errorf("Labels[tenant_id] = %q, want kusari", ingest.Labels["tenant_id"])
			}
			if !strings.HasPrefix(ingest.RawEvidenceRef, fmt.Sprintf("ebpf://%s/", tc.wantSyscall)) {
				t.Errorf("RawEvidenceRef = %q, want prefix ebpf://%s/", ingest.RawEvidenceRef, tc.wantSyscall)
			}
		})
	}
}

func TestDropAnomalyObservationEmission(t *testing.T) {
	mgr := NewSentinelProbeManager(nil, unreachableIngestURL, nil)

	// Zero drops is a no-op
	mgr.ReportDropAnomaly(0)
	select {
	case obs := <-mgr.queue:
		t.Fatalf("expected no observation on 0 drops, got: %+v", obs)
	default:
	}

	// Non-zero drops emits an anomaly observation
	mgr.ReportDropAnomaly(25)
	select {
	case obs := <-mgr.queue:
		if obs.Syscall != SyscallNameRingbufDrops {
			t.Errorf("obs.Syscall = %q, want %q", obs.Syscall, SyscallNameRingbufDrops)
		}
		if obs.Severity != SeverityCritical {
			t.Errorf("obs.Severity = %q, want %q", obs.Severity, SeverityCritical)
		}
		if obs.Target != "kernel_ringbuf_drops=25" {
			t.Errorf("obs.Target = %q, want kernel_ringbuf_drops=25", obs.Target)
		}
		if obs.Labels["anomaly_type"] != "ringbuf_drops" {
			t.Errorf("obs.Labels[anomaly_type] = %q, want ringbuf_drops", obs.Labels["anomaly_type"])
		}
		if obs.Labels["drop_count"] != "25" {
			t.Errorf("obs.Labels[drop_count] = %q, want 25", obs.Labels["drop_count"])
		}

		ingest := obs.toIngest()
		if ingest.Labels["syscall"] != SyscallNameRingbufDrops {
			t.Errorf("ingest.Labels[syscall] = %q, want %q", ingest.Labels["syscall"], SyscallNameRingbufDrops)
		}
	default:
		t.Fatal("expected drop anomaly observation in queue, but queue was empty")
	}
}

func TestPostingToIngestWithWardenKey(t *testing.T) {
	var receivedToken string

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/observations" {
			http.NotFound(w, r)
			return
		}
		receivedToken = r.Header.Get("Authorization")

		if receivedToken != "Bearer warden-named-sensor-key" {
			w.WriteHeader(http.StatusUnauthorized)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "unauthorized"})
			return
		}
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "accepted"})
	}))
	defer server.Close()

	// Case 1: Valid warden key
	mgr := NewSentinelProbeManager(nil, server.URL, nil, WithBearerToken("warden-named-sensor-key"))
	obs := TelemetryObservation{
		Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
		Syscall:   SyscallNameOpenat,
		Target:    "/etc/passwd",
		Severity:  SeverityCritical,
		PodName:   "agent-kusari",
		Namespace: "tenant-kusari",
	}

	err := mgr.dispatchObservation(obs)
	if err != nil {
		t.Fatalf("dispatchObservation with valid key failed: %v", err)
	}
	if receivedToken != "Bearer warden-named-sensor-key" {
		t.Errorf("received Authorization header = %q, want Bearer warden-named-sensor-key", receivedToken)
	}

	// Case 2: Wrong key is rejected with 401
	mgrWrongKey := NewSentinelProbeManager(nil, server.URL, nil, WithBearerToken("wrong-forged-key"))
	err = mgrWrongKey.dispatchObservation(obs)
	if err == nil {
		t.Fatal("dispatchObservation with wrong key expected error, got nil")
	}
	if !strings.Contains(err.Error(), "401") {
		t.Errorf("expected 401 in error message, got: %v", err)
	}

	// Case 3: Missing token returns ErrIngestTokenMissing
	mgrNoToken := NewSentinelProbeManager(nil, server.URL, nil)
	err = mgrNoToken.dispatchObservation(obs)
	if err != ErrIngestTokenMissing {
		t.Errorf("dispatchObservation with no token: got %v, want ErrIngestTokenMissing", err)
	}
}
