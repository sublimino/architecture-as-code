// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package netlink

import (
	"context"
	"errors"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestResolveRejectsNonPositivePIDWithoutTouchingNamespaces(t *testing.T) {
	for _, pid := range []int{0, -1} {
		k := newFakeKernel()
		_, err := NewResolverWithOps(k.ops()).Resolve(context.Background(), pid)
		if err == nil || !strings.Contains(err.Error(), "invalid pid") {
			t.Errorf("pid %d: err = %v, want invalid pid", pid, err)
		}
		if len(k.opened) != 0 {
			t.Errorf("pid %d: opened %v before validating the pid", pid, k.opened)
		}
	}
}

func TestResolveStopsRetryingWhenContextIsCancelled(t *testing.T) {
	k := newFakeKernel()
	k.podMissingFor = 1 << 30
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r := withClock(NewResolverWithOps(k.ops()), &fakeClock{t: time.Unix(0, 0)})
	res, err := r.Resolve(ctx, 1)
	if !errors.Is(err, context.Canceled) || res.Attempts != 1 {
		t.Fatalf("err = %v attempts = %d, want context.Canceled after one attempt", err, res.Attempts)
	}
}

func TestResolveHostSideFailures(t *testing.T) {
	cases := []struct {
		name     string
		mutate   func(*fakeKernel)
		want     error
		attempts int // 1 = terminal, >1 = retried until the deadline
	}{
		{"pod veth without IFLA_LINK", func(k *fakeKernel) { k.podLinks["eth0"] = LinkInfo{Index: 2, Name: "eth0", Type: "veth"} }, ErrVethNotFound, 50},
		{"host peer index vanished", func(k *fakeKernel) { delete(k.hostLinks, 19) }, ErrVethNotFound, 50},
		{"host peer is not a veth", func(k *fakeKernel) { k.hostLinks[19] = LinkInfo{Index: 19, Name: "br0", Type: "bridge", PeerIndex: 2} }, ErrNotVeth, 1},
	}
	for _, c := range cases {
		k := newFakeKernel()
		c.mutate(k)
		r := withClock(NewResolverWithOps(k.ops()), &fakeClock{t: time.Unix(0, 0)})
		res, err := r.Resolve(context.Background(), 1)
		if !errors.Is(err, c.want) || res.Attempts != c.attempts {
			t.Errorf("%s: err = %v attempts = %d, want %v after %d", c.name, err, res.Attempts, c.want, c.attempts)
		}
	}
}

func TestResolveHostLookupErrorIsTerminal(t *testing.T) {
	k := newFakeKernel()
	ops := k.ops()
	ops.LinkByIndex = func(int) (LinkInfo, error) { return LinkInfo{}, syscall.EPERM }
	res, err := withClock(NewResolverWithOps(ops), &fakeClock{t: time.Unix(0, 0)}).Resolve(context.Background(), 1)
	if err == nil || errors.Is(err, ErrVethNotFound) || !errors.Is(err, syscall.EPERM) || res.Attempts != 1 {
		t.Fatalf("err = %v attempts = %d, want a terminal EPERM on the first attempt", err, res.Attempts)
	}
}
