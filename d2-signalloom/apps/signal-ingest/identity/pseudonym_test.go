// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package identity

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// testRootKey is 32 bytes of fixed, non-secret material for deterministic tests.
var testRootKey = []byte("0123456789abcdef0123456789abcdef")

func mustKeyRing(t *testing.T, epoch uint32) *PseudonymKeyRing {
	t.Helper()
	k, err := NewPseudonymKeyRing(testRootKey, epoch)
	if err != nil {
		t.Fatalf("NewPseudonymKeyRing: %v", err)
	}
	return k
}

// ---------------------------------------------------------------------------
// Key ring construction — fail-closed behaviour
// ---------------------------------------------------------------------------

func TestPseudonymKeyRing_FailsClosedOnWeakRootKey(t *testing.T) {
	cases := []struct {
		name string
		root []byte
	}{
		{"nil", nil},
		{"empty", []byte{}},
		{"one byte", []byte("x")},
		{"31 bytes, one short", []byte("0123456789abcdef0123456789abcde")},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ring, err := NewPseudonymKeyRing(tc.root, 0)
			if !errors.Is(err, ErrPseudonymRootKeyTooShort) {
				t.Fatalf("expected ErrPseudonymRootKeyTooShort, got %v", err)
			}
			if ring != nil {
				t.Fatal("a rejected key ring must be nil, not a degraded usable object")
			}
		})
	}
}

// TestPseudonymKeyRing_ErrorValueIsNotALegalAnswer pins the rule that an error path never yields
// a string a caller could mistake for a pseudonym. Returning "" would be indistinguishable from
// "this identifier legitimately has no pseudonym", which is how a control fails open.
func TestPseudonymKeyRing_ErrorValueIsNotALegalAnswer(t *testing.T) {
	k := mustKeyRing(t, 0)

	if p, err := k.Pseudonym("", "alice@corp.internal"); !errors.Is(err, ErrPseudonymTenantRequired) || p != "" {
		t.Fatalf("empty tenant: want (\"\", ErrPseudonymTenantRequired), got (%q, %v)", p, err)
	}
	if p, err := k.Pseudonym("tenant-a", ""); !errors.Is(err, ErrPseudonymValueRequired) || p != "" {
		t.Fatalf("empty value: want (\"\", ErrPseudonymValueRequired), got (%q, %v)", p, err)
	}
	if IsPseudonym("") {
		t.Fatal("the empty string must not satisfy IsPseudonym")
	}
}

// ---------------------------------------------------------------------------
// Scoping and domain separation
// ---------------------------------------------------------------------------

func TestPseudonym_DeterministicWithinScope(t *testing.T) {
	k := mustKeyRing(t, 0)
	const val = "alice@corp.internal"

	first, err := k.Pseudonym("tenant-a", val)
	if err != nil {
		t.Fatalf("Pseudonym: %v", err)
	}
	for i := 0; i < 64; i++ {
		got, err := k.Pseudonym("tenant-a", val)
		if err != nil {
			t.Fatalf("Pseudonym iteration %d: %v", i, err)
		}
		if got != first {
			t.Fatalf("pseudonym not deterministic at iteration %d: %s vs %s", i, got, first)
		}
	}
	if !IsPseudonym(first) {
		t.Fatalf("pseudonym %q does not have pseudonym shape", first)
	}
}

func TestPseudonym_TenantScopesAreIncomparable(t *testing.T) {
	k := mustKeyRing(t, 0)
	const val = "alice@corp.internal"

	a, err := k.Pseudonym("tenant-a", val)
	if err != nil {
		t.Fatalf("tenant-a: %v", err)
	}
	b, err := k.Pseudonym("tenant-b", val)
	if err != nil {
		t.Fatalf("tenant-b: %v", err)
	}
	if a == b {
		t.Fatal("the same identifier produced the same pseudonym under two tenants; cross-tenant correlation is possible")
	}
}

