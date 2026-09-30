// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package deploy holds the stun-sentinel DaemonSet manifests. This test pins
// the SLDC-P1-3 securityContext contract so a manifest edit that drops a
// capability, a host namespace or a mount fails in `go test`, before it can
// fail on a node at the moment containment is needed.
package deploy

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/yaml"
)

var requiredCaps = []corev1.Capability{"SYS_PTRACE", "BPF", "NET_ADMIN", "SYS_ADMIN"}

// Every manifest that deploys a stun-sentinel DaemonSet, relative to here.
var manifests = []string{
	"daemonset.yaml",
	"../base/daemonset.yaml",
	"../../../deploy/stun-sentinel-daemonset.yaml",
	"../../../infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml",
}

// The hardened in-sentinel manifests (this app's own) carry the full P1-3
// contract: host network, privileged, and the complete mount set.
var hardened = map[string]bool{"daemonset.yaml": true, "../base/daemonset.yaml": true}

func loadDaemonSet(t *testing.T, path string) *appsv1.DaemonSet {
	t.Helper()
	raw, err := os.ReadFile(filepath.Clean(path))
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	for _, doc := range bytes.Split(raw, []byte("\n---")) {
		var meta struct{ Kind string }
		if err := yaml.Unmarshal(doc, &meta); err != nil || meta.Kind != "DaemonSet" {
			continue
		}
		ds := &appsv1.DaemonSet{}
		if err := yaml.UnmarshalStrict(doc, ds); err != nil {
			t.Fatalf("%s: decode DaemonSet: %v", path, err)
		}
		return ds
	}
	t.Fatalf("%s: no DaemonSet document", path)
	return nil
}

func sentinelContainer(t *testing.T, path string, ds *appsv1.DaemonSet) corev1.Container {
	t.Helper()
	cs := ds.Spec.Template.Spec.Containers
	if len(cs) != 1 {
		t.Fatalf("%s: want exactly one container, got %d", path, len(cs))
	}
	return cs[0]
}

func TestSecurityContextCapabilities(t *testing.T) {
	for _, path := range manifests {
		t.Run(path, func(t *testing.T) {
			ds := loadDaemonSet(t, path)
			// PF-6: the canonical name; signalloom-stun-sentinel breaks tests.
			if ds.Name != "stun-sentinel" {
				t.Errorf("DaemonSet name = %q, want stun-sentinel", ds.Name)
			}
			if !ds.Spec.Template.Spec.HostPID {
				t.Error("hostPID must be true: host PIDs and /proc/<pid>/ns/net")
			}
			c := sentinelContainer(t, path, ds)
			sc := c.SecurityContext
			if sc == nil || sc.Capabilities == nil {
				t.Fatal("securityContext.capabilities missing")
			}
			have := map[corev1.Capability]bool{}
			for _, cap := range sc.Capabilities.Add {
				have[cap] = true
			}
			for _, want := range requiredCaps {
				if !have[want] {
					t.Errorf("securityContext.capabilities.add lacks %s", want)
				}
			}
		})
	}
}

func TestHardenedDaemonSetContract(t *testing.T) {
	for path := range hardened {
		t.Run(path, func(t *testing.T) {
			ds := loadDaemonSet(t, path)
			spec := ds.Spec.Template.Spec
			if !spec.HostNetwork {
				t.Error("hostNetwork must be true: tc/netlink run in the host netns")
			}
			if spec.DNSPolicy != corev1.DNSClusterFirstWithHostNet {
				t.Errorf("dnsPolicy = %q, want ClusterFirstWithHostNet under hostNetwork", spec.DNSPolicy)
			}
			c := sentinelContainer(t, path, ds)
			if c.SecurityContext.Privileged == nil || !*c.SecurityContext.Privileged {
				t.Error("privileged must be true for cgroup-v2 writes")
			}

			hostPaths := map[string]string{}
			for _, v := range spec.Volumes {
				if v.HostPath != nil {
					hostPaths[v.Name] = v.HostPath.Path
				}
			}
			type want struct {
				host     string
				readOnly bool
			}
			wants := map[string]want{
				"/sys/fs/cgroup":  {"/sys/fs/cgroup", false},
				"/lib/modules":    {"/lib/modules", true},
				"/sys/kernel/btf": {"/sys/kernel/btf", true},
				"/host/proc":      {"/proc", true},
			}
			seen := map[string]bool{}
			for _, m := range c.VolumeMounts {
				w, ok := wants[m.MountPath]
				if !ok {
					continue
				}
				seen[m.MountPath] = true
				if hostPaths[m.Name] != w.host {
					t.Errorf("%s mounts hostPath %q, want %q", m.MountPath, hostPaths[m.Name], w.host)
				}
				if m.ReadOnly != w.readOnly {
					t.Errorf("%s readOnly = %v, want %v", m.MountPath, m.ReadOnly, w.readOnly)
				}
			}
			for mp := range wants {
				if !seen[mp] {
					t.Errorf("missing volume mount %s", mp)
				}
			}

			env := map[string]string{}
			for _, e := range c.Env {
				if e.ValueFrom != nil && e.ValueFrom.FieldRef != nil {
					env[e.Name] = e.ValueFrom.FieldRef.FieldPath
				}
			}
			for name, field := range map[string]string{
				"POD_NAME": "metadata.name", "POD_NAMESPACE": "metadata.namespace",
				"POD_UID": "metadata.uid", "POD_IP": "status.podIP",
			} {
				if env[name] != field {
					t.Errorf("env %s fieldRef = %q, want %q (self-pod exclusion identity)", name, env[name], field)
				}
			}
			listen := ""
			for _, a := range c.Args {
				if strings.HasPrefix(a, "--listen-addr=") {
					listen = a
				}
			}
			if listen != "--listen-addr=$(POD_IP):8080" {
				t.Errorf("listen arg = %q: under hostNetwork bind the pod IP, never 0.0.0.0", listen)
			}
		})
	}
}

// deploy/daemonset.yaml and base/daemonset.yaml must not drift apart.
func TestDeployMatchesBase(t *testing.T) {
	a, b := loadDaemonSet(t, "daemonset.yaml"), loadDaemonSet(t, "../base/daemonset.yaml")
	if !reflect.DeepEqual(a, b) {
		t.Fatal("deploy/daemonset.yaml and base/daemonset.yaml have drifted")
	}
}
