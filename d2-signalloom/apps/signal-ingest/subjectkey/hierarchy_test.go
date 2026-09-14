// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package subjectkey

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

const testMaster = "0123456789abcdef0123456789abcdef"

func testHierarchy(t *testing.T) *Hierarchy {
	t.Helper()
	h, err := NewHierarchy([]byte(testMaster))
	if err != nil {
		t.Fatalf("NewHierarchy: %v", err)
	}
	return h
}

// pseudo returns a well-formed 64-hex pseudonym for tests, distinct per label.
func pseudo(label string) string {
	out := make([]byte, 0, 64)
	for len(out) < 64 {
		for i := 0; i < len(label) && len(out) < 64; i++ {
			out = append(out, "0123456789abcdef"[label[i]%16])
		}
		out = append(out, '7')
	}
	return string(out[:64])
}

// ISC-2, ISC-3, ISC-4: fail closed on absent or short key material, with no opt-in escape.
func TestHierarchy_RefusesWeakMasterKey(t *testing.T) {
	for _, tc := range []struct {
		name string
		key  []byte
	}{
		{"empty", nil},
		{"zero length", []byte{}},
		{"one byte short", bytes.Repeat([]byte("a"), MinMasterKeyBytes-1)},
		{"passphrase", []byte("hunter2")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			// Set every dev opt-in variable the identity package honours. If a passthrough escape
			// hatch existed here it would fire under exactly these conditions, so the test asserts
			// the ABSENCE of the escape rather than trusting the absence of the code.
			for _, env := range []string{
				"INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR",
				"IDENTITY_ALLOW_NOOP_ENCRYPTOR",
				"SIGNAL_INGEST_ALLOW_NOOP_ENCRYPTOR",
				"SUBJECTKEY_ALLOW_NOOP",
			} {
				t.Setenv(env, "true")
			}
			h, err := NewHierarchy(tc.key)
			if err == nil {
				t.Fatalf("expected refusal, got a usable hierarchy %v", h)
			}
			if h != nil {
				t.Fatalf("a refusal must not also return a hierarchy")
			}
		})
	}
}

// ISC-8, ISC-9, ISC-10: tenant KEKs are scoped and deterministic.
func TestHierarchy_TenantKEKScopeAndDeterminism(t *testing.T) {
	h := testHierarchy(t)
	a1, err := h.tenantKEK("tenant-a", 0)
	if err != nil {
		t.Fatalf("derive a: %v", err)
	}
	a2, _ := h.tenantKEK("tenant-a", 0)
	b, _ := h.tenantKEK("tenant-b", 0)
	e1, _ := h.tenantKEK("tenant-a", 1)

	if !bytes.Equal(a1, a2) {
		t.Fatal("derivation is not deterministic")
	}
	if bytes.Equal(a1, b) {
		t.Fatal("two tenants derived the SAME key; every tenant shares one key domain")
	}
	if bytes.Equal(a1, e1) {
		t.Fatal("two epochs derived the same key; rotation would be a no-op")
	}
	if len(a1) != TenantKEKBytes {
		t.Fatalf("tenant KEK is %d bytes, expected %d", len(a1), TenantKEKBytes)
	}
}

// ISC-7: the HKDF info construction is collision-free across tenant-name boundaries.
//
// Without length prefixing, tenants "ab"+"c" and "a"+"bc" concatenate identically. This test drives
// the actual byte construction rather than asserting the comment is present.
func TestHierarchy_InfoIsCollisionFree(t *testing.T) {
	if bytes.Equal(deriveInfo(0, "abc"), deriveInfo(0, "ab\x00c")) {
		t.Fatal("deriveInfo collides across a NUL boundary")
	}
	// The pair that a naive domain||epoch||tenant concatenation would collide on.
	i1 := deriveInfo(1, "a")
	i2 := deriveInfo(0, "\x00\x00\x00\x01a")
	if bytes.Equal(i1, i2) {
		t.Fatal("deriveInfo collides between an epoch and a tenant-name prefix")
	}
}

// ISC-11, ISC-12, ISC-14: DEKs are random, not derived.
//
// THE load-bearing property of this whole package. A derived DEK — HKDF(tenantKEK, pseudonym) —
// would make every other test here pass unchanged while making destruction impossible, because the
// master key holder re-derives it. This test asserts the same inputs produce DIFFERENT keys, which
// is exactly the assertion a derived implementation fails.
func TestHierarchy_DEKIsRandomNotDerived(t *testing.T) {
	seen := make(map[string]struct{}, 64)
	for i := 0; i < 64; i++ {
		dek, err := NewDEK()
		if err != nil {
			t.Fatalf("NewDEK: %v", err)
		}
		if len(dek) != DEKBytes {
			t.Fatalf("DEK is %d bytes, expected %d", len(dek), DEKBytes)
		}
		k := string(dek)
		if _, dup := seen[k]; dup {
			t.Fatal("NewDEK returned a repeated key; it is derived or the CSPRNG is broken, and destruction would be theatre")
		}
		seen[k] = struct{}{}
	}
}

