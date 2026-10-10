// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"encoding/binary"
	"net"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
)

// rawConnect lays out a connect syscall_event_t: family at 30, dport at 32,
// daddr at 40 (pkg/ebpf offsets, pinned by _Static_assert in the probe).
func rawConnect(pid uint32, ip net.IP, port uint16) []byte {
	b := rawRecord(ebpf.EventConnect, pid, "")
	if v4 := ip.To4(); v4 != nil {
		binary.NativeEndian.PutUint16(b[30:], ebpf.AF_INET)
		copy(b[40:44], v4)
	} else {
		binary.NativeEndian.PutUint16(b[30:], ebpf.AF_INET6)
		copy(b[40:56], ip.To16())
	}
	binary.NativeEndian.PutUint16(b[32:], port)
	return b
}

func TestConnectFromAnAgentPodIsReportedAtWarnWithTheRemoteEndpointAndNoFreeze(t *testing.T) {
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	obs, ok := m.handleRecord(rawConnect(1001, net.IPv4(140, 82, 121, 4), 443))
	if !ok {
		t.Fatalf("a connect from a watched pod must be reported; stats=%+v", m.Stats())
	}
	if obs.Syscall != SyscallNameConnect || obs.Target != "140.82.121.4:443" || obs.Severity != SeverityWarn {
		t.Fatalf("obs = %+v", obs)
	}
	if obs.DirectReaction != ReactionNone || *calls != 0 {
		t.Fatalf("a connect never freezes: reaction=%s freezes=%d", obs.DirectReaction, *calls)
	}
	if obs.PodName != "agent-1" || obs.Opener == nil || obs.Opener.Comm != "agent" {
		t.Fatalf("obs = %+v opener=%+v", obs, obs.Opener)
	}
	if s := m.Stats(); s.Matched != 1 || s.NotSensitive != 0 {
		t.Fatalf("stats = %+v", s)
	}
}

func TestConnectIPv6EndpointIsBracketed(t *testing.T) {
	m, _ := pipeline(t, agentPod("tenant-kusari"), nil)
	obs, ok := m.handleRecord(rawConnect(1001, net.ParseIP("2606:4700::6810:84e5"), 8443))
	if !ok || obs.Target != "[2606:4700::6810:84e5]:8443" || obs.Severity != SeverityWarn {
		t.Fatalf("ok=%v obs=%+v", ok, obs)
	}
}

func TestConnectWithoutAnOwningPodIsDropped(t *testing.T) {
	m, _ := pipeline(t, agentPod("tenant-kusari"), nil)
	if _, ok := m.handleRecord(rawConnect(4040, net.IPv4(10, 0, 0, 1), 80)); ok {
		t.Fatal("a connect from an unknown pid has no pod to report")
	}
	if s := m.Stats(); s.NoPod != 1 {
		t.Fatalf("stats = %+v", s)
	}
}

func TestSensitiveOpenStaysCriticalAndFreezes(t *testing.T) {
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	obs, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/shadow"))
	if !ok || obs.Severity != SeverityCritical || *calls != 1 {
		t.Fatalf("ok=%v severity=%s freezes=%d", ok, obs.Severity, *calls)
	}
}

func TestNormalizeConnectUsesTheEndpointNotTheFilename(t *testing.T) {
	m := NewSentinelProbeManager(nil, "", nil)
	raw := SyscallEvent{Type: SyscallTypeConnect, Family: ebpf.AF_INET, DestPort: 53, DestAddr: net.IPv4(10, 43, 0, 10)}
	copy(raw.Filename[:], "/should/not/appear")
	obs := m.NormalizeObservation(raw, nil)
	if obs.Target != "10.43.0.10:53" || obs.Severity != SeverityWarn || obs.Syscall != SyscallNameConnect {
		t.Fatalf("obs = %+v", obs)
	}
	if (SyscallEvent{Type: SyscallTypeOpenat, DestAddr: net.IPv4(1, 2, 3, 4)}).RemoteEndpoint() != "" {
		t.Fatal("only a connect has a remote endpoint")
	}
}
