// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
	corev1 "k8s.io/api/core/v1"
)

// The sentinel records WHY it froze a pod (Step 5 stun record), so the
// freeze hook must receive the syscall and target the detection was about.
func TestHandleRecordHandsTheFreezeItsSyscallAndTarget(t *testing.T) {
	proc := t.TempDir()
	dir := filepath.Join(proc, "1001")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	cg := "0::/kubepods/burstable/pod" + pipelinePodUID + "/e3b0c44298fc\n"
	if err := os.WriteFile(filepath.Join(dir, "cgroup"), []byte(cg), 0o644); err != nil {
		t.Fatal(err)
	}
	var gotSyscall, gotTarget string
	fm := NewReasonedFreezeManager(func(_ *corev1.Pod, syscall, target string) error {
		gotSyscall, gotTarget = syscall, target
		return nil
	})
	inf := NewMockSharedIndexInformer()
	m := NewSentinelProbeManager(inf, "", fm, WithProcRoot(proc))
	inf.InjectPod(agentPod("tenant-kusari"))

	obs, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/passwd"))
	if !ok || obs.DirectReaction != ReactionCgroupFrozen {
		t.Fatalf("ok=%v obs=%+v, want a frozen observation", ok, obs)
	}
	if gotSyscall != SyscallNameOpenat || gotTarget != "/etc/passwd" {
		t.Fatalf("freeze hook got (%q, %q), want (%q, %q)", gotSyscall, gotTarget, SyscallNameOpenat, "/etc/passwd")
	}
}
