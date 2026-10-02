// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

//go:build frostdb

package store

import (
	"context"
	"testing"
	"time"
)

// TestSentinelTargetHomeDirectoryUserIsRedactedBeforeTheSegment pins the decision taken for the
// sentinel's `target` label: the key is admitted, but a path is a file name chosen by whoever owns
// the file system, and a path under a home directory names an account. A segment is immutable and
// signed, so the user component is removed at the Append chokepoint, never at a caller.
func TestSentinelTargetHomeDirectoryUserIsRedactedBeforeTheSegment(t *testing.T) {
	cases := map[string]string{
		"/home/alice/.ssh/id_rsa":       "/home/[REDACTED_USER]/.ssh/id_rsa",
		"/home/alice":                   "/home/[REDACTED_USER]",
		"/Users/bob/.aws/credentials":   "/Users/[REDACTED_USER]/.aws/credentials",
		"/var/home/carol/.kube/config":  "/var/home/[REDACTED_USER]/.kube/config",
		"/host/home/dave/x/home/eve/y":  "/host/home/[REDACTED_USER]/x/home/[REDACTED_USER]/y",
		"/etc/passwd":                   "/etc/passwd",
		"/root/.ssh/authorized_keys":    "/root/.ssh/authorized_keys",
		"/run/secrets/kubernetes.io/sa": "/run/secrets/kubernetes.io/sa",
		"/homework/notes":               "/homework/notes",
	}

	batch := readSentinelGolden(t)
	for in, want := range cases {
		t.Run(in, func(t *testing.T) {
			s, err := NewFrostDBStoreWithBucket(t.TempDir())
			if err != nil {
				t.Fatalf("NewFrostDBStoreWithBucket: %v", err)
			}
			defer s.Close()

			o := batch[0]
			o.Labels = map[string]string{}
			for k, v := range batch[0].Labels {
				o.Labels[k] = v
			}
			o.Labels["target"] = in
			if err := s.Append(context.Background(), append(batch[:0:0], o)); err != nil {
				t.Fatalf("Append: %v", err)
			}
			got, err := s.QueryRange(context.Background(), Query{
				After: o.Timestamp.Add(-time.Second), Before: o.Timestamp.Add(time.Second),
			})
			if err != nil || len(got) != 1 {
				t.Fatalf("QueryRange: %d observations, err %v", len(got), err)
			}
			if got[0].Labels["target"] != want {
				t.Fatalf("target %q stored as %q, want %q", in, got[0].Labels["target"], want)
			}
		})
	}
}
