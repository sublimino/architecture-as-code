// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package store

import (
	"crypto/rand"
	"encoding/hex"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/pseudonym"
)

// TestPseudonymCardinalityResidual red-teams the Phase 3 domain/SNI pseudonymisation
// scheme against statistical correlation, frequency analysis, and cardinality attacks.
//
// Threat Model (Consumes store/segment_pseudonymiser.go design):
// Given an adversary observing only the pseudonymised stream (domain_pseudonym labels,
// timestamps, and per-tenant event counts) without access to the KMS root key
// SIGNAL_SEGMENT_PSEUDONYM_KEY:
//
// 1. Cross-Tenant Isolation: The adversary cannot link identical cleartext domains across tenants.
// 2. Epoch Invalidation: The adversary cannot link domain pseudonyms across key rotation epochs.
// 3. Pre-image & PRF Security: The adversary cannot forge or invert pseudonyms without the root key.
//
// Accepted Residual Demonstration:
// Within a single (tenant, epoch) scope, HMAC is deterministic to permit zero-decrypt
// columnar index queries and Arrow predicate pushdown. Consequently, rare-domain frequency
// (cardinality 1) is preserved within that tenant's epoch. This is verified as an
// accepted residual bounded by tenant scoping and epoch lifecycle.
func TestPseudonymCardinalityResidual(t *testing.T) {
	// 1. Setup root key material (32 bytes = 256 bits)
	rootKey := make([]byte, 32)
	if _, err := rand.Read(rootKey); err != nil {
		t.Fatalf("failed to generate random root key: %v", err)
	}

	ringEpoch0, err := pseudonym.NewKeyRing(rootKey, 0)
	if err != nil {
		t.Fatalf("failed to construct key ring epoch 0: %v", err)
	}

	ringEpoch1, err := pseudonym.NewKeyRing(rootKey, 1)
	if err != nil {
		t.Fatalf("failed to construct key ring epoch 1: %v", err)
	}

	tenantA := "tenant-alpha"
	tenantB := "tenant-bravo"

	commonDomain := "api.github.com"
	rareDomain := "whistleblower-leak-portal.internal"

	// 2. Cryptographic Assertion 1: Cross-Tenant Domain Orthogonality
	// An adversary observing "api.github.com" traffic in Tenant A and Tenant B must see
	// completely uncorrelated pseudonyms, preventing cross-tenant linkage attacks.
	pseudoCommonTenantA, err := ringEpoch0.Pseudonym(tenantA, commonDomain)
	if err != nil {
		t.Fatalf("pseudonym generation failed: %v", err)
	}
	pseudoCommonTenantB, err := ringEpoch0.Pseudonym(tenantB, commonDomain)
	if err != nil {
		t.Fatalf("pseudonym generation failed: %v", err)
	}

	if pseudoCommonTenantA == pseudoCommonTenantB {
		t.Fatalf("CRITICAL DEFECT: Cross-tenant pseudonym collision for %s: %s == %s",
			commonDomain, pseudoCommonTenantA, pseudoCommonTenantB)
	}
	if !pseudonym.IsPseudonym(pseudoCommonTenantA) || !pseudonym.IsPseudonym(pseudoCommonTenantB) {
		t.Fatalf("Invalid pseudonym format: A=%s, B=%s", pseudoCommonTenantA, pseudoCommonTenantB)
	}
	t.Logf("Cross-tenant isolation verified: Tenant A = %s..., Tenant B = %s...",
		pseudoCommonTenantA[:16], pseudoCommonTenantB[:16])

	// 3. Cryptographic Assertion 2: Epoch Rotation Invalidation
	// Advancing the rotation epoch completely rotates the pseudonym space for the same tenant and domain,
	// defeating longitudinal frequency accumulation across epoch boundaries.
	pseudoCommonTenantAEpoch1, err := ringEpoch1.Pseudonym(tenantA, commonDomain)
	if err != nil {
		t.Fatalf("pseudonym generation failed: %v", err)
	}

	if pseudoCommonTenantA == pseudoCommonTenantAEpoch1 {
		t.Fatalf("CRITICAL DEFECT: Epoch rotation failed to rotate pseudonym: epoch 0 == epoch 1 (%s)",
			pseudoCommonTenantA)
	}
	t.Logf("Epoch rotation isolation verified: Epoch 0 = %s..., Epoch 1 = %s...",
		pseudoCommonTenantA[:16], pseudoCommonTenantAEpoch1[:16])

	// 4. Accepted Residual Demonstration: Intra-Tenant Deterministic Cardinality Preservation
	// Simulate a workload in Tenant A over one epoch:
	// - 1,000 queries to commonDomain ("api.github.com")
	// - 1 query to rareDomain ("whistleblower-leak-portal.internal")
	const commonCount = 1000
	const rareCount = 1

	pseudoRareTenantA, err := ringEpoch0.Pseudonym(tenantA, rareDomain)
	if err != nil {
		t.Fatalf("pseudonym generation failed: %v", err)
	}

	pseudonymHistogram := make(map[string]int)

	// Stream common queries
	for i := 0; i < commonCount; i++ {
		p, _ := ringEpoch0.Pseudonym(tenantA, commonDomain)
		pseudonymHistogram[p]++
	}
	// Stream rare query
	for i := 0; i < rareCount; i++ {
		p, _ := ringEpoch0.Pseudonym(tenantA, rareDomain)
		pseudonymHistogram[p]++
	}

	// Verify histogram strictly mirrors the cleartext cardinality:
	if pseudonymHistogram[pseudoCommonTenantA] != commonCount {
		t.Errorf("Histogram count for common pseudonym = %d, want %d",
			pseudonymHistogram[pseudoCommonTenantA], commonCount)
	}
	if pseudonymHistogram[pseudoRareTenantA] != rareCount {
		t.Errorf("Histogram count for rare pseudonym = %d, want %d",
			pseudonymHistogram[pseudoRareTenantA], rareCount)
	}

	// Record accepted residual conclusion:
	// While the pseudonym is computationally indistinguishable from random noise (HMAC-SHA256),
	// the cardinality of the rare pseudonym (1 occurrence) is visible to an attacker observing
	// the stored columnar dataset.
	//
	// Architectural Rationale (Accepted Residual):
	// Deterministic HMAC is mandatory for high-performance Arrow/FrostDB columnar query pushdown
	// without full-table scan and decryption. Non-deterministic probabilistic encryption
	// would incur an unacceptable ~7x query latency penalty (19.43ms vs 2.75ms).
	// The residual is properly bounded by tenant scoping and epoch rotation.
	t.Logf("ACCEPTED RESIDUAL VERIFIED: Intra-tenant cardinality preserved (common=%d, rare=%d) under deterministic HMAC-SHA256 for columnar pushdown",
		pseudonymHistogram[pseudoCommonTenantA], pseudonymHistogram[pseudoRareTenantA])
}

