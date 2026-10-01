// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package deploy

import (
	"fmt"
	"slices"
	"strings"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
)

// hostPathPolicy: the only host paths the sentinel may mount, and whether the
// mount must be read-only. Measured on kind-osramp 2026-10-01 — the probe
// attaches all four tracepoints with exactly these two.
//
// /sys/fs/bpf, /sys/kernel/btf and /lib/modules are deliberately ABSENT, not
// forgotten: nothing is pinned, and the probe is bpf2go-embedded so it needs
// no CO-RE mount. Adding one back must fail here rather than pass unnoticed.
var hostPathPolicy = map[string]bool{
	"/sys/fs/cgroup":    false, // cgroup.freeze writes
	"/sys/kernel/debug": true,  // tracepoint attach reads the tracepoint id from tracefs
}

// leastPrivilegeViolations returns one line per breach of the sentinel's
// least-privilege contract; empty means compliant.
func leastPrivilegeViolations(ds *appsv1.DaemonSet) []string {
	var out []string
	spec := ds.Spec.Template.Spec
	if len(spec.Containers) != 1 {
		return []string{fmt.Sprintf("containers: want 1, got %d", len(spec.Containers))}
	}
	if !spec.HostPID {
		out = append(out, "hostPID: must be true (host PIDs, /proc/<pid>/ns/net)")
	}
	if spec.HostIPC {
		out = append(out, "hostIPC: must be false (never needed)")
	}
	sc := spec.Containers[0].SecurityContext
	if sc == nil || sc.Capabilities == nil {
		return append(out, "securityContext.capabilities: missing")
	}
	// No sentinel may be privileged any more. The hardened profile was
	// measured loading the eBPF probe and freezing cgroups without it, so
	// privileged is now pure blast radius with nothing bought for it.
	if sc.Privileged != nil && *sc.Privileged {
		out = append(out, "privileged: the hardened profile works without it")
	}
	add := make([]string, 0, len(sc.Capabilities.Add))
	for _, c := range sc.Capabilities.Add {
		add = append(add, string(c))
	}
	slices.Sort(add)
	if got := strings.Join(add, ","); got != "BPF,NET_ADMIN,SYS_ADMIN,SYS_PTRACE" {
		out = append(out, "capabilities.add: got "+got+", want exactly BPF,NET_ADMIN,SYS_ADMIN,SYS_PTRACE")
	}
	if !slices.Contains(sc.Capabilities.Drop, "ALL") {
		out = append(out, "capabilities.drop: the sentinel must drop ALL")
	}
	if sc.ReadOnlyRootFilesystem == nil || !*sc.ReadOnlyRootFilesystem {
		out = append(out, "readOnlyRootFilesystem: must be true")
	}
	hostPaths := map[string]string{}
	for _, v := range spec.Volumes {
		if v.HostPath != nil {
			hostPaths[v.Name] = v.HostPath.Path
		}
	}
	for _, m := range spec.Containers[0].VolumeMounts {
		hp, ok := hostPaths[m.Name]
		if !ok {
			continue
		}
		mustRO, allowed := hostPathPolicy[hp]
		switch {
		case !allowed:
			out = append(out, "hostPath "+hp+": not in the sentinel mount allowlist")
		case mustRO && !m.ReadOnly:
			out = append(out, "hostPath "+hp+": must be mounted readOnly")
		}
	}
	return out
}

func TestCanonicalManifestIsLeastPrivilege(t *testing.T) {
	if v := leastPrivilegeViolations(loadDaemonSet(t, canonical)); len(v) > 0 {
		t.Errorf("%s:\n  %s", canonical, strings.Join(v, "\n  "))
	}
}

// Each mutation breaks one clause on the real manifest; the checker must name it.
func TestLeastPrivilegeCheckerCatchesEachMutation(t *testing.T) {
	sc := func(ds *appsv1.DaemonSet) *corev1.SecurityContext {
		return ds.Spec.Template.Spec.Containers[0].SecurityContext
	}
	yes := true
	no := false
	mutations := []struct {
		want   string
		mutate func(*appsv1.DaemonSet)
	}{
		{"capabilities.add", func(ds *appsv1.DaemonSet) {
			sc(ds).Capabilities.Add = append(sc(ds).Capabilities.Add, "NET_RAW")
		}},
		{"capabilities.add", func(ds *appsv1.DaemonSet) { sc(ds).Capabilities.Add = sc(ds).Capabilities.Add[1:] }},
		{"capabilities.drop", func(ds *appsv1.DaemonSet) { sc(ds).Capabilities.Drop = nil }},
		{"privileged", func(ds *appsv1.DaemonSet) { sc(ds).Privileged = &yes }},
		{"readOnlyRootFilesystem", func(ds *appsv1.DaemonSet) { sc(ds).ReadOnlyRootFilesystem = &no }},
		{"hostIPC", func(ds *appsv1.DaemonSet) { ds.Spec.Template.Spec.HostIPC = true }},
		{"hostPID", func(ds *appsv1.DaemonSet) { ds.Spec.Template.Spec.HostPID = false }},
		{"hostPath /: not in the sentinel mount allowlist", func(ds *appsv1.DaemonSet) {
			s := &ds.Spec.Template.Spec
			s.Volumes = append(s.Volumes, corev1.Volume{Name: "root", VolumeSource: corev1.VolumeSource{HostPath: &corev1.HostPathVolumeSource{Path: "/"}}})
			s.Containers[0].VolumeMounts = append(s.Containers[0].VolumeMounts, corev1.VolumeMount{Name: "root", MountPath: "/host", ReadOnly: true})
		}},
		{"hostPath /sys/fs/bpf: not in the sentinel mount allowlist", func(ds *appsv1.DaemonSet) {
			s := &ds.Spec.Template.Spec
			s.Volumes = append(s.Volumes, corev1.Volume{Name: "bpffs", VolumeSource: corev1.VolumeSource{HostPath: &corev1.HostPathVolumeSource{Path: "/sys/fs/bpf"}}})
			s.Containers[0].VolumeMounts = append(s.Containers[0].VolumeMounts, corev1.VolumeMount{Name: "bpffs", MountPath: "/sys/fs/bpf"})
		}},
		{"hostPath /sys/kernel/debug: must be mounted readOnly", func(ds *appsv1.DaemonSet) {
			for i, m := range ds.Spec.Template.Spec.Containers[0].VolumeMounts {
				if m.MountPath == "/sys/kernel/debug" {
					ds.Spec.Template.Spec.Containers[0].VolumeMounts[i].ReadOnly = false
				}
			}
		}},
	}
	for _, m := range mutations {
		ds := loadDaemonSet(t, canonical)
		m.mutate(ds)
		v := strings.Join(leastPrivilegeViolations(ds), "\n")
		if !strings.Contains(v, m.want) {
			t.Errorf("mutated for %q: violations = %q", m.want, v)
		}
	}
}
