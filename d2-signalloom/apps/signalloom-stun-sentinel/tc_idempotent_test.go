// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"errors"
	"fmt"
	"strings"
	"testing"
)

// Live, 2026-10-03: every reconcile of a frozen pod failed
//
//	attach drop filter after freezing pod: tc replace Sentinel ingress filter
//	on lxc…: RTNETLINK answers: File exists
//
// every ~30 s (19 reconcile_failed). cls_matchall refuses any change to an
// existing filter with EEXIST, so `tc filter replace` is NOT idempotent for
// matchall: the first attach works and every later one fails.

// fakeTC models the kernel's tc state for one device, with matchall's EEXIST.
type fakeTC struct {
	clsact  bool
	filters map[string]string // direction -> "pref handle action"
	calls   []string
}

func newFakeTC() *fakeTC { return &fakeTC{filters: map[string]string{}} }

func (f *fakeTC) run(name string, args ...string) ([]byte, error) {
	call := strings.Join(append([]string{name}, args...), " ")
	f.calls = append(f.calls, call)
	arg := func(key string) string {
		for i := 0; i+1 < len(args); i++ {
			if args[i] == key {
				return args[i+1]
			}
		}
		return ""
	}
	dir := "ingress"
	if strings.Contains(call, " egress") {
		dir = "egress"
	}
	switch {
	case strings.HasPrefix(call, "tc qdisc replace "):
		f.clsact = true
		return nil, nil
	case strings.HasPrefix(call, "tc filter replace "):
		if !f.clsact {
			return []byte("Error: Parent Qdisc doesn't exists.\n"), errors.New("exit status 2")
		}
		if _, ok := f.filters[dir]; ok {
			return []byte("RTNETLINK answers: File exists\n"), errors.New("exit status 2")
		}
		f.filters[dir] = arg("pref") + " " + arg("handle") + " drop"
		return nil, nil
	case strings.HasPrefix(call, "tc filter del "):
		if _, ok := f.filters[dir]; !ok {
			return []byte("Error: Cannot find specified filter chain.\n"), errors.New("exit status 2")
		}
		delete(f.filters, dir)
		return nil, nil
	case strings.HasPrefix(call, "tc filter show "):
		v, ok := f.filters[dir]
		if !ok {
			return nil, nil
		}
		var pref, handle, action string
		fmt.Sscan(v, &pref, &handle, &action)
		var h uint64
		fmt.Sscan(handle, &h)
		return []byte(fmt.Sprintf("filter protocol all pref %s matchall chain 0 \n"+
			"filter protocol all pref %s matchall chain 0 handle 0x%x \n"+
			"  not_in_hw\n\taction order 1: gact action %s\n\t random type none pass val 0\n\t index 1 ref 1 bind 1\n\n",
			pref, pref, h, action)), nil
	}
	return nil, fmt.Errorf("unexpected tc call %q", call)
}

func (f *fakeTC) writes() int {
	n := 0
	for _, c := range f.calls {
		if !strings.HasPrefix(c, "tc filter show ") {
			n++
		}
	}
	return n
}

func TestAttachDropIsIdempotentAgainstMatchallEEXIST(t *testing.T) {
	k := newFakeTC()
	tc := newTCDropFilter()
	tc.run = k.run
	for i := 0; i < 3; i++ { // the stun, then two reconcile resyncs
		if err := tc.attachDrop("lxc-target"); err != nil {
			t.Fatalf("attach %d: %v", i, err)
		}
	}
	if k.filters["ingress"] != "49152 1 drop" || k.filters["egress"] != "49153 2 drop" {
		t.Fatalf("filters = %v", k.filters)
	}
}

// A resync of an already-contained pod changes nothing, so it must exec
// nothing that writes: the sentinel's own execs are what its execve burst
// detector sees.
func TestAttachDropOnAContainedPodOnlyReads(t *testing.T) {
	k := newFakeTC()
	tc := newTCDropFilter()
	tc.run = k.run
	if err := tc.attachDrop("lxc-target"); err != nil {
		t.Fatal(err)
	}
	before := k.writes()
	if err := tc.attachDrop("lxc-target"); err != nil {
		t.Fatal(err)
	}
	if got := k.writes() - before; got != 0 {
		t.Fatalf("a resync ran %d tc writes: %q", got, k.calls)
	}
}

func TestAttachDropRestoresAHalfMissingFilter(t *testing.T) {
	k := newFakeTC()
	tc := newTCDropFilter()
	tc.run = k.run
	if err := tc.attachDrop("lxc-target"); err != nil {
		t.Fatal(err)
	}
	delete(k.filters, "egress") // removed out from under the sentinel
	mark := len(k.calls)
	if err := tc.attachDrop("lxc-target"); err != nil {
		t.Fatal(err)
	}
	if k.filters["egress"] != "49153 2 drop" {
		t.Fatalf("egress drop not restored: %v", k.filters)
	}
	for _, c := range k.calls[mark:] {
		if strings.HasPrefix(c, "tc filter replace ") && strings.Contains(c, " ingress ") {
			t.Fatalf("rewrote the intact ingress drop: %q", k.calls[mark:])
		}
	}
}

func TestAttachDropWorksAgainAfterAnUnstun(t *testing.T) {
	k := newFakeTC()
	tc := newTCDropFilter()
	tc.run = k.run
	if err := tc.attachDrop("lxc-target"); err != nil {
		t.Fatal(err)
	}
	if err := tc.detachDrop("lxc-target"); err != nil {
		t.Fatal(err)
	}
	if len(k.filters) != 0 {
		t.Fatalf("detach left %v", k.filters)
	}
	if err := tc.attachDrop("lxc-target"); err != nil {
		t.Fatal(err)
	}
	if len(k.filters) != 2 {
		t.Fatalf("re-stun filters = %v", k.filters)
	}
}

// A filter at the Sentinel's pref that is not its drop is never claimed as
// containment: the attach must fail, not report the pod isolated.
func TestAttachDropRefusesAForeignFilterAtItsPref(t *testing.T) {
	for _, occupant := range []string{
		"49152 1 pass", // our pref and handle, not a drop
		"49152 5 drop", // a drop at our pref, someone else's handle
	} {
		k := newFakeTC()
		k.clsact = true
		k.filters["ingress"] = occupant
		tc := newTCDropFilter()
		tc.run = k.run
		err := tc.attachDrop("lxc-target")
		if err == nil || !strings.Contains(err.Error(), "File exists") {
			t.Errorf("%s: err = %v; want the occupied pref reported", occupant, err)
		}
	}
}

// Two reconciles race: this one read "absent", the other installed the drop,
// and this replace hits EEXIST. Ours is there, so the pod is contained.
func TestAttachDropAcceptsEEXISTWhenTheFilterIsOurs(t *testing.T) {
	k := newFakeTC()
	k.clsact = true
	k.filters["ingress"] = "49152 1 drop"
	stale := true
	tc := newTCDropFilter()
	tc.run = func(name string, args ...string) ([]byte, error) {
		if stale && strings.Join(args, " ") == "filter show dev lxc-target ingress" {
			stale = false
			k.calls = append(k.calls, "tc "+strings.Join(args, " "))
			return nil, nil
		}
		return k.run(name, args...)
	}
	if err := tc.attachDrop("lxc-target"); err != nil {
		t.Fatalf("lost race reported as failure: %v", err)
	}
	if k.filters["egress"] != "49153 2 drop" {
		t.Fatalf("filters = %v", k.filters)
	}
}