// ISC-15, ISC-16, ISC-17, ISC-18, ISC-19: the wrap binds scope and detects tampering.
func TestHierarchy_WrapBindsScope(t *testing.T) {
	h := testHierarchy(t)
	base := KeyScope{TenantID: "t1", SubjectPseudonym: pseudo("alice"), KeyEpoch: 0, KeyVersion: 1}
	dek, _ := NewDEK()
	wrapped, err := h.WrapDEK(base, dek)
	if err != nil {
		t.Fatalf("WrapDEK: %v", err)
	}
	if len(wrapped) != wrappedDEKLen {
		t.Fatalf("wrapped key is %d bytes, expected %d", len(wrapped), wrappedDEKLen)
	}
	if bytes.Contains(wrapped, dek) {
		t.Fatal("the wrapped key contains the plaintext DEK verbatim")
	}

	got, err := h.UnwrapDEK(base, wrapped)
	if err != nil {
		t.Fatalf("UnwrapDEK in its own scope: %v", err)
	}
	if !bytes.Equal(got, dek) {
		t.Fatal("round trip did not return the original key")
	}

	// Each mutation must break the unwrap. If any of these succeeded, a wrapped key could be moved
	// between rows and would decrypt into a value silently disagreeing with the row it now sits in.
	for name, mutated := range map[string]KeyScope{
		"other subject": {TenantID: "t1", SubjectPseudonym: pseudo("bob"), KeyEpoch: 0, KeyVersion: 1},
		"other version": {TenantID: "t1", SubjectPseudonym: pseudo("alice"), KeyEpoch: 0, KeyVersion: 2},
		"other epoch":   {TenantID: "t1", SubjectPseudonym: pseudo("alice"), KeyEpoch: 1, KeyVersion: 1},
		"other tenant":  {TenantID: "t2", SubjectPseudonym: pseudo("alice"), KeyEpoch: 0, KeyVersion: 1},
	} {
		if _, err := h.UnwrapDEK(mutated, wrapped); err == nil {
			t.Fatalf("a wrapped key opened in the %q scope; the AAD binding is not enforced", name)
		}
	}

	if _, err := h.UnwrapDEK(base, TamperWrapped(wrapped)); err == nil {
		t.Fatal("a single flipped bit did not fail the GCM tag")
	}
}

// ISC-20, ISC-127, ISC-128, ISC-129: the tenant KEK is unreachable from the erasure path.
//
// This is a SOURCE guard, and it exists because the property it protects is an absence. A comment
// saying "we never destroy the tenant KEK" stays true-looking after someone adds DestroyTenantKEK
// next month; a grep over the package's own source does not.
//
// The guard is mutation-checked below by asserting it matches a deliberately-planted string, so a
// regexp that silently matches nothing cannot pass as "no violations found".
func TestHierarchy_NoTenantKEKDestructionSurface(t *testing.T) {
	forbidden := regexp.MustCompile(`(?i)\b(destroy|delete|purge|revoke|shred|zero)[a-z]*(tenant|master)[a-z]*(kek|key)\b|\b(tenant|master)[a-z]*(kek|key)[a-z]*(destroy|delete|purge|revoke|shred)\b`)

	// Falsify the guard FIRST. A regexp that matches nothing reports "clean" identically to a
	// codebase that is clean, and the two are indistinguishable without this.
	for _, bait := range []string{"func DestroyTenantKEK(", "TenantKeyDelete", "purgeMasterKey"} {
		if !forbidden.MatchString(bait) {
			t.Fatalf("the guard pattern does not match the planted violation %q; it would report a clean package regardless of contents", bait)
		}
	}

	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("read package dir: %v", err)
	}
	scanned := 0
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		body, err := os.ReadFile(filepath.Clean(name))
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		scanned++
		for i, line := range strings.Split(string(body), "\n") {
			trimmed := strings.TrimSpace(line)
			// Comments discuss the absence at length; they are documentation, not surface.
			if strings.HasPrefix(trimmed, "//") {
				continue
			}
			if forbidden.MatchString(line) {
				t.Errorf("%s:%d introduces a tenant/master key destruction surface: %s", name, i+1, trimmed)
			}
		}
	}
	// A scan that read zero files would report clean. Assert it actually looked.
	if scanned < 5 {
		t.Fatalf("the guard scanned only %d non-test source files; it is not covering the package", scanned)
	}

	// The positive half: there IS a way to observe a tenant KEK without extracting it, and it is
	// one-way. If this ever returned the key itself the guard above would be moot.
	h := testHierarchy(t)
	fp, err := h.TenantKEKFingerprint("t1", 0)
	if err != nil {
		t.Fatalf("fingerprint: %v", err)
	}
	kek, _ := h.tenantKEK("t1", 0)
	if bytes.Equal(fp, kek) {
		t.Fatal("the fingerprint IS the key")
	}
}

// ISC-96: Zero actually clears the buffer it is handed.
func TestZero_ClearsBuffer(t *testing.T) {
	b := []byte{1, 2, 3, 4, 5}
	Zero(b)
	for i, v := range b {
		if v != 0 {
			t.Fatalf("byte %d is %d after Zero", i, v)
		}
	}
	Zero(nil) // must not panic
}