func TestPseudonym_EpochScopesAreIncomparable(t *testing.T) {
	const val = "alice@corp.internal"

	e0, err := mustKeyRing(t, 0).Pseudonym("tenant-a", val)
	if err != nil {
		t.Fatalf("epoch 0: %v", err)
	}
	e1, err := mustKeyRing(t, 1).Pseudonym("tenant-a", val)
	if err != nil {
		t.Fatalf("epoch 1: %v", err)
	}
	if e0 == e1 {
		t.Fatal("rotating the epoch did not change the pseudonym; rotation would be a no-op")
	}
}

// TestPseudonym_TenantBoundaryIsUnambiguous is the concatenation-ambiguity probe.
//
// Without a length prefix on the tenant in the HKDF info parameter, tenant "ab" and tenant "a"
// followed by a value beginning "b" can serialise to the same byte string, silently merging two
// tenants' correlation domains. This checks the boundary explicitly rather than trusting that the
// construction happens to be prefix-free.
func TestPseudonym_TenantBoundaryIsUnambiguous(t *testing.T) {
	k := mustKeyRing(t, 0)

	pairs := [][2]string{
		{"ab", "c"},
		{"a", "bc"},
		{"abc", ""},
		{"", "abc"},
	}
	seen := map[string][2]string{}
	for _, p := range pairs {
		tenant, value := p[0], p[1]
		if tenant == "" || value == "" {
			continue // covered by the fail-closed test; not a collision candidate
		}
		got, err := k.Pseudonym(tenant, value)
		if err != nil {
			t.Fatalf("Pseudonym(%q,%q): %v", tenant, value, err)
		}
		if prev, dup := seen[got]; dup {
			t.Fatalf("HKDF info is ambiguous: (%q,%q) and (%q,%q) produced the same pseudonym",
				prev[0], prev[1], tenant, value)
		}
		seen[got] = p
	}
}

// TestPseudonym_DomainIsVersionPinned guards the domain-separation constant. Editing it in place
// rather than versioning it would silently invalidate every stored pseudonym.
func TestPseudonym_DomainIsVersionPinned(t *testing.T) {
	if PseudonymDomain != "signalloom/identity/alias-pseudonym/v1" {
		t.Fatalf("PseudonymDomain changed to %q. Changing it in place invalidates every stored pseudonym. "+
			"Introduce a new /vN suffix and bump the epoch instead.", PseudonymDomain)
	}
}

func TestPseudonym_KeyDerivationIsCached(t *testing.T) {
	k := mustKeyRing(t, 0)
	if _, err := k.Pseudonym("tenant-a", "x@corp.internal"); err != nil {
		t.Fatalf("first call: %v", err)
	}
	if _, ok := k.derived.Load("tenant-a"); !ok {
		t.Fatal("tenant key was not cached after first use; HKDF would re-run on every lookup")
	}
}

// ---------------------------------------------------------------------------
// Adversarial dictionary attack
// ---------------------------------------------------------------------------

// candidateDirectory builds an attacker's plausible-identifier list.
//
// The threat model is not a global rainbow table; it is an attacker who knows the shape of the
// victim's identifier namespace. For a corporate identity graph that is a small, highly
// enumerable space: first.last@corp.internal, usernames, and SPIFFE IDs from a known cluster.
// Every real seeded fixture value is included, so the attack is given every advantage.
func candidateDirectory(t *testing.T) []string {
	t.Helper()

	firsts := []string{
		"alice", "bob", "carol", "dave", "erin", "frank", "grace", "heidi",
		"ivan", "judy", "ken", "leo", "mallory", "niaj", "olivia", "peggy",
		"quentin", "rupert", "sybil", "trent", "uma", "victor", "walter", "xena",
		"yvonne", "zach", "andy", "gabs", "priya", "raj", "sofia", "tomas",
	}
	lasts := []string{"", ".smith", ".jones", ".patel", ".nguyen", ".oconnor", "-admin", "-svc", "-promoted", "-ops"}
	domains := []string{"corp.internal", "control-plane.io", "example.com"}

	var out []string
	for _, f := range firsts {
		for _, l := range lasts {
			for _, d := range domains {
				out = append(out, fmt.Sprintf("%s%s@%s", f, l, d))
			}
		}
		out = append(out, f, strings.ToUpper(f))
		for _, ns := range []string{"prod", "security", "staging"} {
			for _, sa := range []string{"deployer", "scanner", "runner", f} {
				out = append(out, fmt.Sprintf("spiffe://cluster.local/ns/%s/sa/%s", ns, sa))
			}
		}
		out = append(out, fmt.Sprintf("%s-session-123", f))
	}

	// Give the attacker every real value outright.
	for _, fixture := range FixtureAliases {
		out = append(out, fixture.AliasValue)
	}

	if len(out) < 1000 {
		t.Fatalf("candidate directory is only %d entries; the attack is not being given a fair chance", len(out))
	}
	return out
}