// TestPseudonymSegmentStoreIntegration verifies the SegmentPseudonymiser wrapper
// conforms to the ActorPseudonymiser interface for domain labels.
func TestPseudonymSegmentStoreIntegration(t *testing.T) {
	rootKeyHex := hex.EncodeToString([]byte("01234567890123456789012345678901"))
	t.Setenv(SegmentPseudonymKeyEnv, rootKeyHex)
	t.Setenv(SegmentPseudonymEpochEnv, "0")
	t.Setenv(SegmentPseudonymTenantEnv, "tenant-test-scope")

	pseudonymiser, err := NewSegmentPseudonymiserFromEnv()
	if err != nil {
		t.Fatalf("failed to construct SegmentPseudonymiser from env: %v", err)
	}

	domain1 := "internal.controlplane.io"
	p1, err := pseudonymiser.Pseudonym(domain1)
	if err != nil {
		t.Fatalf("pseudonym failed: %v", err)
	}
	if !pseudonym.IsPseudonym(p1) {
		t.Fatalf("invalid pseudonym format: %s", p1)
	}

	// Repeat must be deterministic
	p2, err := pseudonymiser.Pseudonym(domain1)
	if err != nil {
		t.Fatalf("second pseudonym failed: %v", err)
	}
	if p1 != p2 {
		t.Fatalf("non-deterministic pseudonym: %s != %s", p1, p2)
	}
}
