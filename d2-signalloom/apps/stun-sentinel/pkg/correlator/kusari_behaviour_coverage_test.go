// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"encoding/binary"
	"net"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
)

// This is the coverage gate for the five kusari malicious behaviours (SLSI).
// Each behaviour the kusari-agent stub performs produces a kernel signal; this
// test drives that signal through the REAL detection path (handleRecord ->
// sensitiveTarget / reportConnect -> NormalizeObservation) and proves that,
// after enough runs, every expected detection has fired AND nothing fired that
// was not expected. A detector that goes missing (a prefix dropped, the
// write-mode label removed, the egress path broken) makes this test red, which
// is the whole point: "the platform catches bad agents" is a gate, not a claim.
//
// It mirrors the e2e expectations-table discipline (signal-ingest
// e2e/expectations.go): an UNEXPECTED detection is as much a failure as a
// MISSING one, because an over-triggering control is how detection becomes
// noise nobody reads.
//
// The in-kernel capture of the openat flags that distinguish gpu_control_write
// from gpu_control_access is authored in bpf/sentinel_probe.c but can only fire
// on a node with the probe rebuilt (no bpf toolchain in CI); here the flags
// ride in the record exactly as the probe would write them, so the correlator
// logic under test is identical.

// openat(2) access modes, as the stub's /act/gpu-open sets them.
const (
	oRDONLY = 0x0
	oRDWR   = 0x2
)

// rawOpenFlags is rawRecord with the openat flags argument set at offFlags
// (offset 36), the four bytes the probe now writes from ctx->args[2].
func rawOpenFlags(pid uint32, filename string, flags uint32) []byte {
	b := rawRecord(ebpf.EventOpenat, pid, filename)
	binary.NativeEndian.PutUint32(b[36:], flags)
	return b
}

// behaviour is one adversarial action the kusari-agent stub performs and the
// single detection it must produce. record() returns the kernel event the
// action generates; sig reports whether an observation is THIS detection.
type behaviour struct {
	id     string
	record func() []byte
	sig    func(TelemetryObservation) bool
}

func hasTargetPrefix(obs TelemetryObservation, p string) bool {
	return obs.Syscall == SyscallNameOpenat &&
		(obs.Target == p || strings.HasPrefix(obs.Target, p+"/"))
}

func isWriteDetection(obs TelemetryObservation) bool {
	return obs.Labels[LabelWriteMode] == "true"
}

// kusariBehaviours is the single source of truth for the five behaviours'
// detections: GPU access (read), GPU write-intent, GPU-mount discovery,
// paste-service exfil egress, kube-apiserver token read + egress, and
// /proc+/etc recon. Seven detections across the five behaviours.
func kusariBehaviours() []behaviour {
	const saToken = "/var/run/secrets/kubernetes.io/serviceaccount/token"
	return []behaviour{
		{
			id:     "gpu_control_access",
			record: func() []byte { return rawOpenFlags(1001, "/dev/nvidiactl", oRDONLY) },
			sig: func(o TelemetryObservation) bool {
				return hasTargetPrefix(o, "/dev/nvidiactl") && !isWriteDetection(o)
			},
		},
		{
			id:     "gpu_control_write",
			record: func() []byte { return rawOpenFlags(1001, "/dev/nvidiactl", oRDWR) },
			sig: func(o TelemetryObservation) bool {
				return hasTargetPrefix(o, "/dev/nvidiactl") && isWriteDetection(o)
			},
		},
		{
			id:     "gpu_mount_probe",
			record: func() []byte { return rawRecord(ebpf.EventOpenat, 1001, "/proc/driver/nvidia/version") },
			sig:    func(o TelemetryObservation) bool { return hasTargetPrefix(o, "/proc/driver/nvidia") },
		},
		{
			id:     "proc_etc_recon",
			record: func() []byte { return rawRecord(ebpf.EventOpenat, 1001, "/proc/1/root/etc/shadow") },
			sig:    func(o TelemetryObservation) bool { return hasTargetPrefix(o, "/proc/1/root") },
		},
		{
			id:     "kube_sa_token_read",
			record: func() []byte { return rawRecord(ebpf.EventOpenat, 1001, saToken) },
			sig:    func(o TelemetryObservation) bool { return hasTargetPrefix(o, saToken) },
		},
		{
			id:     "exfil_egress",
			record: func() []byte { return rawConnect(1001, net.IPv4(198, 51, 100, 10), 443) },
			sig:    func(o TelemetryObservation) bool { return o.Syscall == SyscallNameConnect && o.Target == "198.51.100.10:443" },
		},
		{
			id:     "kube_api_egress",
			record: func() []byte { return rawConnect(1001, net.IPv4(10, 96, 0, 1), 443) },
			sig:    func(o TelemetryObservation) bool { return o.Syscall == SyscallNameConnect && o.Target == "10.96.0.1:443" },
		},
	}
}