// TestAliasPseudonym_ResistsDictionaryAttack is the card's adversarial proof.
//
// It runs the attack twice against the same candidate directory:
//
//	Positive control — the OLD scheme. Bare sha256.Sum256 over the alias value, which is exactly
//	what encryption.go:135-138 used to compute. The attack MUST succeed here. If it does not, the
//	attack harness itself is broken and the negative result below would be meaningless.
//
//	The real assertion — the NEW scheme. Keyed HMAC-SHA256 under a key the attacker does not hold.
//	A single successful inversion fails the test.
//
// This test is not skipped, not gated on an environment variable, and not short-circuited.
func TestAliasPseudonym_ResistsDictionaryAttack(t *testing.T) {
	candidates := candidateDirectory(t)
	t.Logf("candidate directory: %d plausible identifiers", len(candidates))

	// Values actually held by the system — the pseudonyms an attacker would see in the aliases table.
	var secrets []string
	for _, fixture := range FixtureAliases {
		secrets = append(secrets, fixture.AliasValue)
	}
	if len(secrets) == 0 {
		t.Fatal("no fixture aliases to attack; the test would vacuously pass")
	}

	// --- Positive control: prove the attack works against the scheme we removed. ---
	legacyRainbow := make(map[string]string, len(candidates))
	for _, c := range candidates {
		sum := sha256.Sum256([]byte(c))
		legacyRainbow[hex.EncodeToString(sum[:])] = c
	}
	legacyInverted := 0
	for _, s := range secrets {
		sum := sha256.Sum256([]byte(s))
		if recovered, ok := legacyRainbow[hex.EncodeToString(sum[:])]; ok && recovered == s {
			legacyInverted++
		}
	}
	if legacyInverted != len(secrets) {
		t.Fatalf("POSITIVE CONTROL FAILED: the rainbow table inverted only %d/%d unkeyed digests. "+
			"The attack harness is broken, so the negative result below proves nothing.",
			legacyInverted, len(secrets))
	}
	t.Logf("positive control: unkeyed SHA-256 inverted %d/%d secrets — the removed scheme is breakable as claimed",
		legacyInverted, len(secrets))

	// --- The real assertion: the keyed scheme, attacked without the key. ---
	ring := mustKeyRing(t, 0)
	const tenant = "acme-bank"

	// What the attacker can see: the stored pseudonyms.
	observed := make(map[string]string, len(secrets))
	for _, s := range secrets {
		p, err := ring.Pseudonym(tenant, s)
		if err != nil {
			t.Fatalf("Pseudonym(%q): %v", s, err)
		}
		observed[p] = s
	}

	// What the attacker can compute without the key. An attacker who knows the algorithm and the
	// tenant but not the key can only guess key material; here they are modelled as trying the
	// unkeyed digest and a set of plausible wrong keys, including the public default salt that
	// SLDP-P2-1 deleted from transform/secrets_scrubber.go.
	wrongKeys := [][]byte{
		[]byte("signal-loom-default-identity-salt-2026"),
		[]byte("0000000000000000000000000000000000000000"),
		[]byte("signalloom/identity/alias-pseudonym/v1__"),
		[]byte(tenant + "0000000000000000000000000000"),
	}

	inversions := 0
	for _, c := range candidates {
		// Attempt 1: the unkeyed digest, i.e. assume the old scheme is still in use.
		sum := sha256.Sum256([]byte(c))
		if orig, hit := observed[hex.EncodeToString(sum[:])]; hit {
			t.Errorf("INVERTED %q via unkeyed SHA-256 (secret was %q)", c, orig)
			inversions++
		}
		// Attempt 2: guessed key material, including the deleted public default salt.
		for _, wk := range wrongKeys {
			guessRing, err := NewPseudonymKeyRing(padTo32(wk), 0)
			if err != nil {
				continue
			}
			guess, err := guessRing.Pseudonym(tenant, c)
			if err != nil {
				continue
			}
			if orig, hit := observed[guess]; hit {
				t.Errorf("INVERTED %q via guessed key material (secret was %q)", c, orig)
				inversions++
			}
		}
	}

	if inversions != 0 {
		t.Fatalf("%d pseudonym(s) inverted against a %d-entry candidate directory; the pseudonymisation control does not hold",
			inversions, len(candidates))
	}
	t.Logf("keyed HMAC: 0/%d secrets inverted against %d candidates across %d key guesses",
		len(secrets), len(candidates), len(wrongKeys)+1)
}

