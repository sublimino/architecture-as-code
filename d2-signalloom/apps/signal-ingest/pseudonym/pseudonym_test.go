// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package pseudonym

import (
	"testing"
)

func TestPseudonymVector(t *testing.T) {
	root := []byte("12345678901234567890123456789012")
	ring, err := NewKeyRing(root, 1)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	p, err := ring.Pseudonym("tenant-test", "my-secret-token")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	t.Logf("Go pseudonym: %s", p)
	expected := "660120720c6726b30f58ea21f3b0f61601f457c9a165c429705bf7c10f5a183e"
	if p != expected {
		t.Errorf("got %s, expected %s", p, expected)
	}
	if !IsPseudonym(p) {
		t.Errorf("IsPseudonym returned false for valid pseudonym %s", p)
	}
}

func TestPseudonymSessionVector(t *testing.T) {
	ring, err := NewKeyRing([]byte("01234567890123456789012345678901"), 1)
	if err != nil {
		t.Fatalf("failed to create keyring: %v", err)
	}
	p, err := ring.Pseudonym("tenant-alpha", "test-session-123")
	if err != nil {
		t.Fatalf("pseudonym failed: %v", err)
	}
	expected := "7b3835c06f46f2ddca90bc84566f21bed867aca811958afb080968a302bbd97e"
	if p != expected {
		t.Fatalf("mismatch: got %s, want %s", p, expected)
	}
}

func TestPseudonymFailClosed(t *testing.T) {
	// Root key too short
	_, err := NewKeyRing([]byte("short"), 1)
	if err == nil {
		t.Errorf("expected error for short root key, got nil")
	}

	root := []byte("12345678901234567890123456789012")
	ring, _ := NewKeyRing(root, 1)

	// Empty tenant
	_, err = ring.Pseudonym("", "val")
	if err != ErrTenantRequired {
		t.Errorf("expected ErrTenantRequired, got %v", err)
	}

	// Empty value
	_, err = ring.Pseudonym("tenant", "")
	if err != ErrValueRequired {
		t.Errorf("expected ErrValueRequired, got %v", err)
	}
}

func TestKeyCaching(t *testing.T) {
	root := []byte("12345678901234567890123456789012")
	ring, _ := NewKeyRing(root, 1)

	if ring.IsTenantKeyCached("tenant-1") {
		t.Errorf("expected key not cached initially")
	}
	_, err := ring.Pseudonym("tenant-1", "val-1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !ring.IsTenantKeyCached("tenant-1") {
		t.Errorf("expected key cached after first use")
	}
}
