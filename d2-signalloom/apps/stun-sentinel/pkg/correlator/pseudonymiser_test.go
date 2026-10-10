// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"encoding/hex"
	"errors"
	"os"
	"testing"
)

// testSegmentRootKeyHex matches signal-ingest/store/segment_schema_v2_test.go's test key.
const testSegmentRootKeyHex = "303132333435363738396162636465663031323334353637383961626364656601"

func TestMain(m *testing.M) {
	if os.Getenv(SegmentPseudonymKeyEnv) == "" {
		_ = os.Setenv(SegmentPseudonymKeyEnv, testSegmentRootKeyHex)
	}
	os.Exit(m.Run())
}

func testPseudonymiser(t *testing.T) *Pseudonymiser {
	t.Helper()
	root, err := hex.DecodeString(testSegmentRootKeyHex)
	if err != nil {
		t.Fatalf("decode test key: %v", err)
	}
	p, err := NewPseudonymiser(root, 0)
	if err != nil {
		t.Fatalf("NewPseudonymiser: %v", err)
	}
	return p
}

func TestPseudonymiser_Deterministic(t *testing.T) {
	p := testPseudonymiser(t)
	domain := "api.anthropic.com"
	tenant := "kusari"

	res1, err := p.Pseudonym(tenant, domain)
	if err != nil {
		t.Fatalf("Pseudonym failed: %v", err)
	}
	res2, err := p.Pseudonym(tenant, domain)
	if err != nil {
		t.Fatalf("Pseudonym failed: %v", err)
	}

	if res1 != res2 {
		t.Fatalf("pseudonym not deterministic: %q != %q", res1, res2)
	}
	if !IsPseudonym(res1) {
		t.Fatalf("result %q is not a valid 64-char hex pseudonym", res1)
	}
}

func TestPseudonymiser_TenantScoped(t *testing.T) {
	p := testPseudonymiser(t)
	domain := "api.openai.com"

	p1, err := p.Pseudonym("tenant-a", domain)
	if err != nil {
		t.Fatalf("Pseudonym tenant-a failed: %v", err)
	}
	p2, err := p.Pseudonym("tenant-b", domain)
	if err != nil {
		t.Fatalf("Pseudonym tenant-b failed: %v", err)
	}

	if p1 == p2 {
		t.Fatalf("cross-tenant pseudonym collision: tenant-a and tenant-b produced same pseudonym %q", p1)
	}
}

func TestPseudonymiser_EpochScoped(t *testing.T) {
	root, _ := hex.DecodeString(testSegmentRootKeyHex)
	pEpoch0, _ := NewPseudonymiser(root, 0)
	pEpoch1, _ := NewPseudonymiser(root, 1)

	domain := "auth.corp.internal"
	tenant := "kusari"

	p0, err := pEpoch0.Pseudonym(tenant, domain)
	if err != nil {
		t.Fatal(err)
	}
	p1, err := pEpoch1.Pseudonym(tenant, domain)
	if err != nil {
		t.Fatal(err)
	}

	if p0 == p1 {
		t.Fatalf("cross-epoch pseudonym collision: epoch 0 and 1 produced same pseudonym %q", p0)
	}
}

func TestPseudonymiser_FailsClosed(t *testing.T) {
	// 1. Under-length root key
	shortKey := []byte("short-key-under-32-bytes")
	if _, err := NewPseudonymiser(shortKey, 0); !errors.Is(err, ErrPseudonymKeyRequired) {
		t.Fatalf("NewPseudonymiser with short key must return ErrPseudonymKeyRequired, got %v", err)
	}

	// 2. Nil root key
	if _, err := NewPseudonymiser(nil, 0); !errors.Is(err, ErrPseudonymKeyRequired) {
		t.Fatalf("NewPseudonymiser with nil key must return ErrPseudonymKeyRequired, got %v", err)
	}

	p := testPseudonymiser(t)

	// 3. Empty tenant
	if _, err := p.Pseudonym("", "example.com"); !errors.Is(err, ErrPseudonymTenantRequired) {
		t.Fatalf("Pseudonym with empty tenant must return ErrPseudonymTenantRequired, got %v", err)
	}

	// 4. Empty value returns ("", nil)
	val, err := p.Pseudonym("kusari", "")
	if err != nil {
		t.Fatalf("Pseudonym with empty value must return nil error, got %v", err)
	}
	if val != "" {
		t.Fatalf("Pseudonym with empty value must return empty string, got %q", val)
	}
}

func TestPseudonymiser_FromEnv(t *testing.T) {
	t.Setenv(SegmentPseudonymKeyEnv, testSegmentRootKeyHex)
	t.Setenv(SegmentPseudonymEpochEnv, "2")

	p, err := NewPseudonymiserFromEnv()
	if err != nil {
		t.Fatalf("NewPseudonymiserFromEnv failed: %v", err)
	}
	if p.Epoch() != 2 {
		t.Fatalf("p.Epoch() = %d, want 2", p.Epoch())
	}

	// Bad hex
	t.Setenv(SegmentPseudonymKeyEnv, "not-hex")
	if _, err := NewPseudonymiserFromEnv(); err == nil {
		t.Fatal("NewPseudonymiserFromEnv with invalid hex must fail")
	}

	// Unset
	t.Setenv(SegmentPseudonymKeyEnv, "")
	if _, err := NewPseudonymiserFromEnv(); !errors.Is(err, ErrPseudonymKeyRequired) {
		t.Fatalf("NewPseudonymiserFromEnv with unset key must return ErrPseudonymKeyRequired, got %v", err)
	}
}

func TestIsPseudonym(t *testing.T) {
	p := testPseudonymiser(t)
	res, _ := p.Pseudonym("kusari", "api.anthropic.com")
	if !IsPseudonym(res) {
		t.Errorf("IsPseudonym(%q) = false, want true", res)
	}
	if IsPseudonym("short") {
		t.Error("IsPseudonym(short) = true, want false")
	}
	if IsPseudonym("api.anthropic.com") {
		t.Error("IsPseudonym(cleartext) = true, want false")
	}
}