// padTo32 stretches short attacker key guesses to the minimum accepted length, so a guess is
// rejected on being wrong rather than on being malformed.
func padTo32(b []byte) []byte {
	if len(b) >= MinPseudonymRootKeyBytes {
		return b
	}
	out := make([]byte, MinPseudonymRootKeyBytes)
	copy(out, b)
	return out
}

// TestAliasPseudonym_CrossTenantSetsAreDisjoint proves one tenant's pseudonym set cannot be
// compared against another's — the correlation channel a single global key would leave open.
func TestAliasPseudonym_CrossTenantSetsAreDisjoint(t *testing.T) {
	ring := mustKeyRing(t, 0)
	shared := candidateDirectory(t)

	setA := make(map[string]struct{}, len(shared))
	for _, v := range shared {
		p, err := ring.Pseudonym("tenant-alpha", v)
		if err != nil {
			t.Fatalf("tenant-alpha %q: %v", v, err)
		}
		setA[p] = struct{}{}
	}

	overlap := 0
	for _, v := range shared {
		p, err := ring.Pseudonym("tenant-bravo", v)
		if err != nil {
			t.Fatalf("tenant-bravo %q: %v", v, err)
		}
		if _, hit := setA[p]; hit {
			overlap++
		}
	}
	if overlap != 0 {
		t.Fatalf("%d pseudonyms collide across tenants over an identical %d-value population; tenants are correlatable",
			overlap, len(shared))
	}
}

// ---------------------------------------------------------------------------
// Envelope encryption
// ---------------------------------------------------------------------------

func mustEncryptor(t *testing.T) *AESGCMEncryptor {
	t.Helper()
	e, err := NewAESGCMEncryptor([]byte("01234567890123456789012345678901"))
	if err != nil {
		t.Fatalf("NewAESGCMEncryptor: %v", err)
	}
	return e
}

// testAAD is a representative row binding for envelope tests.
func testAAD(t *testing.T, actorID, aliasType, value string) []byte {
	t.Helper()
	p, err := mustKeyRing(t, 0).Pseudonym("tenant-a", value)
	if err != nil {
		t.Fatalf("Pseudonym: %v", err)
	}
	return AliasEnvelopeAAD(actorID, aliasType, p)
}

