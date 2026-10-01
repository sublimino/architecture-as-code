// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package deploy once held one of four competing stun-sentinel DaemonSets.
// There is now exactly one, at
// infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml, and this test
// pins its contract so a manifest edit that drops a capability, a host
// namespace, the debugfs mount or the ingest URL fails in `go test` before it
// can fail on a node at the moment containment is needed.
//
// It also pins the consolidation itself: TestRetiredManifestsStayRetired fails
// if any of the three retired paths grows a DaemonSet back, which is the only
// thing stopping the duplicates reappearing.
package deploy

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/yaml"
)

var requiredCaps = []corev1.Capability{"SYS_PTRACE", "BPF", "NET_ADMIN", "SYS_ADMIN"}

// canonical is THE sentinel DaemonSet. Everything else is an overlay of it.
const canonical = "../../../infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml"

// retired are the three paths that used to declare a competing sentinel
// DaemonSet: two are now comment-only tombstones naming the canonical
// manifest, and ../base/daemonset.yaml is deleted outright (its directory
// kustomization now renders the canonical base instead).
var retired = []string{
	"daemonset.yaml",
	"../base/daemonset.yaml",
	"../../../deploy/stun-sentinel-daemonset.yaml",
}

// findDaemonSet returns the first DaemonSet document in a multi-doc manifest,
// or nil when the file declares none. A missing file also yields nil: deleting
// the manifest is the strongest form of retiring it.
func findDaemonSet(t *testing.T, path string) *appsv1.DaemonSet {
	t.Helper()
	raw, err := os.ReadFile(filepath.Clean(path))
	if os.IsNotExist(err) {
		return nil
	}
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
	return nil
}

func loadDaemonSet(t *testing.T, path string) *appsv1.DaemonSet {
	t.Helper()
	ds := findDaemonSet(t, path)
	if ds == nil {
		t.Fatalf("%s: no DaemonSet document", path)
	}
	return ds
}

func sentinelContainer(t *testing.T, path string, ds *appsv1.DaemonSet) corev1.Container {
	t.Helper()
	cs := ds.Spec.Template.Spec.Containers
	if len(cs) != 1 {
		t.Fatalf("%s: want exactly one container, got %d", path, len(cs))
	}
	return cs[0]
}

// The consolidation is only real while the retired paths stay empty. A
// DaemonSet reappearing at any of them is a second source of truth.
func TestRetiredManifestsStayRetired(t *testing.T) {
	for _, path := range retired {
		t.Run(path, func(t *testing.T) {
			if ds := findDaemonSet(t, path); ds != nil {
				t.Errorf("a DaemonSet has reappeared here; the only sentinel manifest is %s", canonical)
			}
		})
	}
}

func TestCanonicalSecurityContextCapabilities(t *testing.T) {
	ds := loadDaemonSet(t, canonical)
	// PF-6: the canonical name; signalloom-stun-sentinel breaks tests.
	if ds.Name != "stun-sentinel" {
		t.Errorf("DaemonSet name = %q, want stun-sentinel", ds.Name)
	}
	if !ds.Spec.Template.Spec.HostPID {
		t.Error("hostPID must be true: host PIDs and /proc/<pid>/ns/net")
	}
	c := sentinelContainer(t, canonical, ds)
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
}

// The hardened profile measured working on kind-osramp (2026-10-01): not
// privileged, read-only root, four capabilities, and only two host mounts.
func TestCanonicalDaemonSetContract(t *testing.T) {
	ds := loadDaemonSet(t, canonical)
	spec := ds.Spec.Template.Spec
	if !spec.HostNetwork {
		t.Error("hostNetwork must be true: tc/netlink run in the host netns")
	}
	// Without this, Kubernetes silently downgrades ClusterFirst to Default for
	// a hostNetwork pod: the node's resolv.conf has no cluster DNS, so the
	// ingest Service name does not resolve at all.
	if spec.DNSPolicy != corev1.DNSClusterFirstWithHostNet {
		t.Errorf("dnsPolicy = %q, want ClusterFirstWithHostNet under hostNetwork", spec.DNSPolicy)
	}
	c := sentinelContainer(t, canonical, ds)
	if c.SecurityContext.Privileged == nil || *c.SecurityContext.Privileged {
		t.Error("privileged must be false: the hardened profile was measured loading the probe without it")
	}
	if c.SecurityContext.ReadOnlyRootFilesystem == nil || !*c.SecurityContext.ReadOnlyRootFilesystem {
		t.Error("readOnlyRootFilesystem must be true")
	}
}