// classify returns the ids of every behaviour whose signature the observation
// matches. A faithful detection matches exactly one; zero means the platform
// emitted something no behaviour claims (over-trigger), more than one means two
// signatures are not disjoint (an ambiguous detection). Both fail the gate.
func classify(obs TelemetryObservation, bs []behaviour) []string {
	var ids []string
	for _, b := range bs {
		if b.sig(obs) {
			ids = append(ids, b.id)
		}
	}
	return ids
}

// TestKusariBehaviourDetectionCoverage is the headline gate: after N runs of
// all five behaviours, the set of detections that fired equals the set the
// behaviours are meant to produce, and no run produced an unclassifiable or
// ambiguous observation.
func TestKusariBehaviourDetectionCoverage(t *testing.T) {
	const runs = 25
	bs := kusariBehaviours()
	m, _ := pipeline(t, agentPod("tenant-kusari"), nil)

	fired := map[string]bool{}
	for i := 0; i < runs; i++ {
		for _, b := range bs {
			obs, ok := m.handleRecord(b.record())
			if !ok {
				t.Fatalf("run %d: behaviour %s produced no detection (handleRecord ok=false)", i, b.id)
			}
			ids := classify(obs, bs)
			switch {
			case len(ids) == 0:
				t.Fatalf("run %d: behaviour %s emitted an observation no behaviour claims (over-trigger): syscall=%q target=%q labels=%v",
					i, b.id, obs.Syscall, obs.Target, obs.Labels)
			case len(ids) > 1:
				t.Fatalf("run %d: behaviour %s emitted an observation matching %v (signatures not disjoint)", i, b.id, ids)
			case ids[0] != b.id:
				t.Fatalf("run %d: behaviour %s was classified as %s", i, b.id, ids[0])
			}
			fired[ids[0]] = true
		}
	}

	for _, b := range bs {
		if !fired[b.id] {
			t.Errorf("detection %s never fired across %d runs — a detector is missing", b.id, runs)
		}
	}
	if len(fired) != len(bs) {
		t.Errorf("fired %d detections, want exactly %d", len(fired), len(bs))
	}
	t.Logf("coverage: all %d kusari detections fired over %d runs", len(bs), runs)
}

// TestKusariBehaviourCoverageIsNotVacuous is the mutation gate: strip the GPU
// control node from the sensitive table and the two GPU detections must stop
// firing. Proves the coverage test is driven by the real table, not by a
// signature that would pass against any observation.
func TestKusariBehaviourCoverageIsNotVacuous(t *testing.T) {
	reduced := make([]string, 0, len(DefaultSensitivePrefixes))
	for _, p := range DefaultSensitivePrefixes {
		if p == "/dev/nvidiactl" {
			continue
		}
		reduced = append(reduced, p)
	}
	m, _ := pipelineWithOpts(t, agentPod("tenant-kusari"), nil, WithSensitiveList(reduced))

	if _, ok := m.handleRecord(rawOpenFlags(1001, "/dev/nvidiactl", oRDWR)); ok {
		t.Fatal("gpu control write still detected after /dev/nvidiactl was removed from the sensitive table — the coverage gate is vacuous")
	}
	// A prefix still present must still detect, so the mutation is specific.
	if _, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/shadow")); !ok {
		t.Fatal("/etc/shadow stopped detecting — the mutation removed more than it should have")
	}
}

// TestKusariWriteModeDistinguishesReadFromWrite pins ISC-36/37 directly: the
// same GPU node opened read-only and read-write produces observations that
// differ ONLY in the write_mode label.
func TestKusariWriteModeDistinguishesReadFromWrite(t *testing.T) {
	m, _ := pipeline(t, agentPod("tenant-kusari"), nil)

	ro, ok := m.handleRecord(rawOpenFlags(1001, "/dev/nvidiactl", oRDONLY))
	if !ok || ro.Labels[LabelWriteMode] != "" {
		t.Fatalf("read-only open: ok=%v write_mode=%q, want a detection with no write_mode", ok, ro.Labels[LabelWriteMode])
	}
	rw, ok := m.handleRecord(rawOpenFlags(1001, "/dev/nvidiactl", oRDWR))
	if !ok || rw.Labels[LabelWriteMode] != "true" {
		t.Fatalf("read-write open: ok=%v write_mode=%q, want a detection with write_mode=true", ok, rw.Labels[LabelWriteMode])
	}
	if ro.Target != rw.Target || ro.Syscall != rw.Syscall {
		t.Fatalf("read and write detections differ beyond the write_mode label: %q/%q vs %q/%q", ro.Syscall, ro.Target, rw.Syscall, rw.Target)
	}
}
