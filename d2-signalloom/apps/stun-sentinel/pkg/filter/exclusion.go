// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package filter decides which pods the sentinel must never interrogate or
// freeze.
//
// A cgroup freeze is indiscriminate: it halts whatever is in the cgroup. Aimed
// at kube-system it wedges the node; at spire it stops SVID issuance and so
// breaks the very revocation path containment relies on; at flux-system it
// stops GitOps reconciliation cluster-wide; at the sentinel itself it removes
// the only thing that could ever thaw anything. None of those is a
// recoverable mistake from inside the cluster, so the exclusion is enforced
// here, in the daemon, rather than trusted to every caller.
package filter

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	corev1 "k8s.io/api/core/v1"
)

// DefaultExcludedNamespaces are infrastructure namespaces the sentinel never
// touches. inf-signalloom is the sentinel's own operational namespace.
var DefaultExcludedNamespaces = []string{
	"kube-system",
	"spire",
	"flux-system",
	"cert-manager",
	"envoy-gateway-system",
	"inf-signalloom",
}

const (
	// SentinelNameLabel / SentinelName identify any stun-sentinel pod, on any
	// node. A sentinel must not freeze a peer sentinel either.
	SentinelNameLabel = "app.kubernetes.io/name"
	SentinelName      = "stun-sentinel"
)

// Reason says why a pod was excluded or refused.
type Reason string

const (
	ReasonNone               Reason = ""
	ReasonNilPod             Reason = "nil-pod"
	ReasonInfraNamespace     Reason = "infrastructure-namespace"
	ReasonSelfPod            Reason = "self-pod"
	ReasonSentinelPod        Reason = "sentinel-pod"
	ReasonSelfProcess        Reason = "self-process"
	ReasonSelfCgroup         Reason = "self-cgroup"
	ReasonNotRunning         Reason = "not-running"
	ReasonIncompleteIdentity Reason = "incomplete-pod-identity"
)

var (
	// ErrExcluded is returned for pods the sentinel must never freeze.
	ErrExcluded = errors.New("filter: pod is excluded from containment")
	// ErrNotRunning is returned for pods that are not in phase Running.
	// Freezing a ContainerCreating pod wedges the runtime's setup half-way.
	ErrNotRunning = errors.New("filter: pod is not Running")
)

// Decision is the outcome of an exclusion evaluation.
type Decision struct {
	Excluded bool
	Reason   Reason
	Detail   string
}

// Self identifies the running sentinel.
type Self struct {
	PodName   string
	Namespace string
	PodUID    string
	// PID is the sentinel's PID as seen in the host PID namespace (hostPID).
	PID int
	// CgroupPath is the sentinel's cgroup-v2 path relative to the hierarchy
	// root ("0::<path>" in /proc/self/cgroup). "/" or "" under a private
	// cgroup namespace, where only the PID check can identify the sentinel.
	CgroupPath string
}

// SelfFromEnv reads the downward-API identity (POD_NAME, POD_NAMESPACE,
// POD_UID) plus the process's own PID and cgroup.
func SelfFromEnv() Self {
	return Self{
		PodName:    os.Getenv("POD_NAME"),
		Namespace:  os.Getenv("POD_NAMESPACE"),
		PodUID:     os.Getenv("POD_UID"),
		PID:        os.Getpid(),
		CgroupPath: readOwnCgroup("/proc/self/cgroup"),
	}
}

func readOwnCgroup(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		if rest, ok := strings.CutPrefix(line, "0::"); ok {
			return strings.TrimSpace(rest)
		}
	}
	return ""
}

// Filter evaluates pods against the exclusion policy.
type Filter struct {
	namespaces map[string]struct{}
	self       Self
	audit      func(line string)
}

// Option configures a Filter.
type Option func(*Filter)

// WithExtraNamespaces adds namespaces to the default exclusion set. It can
// only widen the set: the defaults are not removable by configuration.
func WithExtraNamespaces(ns ...string) Option {
	return func(f *Filter) {
		for _, n := range ns {
			if n = strings.TrimSpace(n); n != "" {
				f.namespaces[n] = struct{}{}
			}
		}
	}
}

// WithAuditLog routes the explicit audit skip lines. Defaults to stderr.
func WithAuditLog(fn func(line string)) Option {
	return func(f *Filter) { f.audit = fn }
}

// New returns a Filter for the given sentinel identity.
func New(self Self, opts ...Option) *Filter {
	f := &Filter{
		namespaces: make(map[string]struct{}, len(DefaultExcludedNamespaces)),
		self:       self,
		audit:      func(line string) { fmt.Fprintln(os.Stderr, line) },
	}
	for _, n := range DefaultExcludedNamespaces {
		f.namespaces[n] = struct{}{}
	}
	for _, o := range opts {
		o(f)
	}
	return f
}