func TestAliasEnvelope_Roundtrip(t *testing.T) {
	e := mustEncryptor(t)
	cases := []string{
		"alice@corp.internal",
		"spiffe://cluster.local/ns/prod/sa/deployer",
		"",
		"ünïcödé-名前@corp.internal",
		strings.Repeat("x", 512),
	}
	for _, in := range cases {
		aad := AliasEnvelopeAAD("actor-1", "email", strings.Repeat("a", PseudonymHexLen))
		sealed, err := e.EncryptEnvelope([]byte(in), aad)
		if err != nil {
			t.Fatalf("EncryptEnvelope(%q): %v", in, err)
		}
		if in != "" && strings.Contains(string(sealed), in) {
			t.Fatalf("envelope for %q contains the plaintext verbatim", in)
		}
		out, err := e.DecryptEnvelope(sealed, aad)
		if err != nil {
			t.Fatalf("DecryptEnvelope(%q): %v", in, err)
		}
		if string(out) != in {
			t.Fatalf("roundtrip mismatch: got %q want %q", string(out), in)
		}
	}
}

// TestAliasEnvelope_RejectsCrossRowSubstitution is the reason the envelope carries AAD.
//
// Without it, an attacker holding UPDATE on the aliases table can copy alias_value_encrypted from
// one row into another. The ciphertext decrypts perfectly, the row's pseudonym column now
// disagrees with the plaintext, and nothing cross-checks the two — so the identity graph resolves
// an actor to an alias value that was never theirs. Binding the ciphertext to
// (actor_id, alias_type, pseudonym) makes the substitution fail the GCM tag instead.
func TestAliasEnvelope_RejectsCrossRowSubstitution(t *testing.T) {
	e := mustEncryptor(t)

	aliceAAD := testAAD(t, "actor-alice", "email", "alice@corp.internal")
	bobAAD := testAAD(t, "actor-bob", "email", "bob@corp.internal")

	sealedAlice, err := e.EncryptEnvelope([]byte("alice@corp.internal"), aliceAAD)
	if err != nil {
		t.Fatalf("EncryptEnvelope: %v", err)
	}

	// Alice's ciphertext pasted into Bob's row.
	out, err := e.DecryptEnvelope(sealedAlice, bobAAD)
	if err == nil {
		t.Fatalf("cross-row substitution accepted, yielding %q; the ciphertext is not bound to its row", string(out))
	}
	if !errors.Is(err, ErrInvalidEnvelope) {
		t.Fatalf("expected ErrInvalidEnvelope on substitution, got %v", err)
	}
	if out != nil {
		t.Fatalf("a rejected envelope must return nil plaintext, got %q", string(out))
	}

	// The same ciphertext in its own row still opens.
	if _, err := e.DecryptEnvelope(sealedAlice, aliceAAD); err != nil {
		t.Fatalf("legitimate open failed: %v", err)
	}
}

func TestAliasEnvelope_FreshDataKeyPerCall(t *testing.T) {
	e := mustEncryptor(t)
	const in = "alice@corp.internal"
	aad := testAAD(t, "actor-1", "email", in)

	a, err := e.EncryptEnvelope([]byte(in), aad)
	if err != nil {
		t.Fatalf("EncryptEnvelope: %v", err)
	}
	b, err := e.EncryptEnvelope([]byte(in), aad)
	if err != nil {
		t.Fatalf("EncryptEnvelope: %v", err)
	}
	if string(a) == string(b) {
		t.Fatal("two envelopes of identical plaintext are byte-identical; the data key or nonce is not fresh")
	}
}

// TestAliasEnvelope_NoopRefusesRealEnvelope pins that a dev-mode process cannot silently return
// envelope bytes as if they were an alias value.
func TestAliasEnvelope_NoopRefusesRealEnvelope(t *testing.T) {
	real := mustEncryptor(t)
	aad := testAAD(t, "actor-1", "email", "alice@corp.internal")
	sealed, err := real.EncryptEnvelope([]byte("alice@corp.internal"), aad)
	if err != nil {
		t.Fatalf("EncryptEnvelope: %v", err)
	}

	noop := NewNoopEncryptor()
	defer noop.Stop()

	out, err := noop.DecryptEnvelope(sealed, aad)
	if err == nil {
		t.Fatalf("NoopEncryptor returned %q for a real envelope instead of refusing", string(out))
	}
	if !errors.Is(err, ErrInvalidEnvelope) {
		t.Fatalf("expected ErrInvalidEnvelope, got %v", err)
	}
}

