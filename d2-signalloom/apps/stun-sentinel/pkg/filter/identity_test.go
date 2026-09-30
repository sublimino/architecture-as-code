// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package filter

import (
	"errors"
	"testing"

	corev1 "k8s.io/api/core/v1"
)

// A pod with no namespace or no UID cannot be checked against the namespace
// policy or the self-UID guard, and the freezer resolves cgroups by UID; such
// a record must fail closed rather than be treated as an ordinary tenant pod.
func TestIncompletePodIdentityFailsClosed(t *testing.T) {
	f := New(testSelf, WithAuditLog(func(string) {}))
	for name, p := range map[string]*corev1.Pod{
		"empty-namespace": pod("", "agent", "0b0c3a1e-0000-4000-8000-000000000001", corev1.PodRunning, nil),
		"empty-uid":       pod("tenant-kusari", "agent", "", corev1.PodRunning, nil),
	} {
		d := f.Evaluate(p)
		if !d.Excluded || d.Reason != ReasonIncompleteIdentity {
			t.Errorf("%s: decision = %+v, want excluded as %q", name, d, ReasonIncompleteIdentity)
		}
		if err := f.CheckFreezable(p); !errors.Is(err, ErrExcluded) {
			t.Errorf("%s: CheckFreezable = %v, want ErrExcluded", name, err)
		}
	}
}

// Extra-namespace configuration can only add exact names: blanks and a
// literal "*" neither remove a default nor widen into a match-all.
func TestExtraNamespaceConfigIsLiteral(t *testing.T) {
	f := New(testSelf, WithExtraNamespaces("", " ", "*"), WithAuditLog(func(string) {}))
	if d := f.Evaluate(pod("kube-system", "x", "u1", corev1.PodRunning, nil)); !d.Excluded {
		t.Fatal("default kube-system exclusion lost")
	}
	if d := f.Evaluate(pod("tenant-kusari", "x", "u2", corev1.PodRunning, nil)); d.Excluded {
		t.Fatalf("\"*\" acted as a wildcard: %+v", d)
	}
}
