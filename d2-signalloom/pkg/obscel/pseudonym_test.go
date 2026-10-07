// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package obscel

import (
	"testing"
)

func TestHMACPseudonymiser_Deterministic(t *testing.T) {
	root := []byte("01234567890123456789012345678901") // 32 bytes
	p1, err := NewHMACPseudonymiser(root, "kusari", 1)
	if err != nil {
		t.Fatalf("NewHMACPseudonymiser: %v", err)
	}
	p2, err := NewHMACPseudonymiser(root, "kusari", 1)
	if err != nil {
		t.Fatalf("NewHMACPseudonymiser: %v", err)
	}

	val := "arn:aws:iam::123456789012:user/alice"
	out1, err := p1.Pseudonym(val)
	if err != nil {
		t.Fatalf("Pseudonym 1: %v", err)
	}
	out2, err := p2.Pseudonym(val)
	if err != nil {
		t.Fatalf("Pseudonym 2: %v", err)
	}

	if out1 != out2 {
		t.Fatalf("pseudonyms must be deterministic: %q vs %q", out1, out2)
	}
	if !IsPseudonym(out1) {
		t.Fatalf("out1 is not a valid pseudonym: %q", out1)
	}

	// Empty value returns empty string and nil error
	empty, err := p1.Pseudonym("")
	if err != nil || empty != "" {
		t.Fatalf("Pseudonym(\"\") = (%q, %v), want (\"\", nil)", empty, err)
	}
}

func TestHMACPseudonymiser_FailsClosed(t *testing.T) {
	root := []byte("too-short")
	if _, err := NewHMACPseudonymiser(root, "kusari", 1); err != ErrRootKeyTooShort {
		t.Fatalf("expected ErrRootKeyTooShort, got %v", err)
	}

	validRoot := []byte("01234567890123456789012345678901")
	if _, err := NewHMACPseudonymiser(validRoot, "", 1); err != ErrTenantRequired {
		t.Fatalf("expected ErrTenantRequired, got %v", err)
	}
}