func TestAliasEnvelope_RejectsTamperingAndTruncation(t *testing.T) {
	e := mustEncryptor(t)
	aad := testAAD(t, "actor-1", "email", "alice@corp.internal")
	good, err := e.EncryptEnvelope([]byte("alice@corp.internal"), aad)
	if err != nil {
		t.Fatalf("EncryptEnvelope: %v", err)
	}

	mutate := func(base []byte, fn func([]byte)) []byte {
		cp := make([]byte, len(base))
		copy(cp, base)
		fn(cp)
		return cp
	}

	cases := []struct {
		name  string
		input []byte
	}{
		{"nil", nil},
		{"header only", good[:envelopeHeaderBytes]},
		{"truncated below header", good[:1]},
		{"truncated mid wrapped key", good[:envelopeHeaderBytes+2]},
		{"body removed", good[:len(good)-8]},
		{"unknown version", mutate(good, func(b []byte) { b[0] = 0xFE })},
		{"flipped wrapped key", mutate(good, func(b []byte) { b[envelopeHeaderBytes+1] ^= 0x01 })},
		{"flipped body", mutate(good, func(b []byte) { b[len(b)-1] ^= 0x01 })},
		{"zero wrapped length", mutate(good, func(b []byte) { b[1], b[2] = 0, 0 })},
		{"overlong wrapped length", mutate(good, func(b []byte) { b[1], b[2] = 0xFF, 0xFF })},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out, err := e.DecryptEnvelope(tc.input, aad)
			if err == nil {
				t.Fatalf("tampered envelope %q was accepted, returning %q", tc.name, string(out))
			}
			// Every rejection path must report the same error class. If header faults returned
			// ErrInvalidEnvelope and body faults returned ErrInvalidCiphertext, a caller checking
			// only one would miss the other — and body tampering is the likelier attack.
			if !errors.Is(err, ErrInvalidEnvelope) {
				t.Fatalf("case %q returned %v; every envelope rejection must be ErrInvalidEnvelope", tc.name, err)
			}
			if out != nil {
				t.Fatalf("a rejected envelope must return nil plaintext, got %q", string(out))
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Never-merge invariant across the pseudonymisation change
// ---------------------------------------------------------------------------

// TestAliasNeverMerge_StillEnforcedAfterPseudonymisation proves the invariant survives the change.
//
// The SQL trigger check_never_merge_alias() compared NEW.alias_value against delegation actor IDs.
// Migration 005 stops writing cleartext there, so that comparison can no longer match. This test
// asserts the invariant is still enforced against the same inputs — via the in-memory repository,
// whose Go-layer check is the same logic PostgresRepository.assertNeverMergeAlias now performs.
func TestAliasNeverMerge_StillEnforcedAfterPseudonymisation(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepositoryWithTenant(NewNoopEncryptor(), "tenant-a")
	now := time.Now().UTC()

	for _, id := range []string{"actor-delegate", "actor-principal"} {
		if err := repo.CreateActor(ctx, ActorRecord{ActorID: id, CreatedAt: now, UpdatedAt: now}); err != nil {
			t.Fatalf("CreateActor(%s): %v", id, err)
		}
	}
	if err := repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "actor-delegate",
		PrincipalActorID: "actor-principal",
		AuthzRef:         "grant-1",
		ValidFrom:        now,
		CreatedAt:        now,
	}); err != nil {
		t.Fatalf("AddDelegation: %v", err)
	}

	err := repo.AddAlias(ctx, AliasRecord{
		ActorID:    "actor-delegate",
		AliasType:  "actor",
		AliasValue: "actor-principal",
		ValidFrom:  now,
		CreatedAt:  now,
	})
	if !errors.Is(err, ErrNeverMergeViolation) {
		t.Fatalf("aliasing a delegate to its principal must violate never-merge, got %v", err)
	}
}

// TestAliasAAD_NoWritePathMutatesBoundColumns pins an invariant the envelope now depends on.
//
// AliasEnvelopeAAD binds each ciphertext to (actor_id, alias_type, pseudonym). That makes
// cross-row substitution fail, which is the point — but it also means that if any future code path
// UPDATEs aliases.actor_id or aliases.alias_type, the existing ciphertext in that row becomes
// permanently undecryptable. This is an identity GRAPH whose purpose includes relating actors, so
// a re-parenting path is a plausible future addition.
//
// No such path exists today. This test is what makes that a checked invariant rather than a
// coincidence: it fails the moment someone adds one, pointing them at the re-encryption they owe.
func TestAliasAAD_NoWritePathMutatesBoundColumns(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatalf("glob: %v", err)
	}

	// Matches an UPDATE on aliases that assigns one of the AAD-bound columns.
	suspect := regexp.MustCompile(`(?is)UPDATE\s+aliases\s+SET\s+[^;'` + "`" + `]*\b(actor_id|alias_type)\s*=`)

	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		body, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("read %s: %v", f, err)
		}
		if loc := suspect.FindIndex(body); loc != nil {
			t.Errorf("%s contains an UPDATE that reassigns an AAD-bound alias column:\n\t%s\n"+
				"Changing actor_id or alias_type invalidates AliasEnvelopeAAD for that row and makes "+
				"alias_value_encrypted permanently undecryptable. Re-encrypt the value in the same "+
				"statement, or drop the column from the AAD and document why.",
				f, strings.TrimSpace(string(body[loc[0]:min(loc[1]+40, len(body))])))
		}
	}
}