// The mount set is exactly two, and that is the whole point: debugfs is
// required (tracepoint attach reads the tracepoint id from tracefs), bpffs and
// the BTF mount are NOT (no pinning; the probe is bpf2go-embedded).
func TestCanonicalHostMounts(t *testing.T) {
	ds := loadDaemonSet(t, canonical)
	spec := ds.Spec.Template.Spec
	c := sentinelContainer(t, canonical, ds)

	hostPaths := map[string]string{}
	for _, v := range spec.Volumes {
		if v.HostPath != nil {
			hostPaths[v.Name] = v.HostPath.Path
		}
	}
	wants := map[string]mountWant{
		"/host-cgroup":      {"/sys/fs/cgroup", false},
		"/sys/kernel/debug": {"/sys/kernel/debug", true},
	}
	seen := map[string]bool{}
	for _, m := range c.VolumeMounts {
		w, ok := wants[m.MountPath]
		if !ok {
			t.Errorf("unexpected host mount %s (hostPath %q): the measured profile needs only %v",
				m.MountPath, hostPaths[m.Name], keysOf(wants))
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
	// Named explicitly so a speculative re-add fails by name, not by count.
	for _, forbidden := range []string{"/sys/fs/bpf", "/sys/kernel/btf", "/lib/modules"} {
		for _, hp := range hostPaths {
			if hp == forbidden {
				t.Errorf("hostPath %s is mounted but is not needed: no pinning, bpf2go-embedded probe, no CO-RE mount", forbidden)
			}
		}
	}
}

// mountWant is the expected hostPath and access mode behind a mountPath.
type mountWant struct {
	host     string
	readOnly bool
}

func keysOf(m map[string]mountWant) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// The binary reads SIGNAL_INGEST_URL (signalloom-stun-sentinel/main.go:351)
// and falls back to the short name http://signal-ingest:8082, which cannot
// resolve from this namespace. The base must therefore supply it, and from a
// ConfigMap so each cluster can carry its own value.
func TestCanonicalIngestURLComesFromConfigMap(t *testing.T) {
	ds := loadDaemonSet(t, canonical)
	c := sentinelContainer(t, canonical, ds)
	for _, e := range c.Env {
		if e.Name != "SIGNAL_INGEST_URL" {
			continue
		}
		ref := e.ValueFrom
		if ref == nil || ref.ConfigMapKeyRef == nil {
			t.Fatal("SIGNAL_INGEST_URL must come from a configMapKeyRef so an overlay can set it per cluster")
		}
		if ref.ConfigMapKeyRef.Optional != nil && *ref.ConfigMapKeyRef.Optional {
			t.Error("SIGNAL_INGEST_URL configMapKeyRef must not be optional: a missing ConfigMap would silently fall back to the unresolvable short name")
		}
		if ref.ConfigMapKeyRef.Key != "SIGNAL_INGEST_URL" {
			t.Errorf("configMapKeyRef.key = %q, want SIGNAL_INGEST_URL", ref.ConfigMapKeyRef.Key)
		}
		return
	}
	t.Fatal("SIGNAL_INGEST_URL is not set: the binary would fall back to http://signal-ingest:8082, which does not resolve from fe-signalloom-agents")
}

// capability-audit.yaml is the SLDC-P1-PRE specification, not a deployable.
// Its whole value is being true, so it must agree with the manifest it governs
// on the three things it exists to state: privileged, the capability set, and
// the host mount set. Before consolidation it disagreed on all three.
func TestCapabilityAuditSpecMatchesCanonical(t *testing.T) {
	const spec = "capability-audit.yaml"
	specDS, canonDS := loadDaemonSet(t, spec), loadDaemonSet(t, canonical)
	specC, canonC := sentinelContainer(t, spec, specDS), sentinelContainer(t, canonical, canonDS)

	privileged := func(c corev1.Container) bool {
		return c.SecurityContext != nil && c.SecurityContext.Privileged != nil && *c.SecurityContext.Privileged
	}
	if privileged(specC) != privileged(canonC) {
		t.Errorf("privileged: spec says %v, manifest says %v", privileged(specC), privileged(canonC))
	}
	caps := func(c corev1.Container) string {
		add := make([]string, 0, 4)
		for _, cap := range c.SecurityContext.Capabilities.Add {
			add = append(add, string(cap))
		}
		slices.Sort(add)
		return strings.Join(add, ",")
	}
	if caps(specC) != caps(canonC) {
		t.Errorf("capabilities.add: spec has %q, manifest has %q", caps(specC), caps(canonC))
	}
	mounts := func(ds *appsv1.DaemonSet, c corev1.Container) string {
		hostPaths := map[string]string{}
		for _, v := range ds.Spec.Template.Spec.Volumes {
			if v.HostPath != nil {
				hostPaths[v.Name] = v.HostPath.Path
			}
		}
		out := make([]string, 0, len(c.VolumeMounts))
		for _, m := range c.VolumeMounts {
			if hp, ok := hostPaths[m.Name]; ok {
				out = append(out, fmt.Sprintf("%s=%s:ro=%v", m.MountPath, hp, m.ReadOnly))
			}
		}
		slices.Sort(out)
		return strings.Join(out, " ")
	}
	if mounts(specDS, specC) != mounts(canonDS, canonC) {
		t.Errorf("host mounts:\n  spec     %s\n  manifest %s", mounts(specDS, specC), mounts(canonDS, canonC))
	}
}

// A remote cluster pulls the image; a kind cluster retags it in an overlay.
// Neither works if the base pins :latest or forbids pulling.
func TestCanonicalImageIsPullableAndPinned(t *testing.T) {
	ds := loadDaemonSet(t, canonical)
	c := sentinelContainer(t, canonical, ds)
	if c.ImagePullPolicy == corev1.PullNever {
		t.Error("imagePullPolicy: Never makes the base unusable on any cluster without a local image load")
	}
	name, tag, found := strings.Cut(c.Image, ":")
	if !found {
		t.Fatalf("image %q carries no tag", c.Image)
	}
	if tag == "latest" {
		t.Errorf("image %q pins :latest; a rollout then depends on when the node last pulled", c.Image)
	}
	if !strings.Contains(name, "/") {
		t.Errorf("image %q has no registry or repository path, so a remote cluster resolves it to docker.io/library", c.Image)
	}
}
