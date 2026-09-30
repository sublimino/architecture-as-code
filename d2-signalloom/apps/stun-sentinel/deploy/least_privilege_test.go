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

// privilegedAllowed lists the manifests whose binary writes other containers'
// cgroup.freeze and so needs privileged: true. The agent-swarm manifest runs
// the legacy controller unprivileged and must stay that way.
var privilegedAllowed = map[string]bool{
	"daemonset.yaml":                               true,
	"../base/daemonset.yaml":                       true,
	"../../../deploy/stun-sentinel-daemonset.yaml": true,
}

// hostPathPolicy: the only host paths a sentinel may mount, and whether the
// mount must be read-only.
var hostPathPolicy = map[string]bool{
	"/sys/fs/cgroup":  false, // cgroup.freeze writes
	"/sys/fs/bpf":     false, // pinned tc programs
	"/proc":           true,
	"/lib/modules":    true,
	"/sys/kernel/btf": true,
}

// leastPrivilegeViolations returns one line per breach of the sentinel's
// least-privilege contract; empty means compliant.
func leastPrivilegeViolations(ds *appsv1.DaemonSet, mayBePrivileged bool) []string {
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
	privileged := sc.Privileged != nil && *sc.Privileged
	if privileged && !mayBePrivileged {
		out = append(out, "privileged: not required by this manifest's binary")
	}
	add := make([]string, 0, len(sc.Capabilities.Add))
	for _, c := range sc.Capabilities.Add {
		add = append(add, string(c))
	}
	slices.Sort(add)
	if got := strings.Join(add, ","); got != "BPF,NET_ADMIN,SYS_ADMIN,SYS_PTRACE" {
		out = append(out, "capabilities.add: got "+got+", want exactly BPF,NET_ADMIN,SYS_ADMIN,SYS_PTRACE")
	}
	if !privileged && !slices.Contains(sc.Capabilities.Drop, "ALL") {
		out = append(out, "capabilities.drop: an unprivileged sentinel must drop ALL")
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

func TestSentinelManifestsAreLeastPrivilege(t *testing.T) {
	for _, path := range manifests {
		if v := leastPrivilegeViolations(loadDaemonSet(t, path), privilegedAllowed[path]); len(v) > 0 {
			t.Errorf("%s:\n  %s", path, strings.Join(v, "\n  "))
		}
	}
}

// Each mutation breaks one clause on a real manifest; the checker must name it.
func TestLeastPrivilegeCheckerCatchesEachMutation(t *testing.T) {
	sc := func(ds *appsv1.DaemonSet) *corev1.SecurityContext {
		return ds.Spec.Template.Spec.Containers[0].SecurityContext
	}
	yes := true
	no := false
	mutations := []struct {
		path, want string
		mutate     func(*appsv1.DaemonSet)
	}{
		{"daemonset.yaml", "capabilities.add", func(ds *appsv1.DaemonSet) {
			sc(ds).Capabilities.Add = append(sc(ds).Capabilities.Add, "NET_RAW")
		}},
		{"daemonset.yaml", "capabilities.add", func(ds *appsv1.DaemonSet) { sc(ds).Capabilities.Add = sc(ds).Capabilities.Add[1:] }},
		{"daemonset.yaml", "readOnlyRootFilesystem", func(ds *appsv1.DaemonSet) { sc(ds).ReadOnlyRootFilesystem = &no }},
		{"daemonset.yaml", "hostIPC", func(ds *appsv1.DaemonSet) { ds.Spec.Template.Spec.HostIPC = true }},
		{"daemonset.yaml", "hostPID", func(ds *appsv1.DaemonSet) { ds.Spec.Template.Spec.HostPID = false }},
		{"daemonset.yaml", "hostPath /: not in the sentinel mount allowlist", func(ds *appsv1.DaemonSet) {
			s := &ds.Spec.Template.Spec
			s.Volumes = append(s.Volumes, corev1.Volume{Name: "root", VolumeSource: corev1.VolumeSource{HostPath: &corev1.HostPathVolumeSource{Path: "/"}}})
			s.Containers[0].VolumeMounts = append(s.Containers[0].VolumeMounts, corev1.VolumeMount{Name: "root", MountPath: "/host", ReadOnly: true})
		}},
		{"daemonset.yaml", "hostPath /proc: must be mounted readOnly", func(ds *appsv1.DaemonSet) {
			for i, m := range ds.Spec.Template.Spec.Containers[0].VolumeMounts {
				if m.MountPath == "/host/proc" {
					ds.Spec.Template.Spec.Containers[0].VolumeMounts[i].ReadOnly = false
				}
			}
		}},
		{"../../../infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml", "privileged", func(ds *appsv1.DaemonSet) { sc(ds).Privileged = &yes }},
		{"../../../infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml", "capabilities.drop", func(ds *appsv1.DaemonSet) { sc(ds).Capabilities.Drop = nil }},
	}
	for _, m := range mutations {
		ds := loadDaemonSet(t, m.path)
		m.mutate(ds)
		v := strings.Join(leastPrivilegeViolations(ds, privilegedAllowed[m.path]), "\n")
		if !strings.Contains(v, m.want) {
			t.Errorf("%s mutated for %q: violations = %q", m.path, m.want, v)
		}
	}
}