// TestAliasLookup_MatchesOnPseudonymNotCleartext pins that resolution no longer depends on a
// cleartext comparison. If someone reinstates an `alias_value == aliasValue` disjunct, a lookup
// under the wrong tenant would start succeeding and this test would fail.
func TestAliasLookup_MatchesOnPseudonymNotCleartext(t *testing.T) {
	ctx := context.Background()
	enc := NewNoopEncryptor()
	now := time.Now().UTC()

	repoA := NewMemoryRepositoryWithTenant(enc, "tenant-a")
	if err := repoA.CreateActor(ctx, ActorRecord{ActorID: "actor-1", CreatedAt: now, UpdatedAt: now}); err != nil {
		t.Fatalf("CreateActor: %v", err)
	}
	if err := repoA.AddAlias(ctx, AliasRecord{
		ActorID: "actor-1", AliasType: "email", AliasValue: "alice@corp.internal",
		ValidFrom: now.Add(-time.Hour), CreatedAt: now,
	}); err != nil {
		t.Fatalf("AddAlias: %v", err)
	}

	found, err := repoA.FindAliasesAsOf(ctx, "alice@corp.internal", now)
	if err != nil {
		t.Fatalf("FindAliasesAsOf: %v", err)
	}
	if len(found) != 1 {
		t.Fatalf("expected 1 alias under the writing tenant, got %d", len(found))
	}
	if !IsPseudonym(found[0].AliasValueHash) {
		t.Fatalf("stored digest %q is not a well-formed pseudonym", found[0].AliasValueHash)
	}

	// The same repository state read under a different tenant scope must not resolve, because the
	// pseudonym is scope-bound. A surviving cleartext comparison would return the row anyway.
	repoB := NewMemoryRepositoryWithTenant(enc, "tenant-b")
	repoB.aliases = repoA.aliases
	crossTenant, err := repoB.FindAliasesAsOf(ctx, "alice@corp.internal", now)
	if err != nil {
		t.Fatalf("cross-tenant FindAliasesAsOf: %v", err)
	}
	if len(crossTenant) != 0 {
		t.Fatalf("a lookup under tenant-b resolved %d of tenant-a's aliases; the match is not scope-bound", len(crossTenant))
	}
}
