// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import "testing"

func TestRemoteStunRequesterAdapterCreatesRequest(t *testing.T) {
	store := NewRemoteStunStore(nil, nil)
	adapter := NewRemoteStunRequester(store)
	adapter.RequestRemoteStun(
		"c1",
		"ns1",
		"wl1",
		"landlock-denial: x",
		"signalloom-policy-engine",
	)

	record := store.Request("c1", "ns1", "wl1", "different", "different")
	if record.ID == "" {
		t.Fatal("adapter did not create a remote stun record")
	}
	if record.Reason != "landlock-denial: x" {
		t.Fatalf("reason = %q, want landlock-denial: x", record.Reason)
	}
	if record.State != RemoteStunRequested {
		t.Fatalf("state = %q, want %q", record.State, RemoteStunRequested)
	}
	if record.RequestedBy != "signalloom-policy-engine" {
		t.Fatalf("requested by = %q", record.RequestedBy)
	}
}

func TestRemoteStunRequesterAdapterNilStore(t *testing.T) {
	adapter := NewRemoteStunRequester(nil)
	adapter.RequestRemoteStun("c1", "ns1", "wl1", "landlock-denial: x", "caller")
}
