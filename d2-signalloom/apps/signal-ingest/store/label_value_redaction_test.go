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

// The sentinel's description is "<syscall> <target> by <ns>/<pod>", so the same account name the
// target label loses would otherwise ride into the segment through the one free-text column.
func TestSentinelDescriptionHomeDirectoryUserIsRedactedBeforeTheSegment(t *testing.T) {
	s, err := NewFrostDBStoreWithBucket(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	o := readSentinelGolden(t)[0]
	o.Description = "sys_enter_openat /home/alice/.ssh/id_rsa by fe-signalloom-agents/agent-kusari-7d9f"
	if err := s.Append(context.Background(), append(readSentinelGolden(t)[:0:0], o)); err != nil {
		t.Fatal(err)
	}
	got, err := s.QueryRange(context.Background(), Query{After: o.Timestamp.Add(-time.Second), Before: o.Timestamp.Add(time.Second)})
	if err != nil || len(got) != 1 {
		t.Fatalf("QueryRange: %d, %v", len(got), err)
	}
	if want := "sys_enter_openat /home/[REDACTED_USER]/.ssh/id_rsa by fe-signalloom-agents/agent-kusari-7d9f"; got[0].Description != want {
		t.Fatalf("description stored as %q, want %q", got[0].Description, want)
	}
}

func TestHomeDirectoryRedactionInFreeTextStopsAtWhitespace(t *testing.T) {
	if got := redactHomeDirectoryUserInText("opened /home/alice by ns/pod"); got != "opened /home/[REDACTED_USER] by ns/pod" {
		t.Fatalf("got %q", got)
	}
}