// ExcludedNamespaces returns the effective namespace set, sorted.
func (f *Filter) ExcludedNamespaces() []string {
	out := make([]string, 0, len(f.namespaces))
	for n := range f.namespaces {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// Evaluate applies the exclusion policy without logging.
func (f *Filter) Evaluate(pod *corev1.Pod) Decision {
	if pod == nil {
		return Decision{Excluded: true, Reason: ReasonNilPod, Detail: "no pod to evaluate; failing closed"}
	}
	if _, ok := f.namespaces[pod.Namespace]; ok {
		return Decision{Excluded: true, Reason: ReasonInfraNamespace, Detail: "namespace " + pod.Namespace}
	}
	if f.self.PodUID != "" && string(pod.UID) == f.self.PodUID {
		return Decision{Excluded: true, Reason: ReasonSelfPod, Detail: "uid matches sentinel POD_UID"}
	}
	if f.self.PodName != "" && pod.Name == f.self.PodName && pod.Namespace == f.self.Namespace {
		return Decision{Excluded: true, Reason: ReasonSelfPod, Detail: "name/namespace match sentinel"}
	}
	if pod.Labels[SentinelNameLabel] == SentinelName {
		return Decision{Excluded: true, Reason: ReasonSentinelPod, Detail: SentinelNameLabel + "=" + SentinelName}
	}
	if pod.UID == "" {
		return Decision{Excluded: true, Reason: ReasonIncompleteIdentity, Detail: "pod has no UID; failing closed"}
	}
	return Decision{}
}

// IsExcludedPod reports whether the sentinel must skip pod, writing an
// explicit audit line when it does.
func (f *Filter) IsExcludedPod(pod *corev1.Pod) bool {
	d := f.Evaluate(pod)
	if d.Excluded {
		f.auditSkip(pod, d)
	}
	return d.Excluded
}

// CheckFreezable is the full pre-freeze gate: exclusion first, then phase.
func (f *Filter) CheckFreezable(pod *corev1.Pod) error {
	if d := f.Evaluate(pod); d.Excluded {
		f.auditSkip(pod, d)
		return fmt.Errorf("%w: %s (%s)", ErrExcluded, d.Reason, d.Detail)
	}
	if pod.Status.Phase != corev1.PodRunning {
		d := Decision{Excluded: true, Reason: ReasonNotRunning, Detail: fmt.Sprintf("phase %q", pod.Status.Phase)}
		f.auditSkip(pod, d)
		return fmt.Errorf("%w: phase %q", ErrNotRunning, pod.Status.Phase)
	}
	return nil
}

// ContainsSelf reports whether a resolved target cgroup holds the sentinel
// itself: its own host PID among pids, or its own cgroup at or beneath
// targetCgroup (an absolute path under cgroupRoot). This catches a request
// that names the sentinel by a UID the downward API did not provide.
func (f *Filter) ContainsSelf(cgroupRoot, targetCgroup string, pids []int) Decision {
	if f.self.PID > 0 {
		for _, p := range pids {
			if p == f.self.PID {
				return Decision{Excluded: true, Reason: ReasonSelfProcess, Detail: fmt.Sprintf("target cgroup holds sentinel pid %d", p)}
			}
		}
	}
	own := strings.TrimSpace(f.self.CgroupPath)
	if own != "" && own != "/" && targetCgroup != "" {
		ownAbs := filepath.Clean(filepath.Join(cgroupRoot, own))
		target := filepath.Clean(targetCgroup)
		if ownAbs == target || strings.HasPrefix(ownAbs, target+string(filepath.Separator)) {
			return Decision{Excluded: true, Reason: ReasonSelfCgroup, Detail: "sentinel cgroup " + ownAbs + " is within target"}
		}
	}
	return Decision{}
}

// AuditSkip writes the audit line for a decision made outside Evaluate.
func (f *Filter) AuditSkip(pod *corev1.Pod, d Decision) { f.auditSkip(pod, d) }

func (f *Filter) auditSkip(pod *corev1.Pod, d Decision) {
	if f.audit == nil {
		return
	}
	ns, name, uid := "", "", ""
	if pod != nil {
		ns, name, uid = pod.Namespace, pod.Name, string(pod.UID)
	}
	f.audit(fmt.Sprintf("audit: stun-sentinel skip pod=%s/%s uid=%s reason=%s detail=%q", ns, name, uid, d.Reason, d.Detail))
}

var (
	defaultOnce   sync.Once
	defaultFilter *Filter
)

// Default returns the process-wide filter built from SelfFromEnv.
func Default() *Filter {
	defaultOnce.Do(func() { defaultFilter = New(SelfFromEnv()) })
	return defaultFilter
}

// IsExcludedPod applies the default filter. See Filter.IsExcludedPod.
func IsExcludedPod(pod *corev1.Pod) bool { return Default().IsExcludedPod(pod) }
