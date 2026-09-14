// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package subjectkey

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"
)

// fakePseudonymiser maps a cleartext subject to a stable 64-hex pseudonym.
//
// It is NOT a pass-through. A pass-through would let every test pass while the saga journalled
// cleartext subject identifiers, which is the defect the pseudonymiser exists to prevent, so the
// fake produces a value that is visibly not the input.
type fakePseudonymiser struct {
	err error
}

func (f fakePseudonymiser) Pseudonym(tenantID, value string) (string, error) {
	if f.err != nil {
		return "", f.err
	}
	if tenantID == "" || value == "" {
		return "", errors.New("fake pseudonymiser: tenant and value are required")
	}
	return pseudo(tenantID + ":" + value), nil
}

// fixedClock returns a deterministic, monotonically advancing clock. Determinism matters here: a
// receipt digest that depended on wall-clock timing would produce a flaky test rather than a failing
// one, and a flaky idempotency test is worse than none.
func fixedClock() func() time.Time {
	base := time.Date(2026, 9, 14, 12, 0, 0, 0, time.UTC)
	var mu sync.Mutex
	n := 0
	return func() time.Time {
		mu.Lock()
		defer mu.Unlock()
		n++
		return base.Add(time.Duration(n) * time.Second)
	}
}

type harness struct {
	t      *testing.T
	h      *Hierarchy
	store  *MemoryStore
	cache  *PlaintextDEKCache
	saga   *Saga
	faults FaultInjector
}

func newHarness(t *testing.T, faults FaultInjector) *harness {
	t.Helper()
	h := testHierarchy(t)
	store := NewMemoryStore()
	cache := NewPlaintextDEKCache()
	s, err := NewSaga(SagaConfig{
		Hierarchy:       h,
		Store:           store,
		Cache:           cache,
		Pseudonymiser:   fakePseudonymiser{},
		StorageResidual: StorageResidualNone,
		Now:             fixedClock(),
		Faults:          faults,
	})
	if err != nil {
		t.Fatalf("NewSaga: %v", err)
	}
	return &harness{t: t, h: h, store: store, cache: cache, saga: s, faults: faults}
}

// provision mints n key versions for a subject and caches each plaintext DEK.
//
// Populating the cache is not incidental. A purge assertion against a cache that was never populated
// passes whether or not the purge works — the failure mode SLDP-P4-PRE §4.1 names explicitly — so
// every erasure test in this file starts with live cache entries.
func (x *harness) provision(tenantID, subject string, n int) (string, []KeyScope) {
	x.t.Helper()
	p, err := fakePseudonymiser{}.Pseudonym(tenantID, subject)
	if err != nil {
		x.t.Fatalf("pseudonym: %v", err)
	}
	var scopes []KeyScope
	for i := 0; i < n; i++ {
		rec, err := x.store.Provision(context.Background(), tenantID, p, 0, func(sc KeyScope) ([]byte, error) {
			dek, err := NewDEK()
			if err != nil {
				return nil, err
			}
			x.cache.Put(sc, dek)
			return x.h.WrapDEK(sc, dek)
		}, time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC))
		if err != nil {
			x.t.Fatalf("provision: %v", err)
		}
		scopes = append(scopes, rec.Scope())
	}
	return p, scopes
}

// canUnwrap reports whether a subject's live key material still opens.
func (x *harness) canUnwrap(tenantID, pseudonym string) bool {
	recs, err := x.store.ListVersions(context.Background(), tenantID, pseudonym)
	if err != nil || len(recs) == 0 {
		return false
	}
	for _, r := range recs {
		if _, err := x.h.UnwrapDEK(r.Scope(), r.WrappedDEK); err == nil {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------------------------
// The load-bearing test: erasing one subject leaves every other subject readable.
// ---------------------------------------------------------------------------------------------

// ISC-130, ISC-131: single-subject erasure.
//
// This is the test the entire card exists to make passable. Before the per-subject hierarchy there
// was one global key, so this test could only pass by erasing nothing or everything.
func TestErasureSaga_ErasesOneSubjectOnly(t *testing.T) {
	x := newHarness(t, nil)
	ctx := context.Background()

	targetP, _ := x.provision("t1", "alice", 2)
	neighbourP, _ := x.provision("t1", "bob", 2)
	crossTenantP, _ := x.provision("t2", "alice", 1)

	if !x.canUnwrap("t1", targetP) || !x.canUnwrap("t1", neighbourP) || !x.canUnwrap("t2", crossTenantP) {
		t.Fatal("precondition: all three subjects must start readable, or the postcondition proves nothing")
	}

	receipt, err := x.saga.Erase(ctx, "t1", "alice")
	if err != nil {
		t.Fatalf("Erase: %v", err)
	}
	if len(receipt.Versions) != 2 {
		t.Fatalf("receipt covers %d versions, expected 2", len(receipt.Versions))
	}

	if x.canUnwrap("t1", targetP) {
		t.Fatal("the erased subject's key still unwraps")
	}
	// The discriminating observations. Without these, "the target failed to unwrap" is equally
	// consistent with a broken key path, and the test would pass for the wrong reason.
	if !x.canUnwrap("t1", neighbourP) {
		t.Fatal("a NEIGHBOUR in the same tenant lost access; the erasure was not per-subject")
	}
	if !x.canUnwrap("t2", crossTenantP) {
		t.Fatal("the same subject name in ANOTHER tenant lost access; tenant scoping failed")
	}

	// ISC-100, ISC-103: the subject's plaintext cache is empty; the neighbour's is not.
	if remaining := x.cache.SubjectKeys("t1", targetP); len(remaining) != 0 {
		t.Fatalf("plaintext DEK cache still holds %d entries for the erased subject: %v", len(remaining), remaining)
	}
	if len(x.cache.SubjectKeys("t1", neighbourP)) == 0 {
		t.Fatal("the neighbour's cached keys were purged too; PurgeSubject is not subject-scoped")
	}

	// ISC-115, ISC-116: the residue is named rather than claimed away.
	if receipt.ResidualPseudonym != ResidualUnresolvableToken {
		t.Fatalf("residual pseudonym disposition is %q", receipt.ResidualPseudonym)
	}
	if receipt.StorageResidual == "" || receipt.ComplianceNote == "" {
		t.Fatal("the receipt omits the storage residual or the compliance note")
	}
}

// ISC-119..ISC-126: the destruction proof, and what makes it a proof.
func TestErasureSaga_DestructionProofRequiresAControl(t *testing.T) {
	x := newHarness(t, nil)
	ctx := context.Background()
	targetP, _ := x.provision("t1", "alice", 2)
	controlP, _ := x.provision("t1", "bob", 1)

	receipt, err := x.saga.Erase(ctx, "t1", "alice")
	if err != nil {
		t.Fatalf("Erase: %v", err)
	}
	priors := map[int]string{}
	for _, v := range receipt.Versions {
		priors[v.KeyVersion] = v.PriorWrappedDigest
	}

	proof, err := x.saga.VerifyDestroyed(ctx, "t1", targetP, controlP, priors)
	if err != nil {
		t.Fatalf("VerifyDestroyed: %v", err)
	}
	if proof.Verdict != VerdictDestroyed {
		t.Fatalf("verdict is %q, expected %q", proof.Verdict, VerdictDestroyed)
	}
	if len(proof.Versions) != 2 {
		t.Fatalf("proof covers %d versions", len(proof.Versions))
	}
	for _, v := range proof.Versions {
		if !v.RowPresent {
			t.Errorf("version %d: the row is gone; absence is not evidence of destruction", v.KeyVersion)
		}
		if !v.UnwrapAttempted {
			t.Errorf("version %d: the proof never attempted an unwrap; it inferred from the flag", v.KeyVersion)
		}
		if !v.UnwrapFailed {
			t.Errorf("version %d: the key still unwraps", v.KeyVersion)
		}
		if !v.StoredBytesDiffer {
			t.Errorf("version %d: the stored bytes still match the pre-destruction digest; it is flagged, not overwritten", v.KeyVersion)
		}
		if !v.DestroyedAtSet {
			t.Errorf("version %d: destroyed_at is unset", v.KeyVersion)
		}
	}
	if !proof.Control.UnwrapSucceeded {
		t.Fatal("the control did not unwrap, so the target's failure proves nothing")
	}

	// No control supplied: the verdict must NOT be a pass. This is the case that distinguishes
	// "destroyed" from "the key path is broken", and reporting it as success would be the single
	// most dangerous wrong answer this package could give.
	noControl, err := x.saga.VerifyDestroyed(ctx, "t1", targetP, "", priors)
	if err == nil {
		t.Fatal("VerifyDestroyed with no control returned no error")
	}
	if noControl.Verdict == VerdictDestroyed {
		t.Fatal("a proof with no control reported 'destroyed'")
	}
	if noControl.Verdict != VerdictControlUnavailable {
		t.Fatalf("verdict is %q, expected %q", noControl.Verdict, VerdictControlUnavailable)
	}

	// Control present but itself broken (a subject with no keys). Must be inconclusive, not a pass.
	broken, err := x.saga.VerifyDestroyed(ctx, "t1", targetP, pseudo("nobody"), priors)
	if err == nil || broken.Verdict == VerdictDestroyed {
		t.Fatalf("a proof whose control has no keys reported %q", broken.Verdict)
	}

	// A LIVE subject must be reported live, so the proof is not a rubber stamp.
	live, err := x.saga.VerifyDestroyed(ctx, "t1", controlP, controlP, nil)
	if err == nil {
		t.Fatal("VerifyDestroyed on a live subject returned success")
	}
	if live.Verdict != VerdictLive {
		t.Fatalf("a live subject got verdict %q, expected %q", live.Verdict, VerdictLive)
	}
}

// ---------------------------------------------------------------------------------------------
// Idempotency.
// ---------------------------------------------------------------------------------------------

// ISC-46, ISC-57..ISC-60, ISC-118: a repeat erasure is the same operation, not a second one.
func TestErasureSaga_IsIdempotent(t *testing.T) {
	x := newHarness(t, nil)
	ctx := context.Background()
	x.provision("t1", "alice", 3)

	first, err := x.saga.Erase(ctx, "t1", "alice")
	if err != nil {
		t.Fatalf("first Erase: %v", err)
	}
	firstDigest, err := first.Digest()
	if err != nil {
		t.Fatalf("digest: %v", err)
	}

	// The clock advances between the two calls. If ANY digest input were stamped from time.Now() at
	// receipt-construction time, these digests would differ — which is precisely how a resumed saga
	// would silently disagree with a tombstone SLDP-P4-2 had already published.
	second, err := x.saga.Erase(ctx, "t1", "alice")
	if err != nil {
		t.Fatalf("second Erase: %v", err)
	}
	secondDigest, err := second.Digest()
	if err != nil {
		t.Fatalf("digest: %v", err)
	}

	if firstDigest != secondDigest {
		t.Fatalf("receipt digest changed on re-run:\n  first:  %s\n  second: %s", firstDigest, secondDigest)
	}
	if !first.CompletedAt.Equal(second.CompletedAt) {
		t.Fatalf("completed_at moved on re-run: %s vs %s", first.CompletedAt, second.CompletedAt)
	}
	if first.OperationID != second.OperationID {
		t.Fatal("a repeat erasure produced a DIFFERENT operation id; it would emit a second tombstone")
	}
	if first.Nonce != second.Nonce {
		t.Fatal("the receipt nonce was re-minted on re-run")
	}
	for i := range first.Versions {
		if !first.Versions[i].DestroyedAt.Equal(second.Versions[i].DestroyedAt) {
			t.Fatalf("version %d destroyed_at moved on re-run", first.Versions[i].KeyVersion)
		}
	}

	// ISC-58: the privacy-facing receipt reports the same destruction, not a second one.
	r1, err := x.saga.DestroySubjectKeys(ctx, "t1", "alice")
	if err != nil {
		t.Fatalf("DestroySubjectKeys: %v", err)
	}
	if r1.ReceiptDigest != firstDigest {
		t.Fatalf("privacy receipt digest %s disagrees with %s", r1.ReceiptDigest, firstDigest)
	}
	if r1.OperationID == "" || r1.ReceiptSchema != ReceiptSchema {
		t.Fatal("the privacy receipt omits the fields SLDP-P4-2 needs")
	}
}

// ISC-43, ISC-44, ISC-45: operation IDs are deterministic, keyed and scope-separated.
func TestErasureSaga_OperationIDIsDeterministicAndKeyed(t *testing.T) {
	x := newHarness(t, nil)
	p := pseudo("alice")

	a, err := x.saga.OperationID("t1", p)
	if err != nil {
		t.Fatalf("OperationID: %v", err)
	}
	b, _ := x.saga.OperationID("t1", p)
	if a != b {
		t.Fatal("operation id is not deterministic")
	}
	if len(a) != 64 {
		t.Fatalf("operation id is %d chars, expected 64 hex", len(a))
	}

	other, _ := x.saga.OperationID("t2", p)
	if a == other {
		t.Fatal("the same subject in two tenants produced one operation id")
	}

	// Keyed, not a bare digest: a different master key must produce a different id for identical
	// inputs. An unkeyed SHA-256(tenant||pseudonym) would be identical here, and would let anyone
	// holding a candidate pseudonym confirm it against a published operation id.
	h2, err := NewHierarchy([]byte("ffffffffffffffffffffffffffffffff"))
	if err != nil {
		t.Fatalf("NewHierarchy: %v", err)
	}
	s2, err := NewSaga(SagaConfig{
		Hierarchy: h2, Store: NewMemoryStore(), Cache: NewPlaintextDEKCache(),
		Pseudonymiser: fakePseudonymiser{}, StorageResidual: StorageResidualNone,
	})
	if err != nil {
		t.Fatalf("NewSaga: %v", err)
	}
	c, _ := s2.OperationID("t1", p)
	if a == c {
		t.Fatal("the operation id is independent of the key; it is an unkeyed digest of the subject")
	}
}

// ISC-61, ISC-62: concurrent erasure of one subject destroys once.
func TestErasureSaga_ConcurrentInvocationsDestroyOnce(t *testing.T) {
	x := newHarness(t, nil)
	ctx := context.Background()
	p, _ := x.provision("t1", "alice", 2)

	const n = 8
	var wg sync.WaitGroup
	digests := make([]string, n)
	errs := make([]error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			r, err := x.saga.Erase(ctx, "t1", "alice")
			if err != nil {
				errs[i] = err
				return
			}
			digests[i], errs[i] = r.Digest()
		}(i)
	}
	wg.Wait()

	// Losers of the compare-and-swap race are EXPECTED — that is the mechanism working. What must
	// not happen is two different receipts, or a success whose digest disagrees.
	var successes []string
	for i := range digests {
		if errs[i] == nil {
			successes = append(successes, digests[i])
		} else if !errors.Is(errs[i], ErrStateConflict) {
			t.Errorf("goroutine %d failed with an unexpected error: %v", i, errs[i])
		}
	}
	if len(successes) == 0 {
		t.Fatal("every concurrent invocation failed; the saga cannot complete under contention")
	}
	for _, d := range successes[1:] {
		if d != successes[0] {
			t.Fatalf("concurrent invocations produced DIFFERENT receipt digests: %s vs %s", successes[0], d)
		}
	}

	recs, _ := x.store.ListVersions(ctx, "t1", p)
	stamps := map[string]struct{}{}
	for _, r := range recs {
		if r.DestroyedAt == nil {
			t.Fatalf("version %d survived a completed erasure", r.KeyVersion)
		}
		stamps[fmt.Sprintf("%d:%s", r.KeyVersion, r.DestroyedAt.Format(time.RFC3339Nano))] = struct{}{}
	}
	if len(stamps) != len(recs) {
		t.Fatal("a version was destroyed twice with different timestamps")
	}
}

// ISC-63, ISC-64: a subject with no keys still gets a journalled receipt.
func TestErasureSaga_ZeroVersionSubjectIsStillJournalled(t *testing.T) {
	x := newHarness(t, nil)
	ctx := context.Background()
	receipt, err := x.saga.Erase(ctx, "t1", "ghost")
	if err != nil {
		t.Fatalf("Erase on a keyless subject: %v", err)
	}
	if len(receipt.Versions) != 0 {
		t.Fatalf("receipt covers %d versions for a keyless subject", len(receipt.Versions))
	}
	saga, err := x.store.LoadSaga(ctx, receipt.OperationID)
	if err != nil {
		t.Fatalf("the erasure was not journalled: %v", err)
	}
	if saga.State != StateCompleted {
		t.Fatalf("saga state is %q", saga.State)
	}
	if saga.ReceiptDigest == "" {
		t.Fatal("a completed saga carries no receipt digest")
	}
}

// ISC-65..ISC-69: the saga refuses rather than degrading.
func TestErasureSaga_RefusesRatherThanDegrading(t *testing.T) {
	x := newHarness(t, nil)
	ctx := context.Background()

	if _, err := x.saga.Erase(ctx, "", "alice"); err == nil {
		t.Error("an empty tenant was accepted")
	}
	if _, err := x.saga.Erase(ctx, "t1", ""); err == nil {
		t.Error("an empty subject was accepted")
	}

	// A pseudonymiser failure must abort BEFORE anything is destroyed.
	h := testHierarchy(t)
	store := NewMemoryStore()
	bad, err := NewSaga(SagaConfig{
		Hierarchy: h, Store: store, Cache: NewPlaintextDEKCache(),
		Pseudonymiser:   fakePseudonymiser{err: errors.New("keyring unavailable")},
		StorageResidual: StorageResidualNone,
	})
	if err != nil {
		t.Fatalf("NewSaga: %v", err)
	}
	if _, err := bad.Erase(ctx, "t1", "alice"); err == nil {
		t.Error("a pseudonymiser failure did not abort the saga")
	}

	// Every nil dependency is refused. A nil store that read as "no keys" would report every
	// erasure successful while destroying nothing.
	for name, cfg := range map[string]SagaConfig{
		"nil hierarchy":     {Store: store, Cache: NewPlaintextDEKCache(), Pseudonymiser: fakePseudonymiser{}, StorageResidual: StorageResidualNone},
		"nil store":         {Hierarchy: h, Cache: NewPlaintextDEKCache(), Pseudonymiser: fakePseudonymiser{}, StorageResidual: StorageResidualNone},
		"nil cache":         {Hierarchy: h, Store: store, Pseudonymiser: fakePseudonymiser{}, StorageResidual: StorageResidualNone},
		"nil pseudonymiser": {Hierarchy: h, Store: store, Cache: NewPlaintextDEKCache(), StorageResidual: StorageResidualNone},
		"unstated residual": {Hierarchy: h, Store: store, Cache: NewPlaintextDEKCache(), Pseudonymiser: fakePseudonymiser{}},
	} {
		if _, err := NewSaga(cfg); err == nil {
			t.Errorf("NewSaga accepted a config with %s", name)
		}
	}
}

// ISC-52: the state ladder refuses a skip.
func TestErasureSaga_StateLadderRefusesSkips(t *testing.T) {
	ctx := context.Background()
	store := NewMemoryStore()
	rec := SagaRecord{
		OperationID: pseudo("op"), TenantID: "t1", SubjectPseudonym: pseudo("alice"),
		Nonce: pseudo("nonce"), StartedAt: time.Now(),
	}
	if _, _, err := store.BeginSaga(ctx, rec); err != nil {
		t.Fatalf("BeginSaga: %v", err)
	}
	// Advancing from a state the row is not in must be refused, not silently applied.
	if _, err := store.AdvanceSaga(ctx, rec.OperationID, StateCachesCleared, nil); !errors.Is(err, ErrStateConflict) {
		t.Fatalf("advancing from the wrong state returned %v, expected ErrStateConflict", err)
	}
	// Advancing from the terminal state has no successor.
	if _, err := store.AdvanceSaga(ctx, rec.OperationID, StateCompleted, nil); !errors.Is(err, ErrIllegalTransition) {
		t.Fatalf("advancing past the terminal state returned %v, expected ErrIllegalTransition", err)
	}
	// Every legal step must be exactly one forward.
	for i := 0; i < len(SagaStates)-1; i++ {
		next, ok := NextState(SagaStates[i])
		if !ok || next != SagaStates[i+1] {
			t.Fatalf("NextState(%q) = %q, expected %q", SagaStates[i], next, SagaStates[i+1])
		}
	}
}

// ISC-54: a version provisioned after the snapshot is not silently missed.
func TestErasureSaga_VersionDriftIsNotSilentlyMissed(t *testing.T) {
	ctx := context.Background()

	// 54.1 — drift while still pending WIDENS the target set rather than refusing, because refusing
	// would leave the new key live forever: the operation id is deterministic, so a re-issued request
	// resolves to this same stuck saga.
	x := newHarness(t, nil)
	p, _ := x.provision("t1", "alice", 1)
	opID, _ := x.saga.OperationID("t1", p)
	if _, _, err := x.store.BeginSaga(ctx, SagaRecord{
		OperationID: opID, TenantID: "t1", SubjectPseudonym: p,
		TargetVersions: []int{1}, Nonce: pseudo("n"), StartedAt: time.Now(),
	}); err != nil {
		t.Fatalf("pre-seed saga: %v", err)
	}
	x.provision("t1", "alice", 1) // version 2 appears after the snapshot
	receipt, err := x.saga.Erase(ctx, "t1", "alice")
	if err != nil {
		t.Fatalf("Erase after pending-state drift: %v", err)
	}
	if len(receipt.Versions) != 2 {
		t.Fatalf("the widened target set covered %d versions, expected 2; the late version was missed", len(receipt.Versions))
	}
	if x.canUnwrap("t1", p) {
		t.Fatal("a version provisioned after the snapshot survived the erasure")
	}

	// 54.2 — drift AFTER certification must refuse loudly. The saga has already certified "every
	// targeted version is destroyed" and that statement is now false.
	y := newHarness(t, nil)
	py, _ := y.provision("t2", "carol", 1)
	opID2, _ := y.saga.OperationID("t2", py)
	if _, _, err := y.store.BeginSaga(ctx, SagaRecord{
		OperationID: opID2, TenantID: "t2", SubjectPseudonym: py,
		TargetVersions: []int{1}, Nonce: pseudo("n"), StartedAt: time.Now(),
	}); err != nil {
		t.Fatalf("pre-seed saga: %v", err)
	}
	if _, err := y.store.AdvanceSaga(ctx, opID2, StatePending, nil); err != nil {
		t.Fatalf("advance to keys_destroyed: %v", err)
	}
	y.provision("t2", "carol", 1)
	if _, err := y.saga.Erase(ctx, "t2", "carol"); !errors.Is(err, ErrVersionDrift) {
		t.Fatalf("post-certification drift returned %v, expected ErrVersionDrift", err)
	}
}

// ISC-97, ISC-98, ISC-99, ISC-104: the cache emptiness assertion is a real probe.
func TestErasureSaga_CacheAssertionIsNotVacuous(t *testing.T) {
	ctx := context.Background()
	x := newHarness(t, nil)
	_, scopes := x.provision("t1", "alice", 2)

	if x.cache.Len() == 0 {
		t.Fatal("the cache was never populated, so the purge assertion below would pass vacuously")
	}
	if _, err := x.saga.Erase(ctx, "t1", "alice"); err != nil {
		t.Fatalf("Erase: %v", err)
	}
	for _, sc := range scopes {
		if _, ok := x.cache.Get(sc); ok {
			t.Fatalf("version %d's plaintext DEK survived erasure; the shredding is cosmetic", sc.KeyVersion)
		}
	}

	// Falsify the probe itself. SubjectKeys is what the saga's emptiness assertion reads, and a
	// SubjectKeys that could never see an entry would report every cache empty — passing whether or
	// not the purge worked. So: insert, confirm it is VISIBLE, purge, confirm it is gone.
	y := newHarness(t, nil)
	py, _ := y.provision("t1", "dave", 1)
	y.cache.Put(KeyScope{TenantID: "t1", SubjectPseudonym: py, KeyVersion: 99}, []byte("live-key-material"))
	if got := y.cache.SubjectKeys("t1", py); len(got) == 0 {
		t.Fatal("SubjectKeys cannot see an entry that is present; the saga's emptiness assertion is blind and always passes")
	}
	if n := y.cache.PurgeSubject("t1", py); n == 0 {
		t.Fatal("PurgeSubject removed nothing from a populated cache")
	}
	if got := y.cache.SubjectKeys("t1", py); len(got) != 0 {
		t.Fatalf("PurgeSubject left %v behind", got)
	}

	// ISC-104: an entry added DURING the saga, before the purge runs, is still caught.
	z := newHarness(t, nil)
	pz, _ := z.provision("t1", "erin", 1)
	z.saga.faults = func(fp FaultPoint) error {
		if fp == FaultBeforeCacheClear {
			z.cache.Put(KeyScope{TenantID: "t1", SubjectPseudonym: pz, KeyVersion: 99}, []byte("late-arrival"))
		}
		return nil
	}
	if _, err := z.saga.Erase(ctx, "t1", "erin"); err != nil {
		t.Fatalf("Erase: %v", err)
	}
	if got := z.cache.SubjectKeys("t1", pz); len(got) != 0 {
		t.Fatalf("an entry added during the saga survived: %v", got)
	}

	// What this file does NOT claim, stated so nobody reads more into the coverage than is there.
	// PurgeSubject and SubjectKeys share one prefix predicate by construction, so no entry can be
	// invisible to the purge and visible to the assertion — which means the ErrCacheNotEmpty arm of
	// Erase is unreachable through this cache implementation and is therefore NOT covered here. It
	// exists for a future cache whose eviction and enumeration diverge (an LRU with a background
	// evictor, a shared cache with another writer), and the falsification above is what keeps the
	// shared predicate honest in the meantime.
	if !errors.Is(ErrCacheNotEmpty, ErrCacheNotEmpty) {
		t.Fatal("unreachable")
	}
}

// ISC-101, ISC-102: the cache registry covers every cache SLDP-P4-PRE enumerated.
func TestErasureSaga_CacheRegistryCoversPreflightInventory(t *testing.T) {
	// The inventory from SLDP-P4-PRE §4, transcribed. Each entry must appear in CacheRegistry with a
	// stated disposition — an unlisted cache is a cache nobody cleared and nobody noticed.
	required := []CacheName{
		CachePlaintextDEK,
		CacheTenantKEKDerivation,
		CachePseudonymKeyRing,
		CacheSegmentPseudonymiser,
		CacheIdentityEncryptorRoot,
		CacheSecretScrubberSalt,
	}
	have := map[CacheName]CacheDisposition{}
	for _, c := range CacheRegistry {
		if c.Reason == "" {
			t.Errorf("cache %q has no stated reason", c.Name)
		}
		have[c.Name] = c
	}
	for _, r := range required {
		if _, ok := have[r]; !ok {
			t.Errorf("cache %q from the SLDP-P4-PRE inventory is absent from CacheRegistry", r)
		}
	}
	cleared := ClearedCacheNames()
	if len(cleared) != 1 || cleared[0] != string(CachePlaintextDEK) {
		t.Fatalf("cleared caches are %v; exactly the plaintext DEK cache should be cleared by a per-subject erasure", cleared)
	}
}

// ISC-132, ISC-133, ISC-134: the version history is bounded.
func TestErasureSaga_KeyVersionHistoryIsBounded(t *testing.T) {
	ctx := context.Background()
	x := newHarness(t, nil)
	p, _ := x.provision("t1", "alice", MaxKeyVersionsPerSubject+3)

	recs, err := x.store.ListVersions(ctx, "t1", p)
	if err != nil {
		t.Fatalf("ListVersions: %v", err)
	}
	live := 0
	for _, r := range recs {
		if !r.Destroyed() {
			live++
		}
	}
	if live > MaxKeyVersionsPerSubject {
		t.Fatalf("%d live versions exceed the bound of %d; the key history is itself a retention problem", live, MaxKeyVersionsPerSubject)
	}
	if len(recs) != MaxKeyVersionsPerSubject+3 {
		t.Fatalf("%d rows exist; surplus versions must be DESTROYED in place, not deleted", len(recs))
	}
	// The bound is enforced, not merely declared: the oldest versions are the destroyed ones.
	for i := 0; i < 3; i++ {
		if !recs[i].Destroyed() {
			t.Errorf("version %d is the oldest surplus and is still live", recs[i].KeyVersion)
		}
	}
}

// ISC-106..ISC-114: the receipt digest is canonical and sensitive to every field.
func TestErasureSaga_ReceiptDigestIsCanonicalAndSensitive(t *testing.T) {
	base := DestructionReceipt{
		Schema: ReceiptSchema, OperationID: pseudo("op"), TenantID: "t1",
		SubjectPseudonym: pseudo("alice"), Nonce: pseudo("nonce"),
		Versions: []DestroyedKeyVersion{
			{KeyVersion: 2, KeyEpoch: 0, PriorWrappedDigest: pseudo("d2"), DestroyedAt: time.Unix(2000, 0)},
			{KeyVersion: 1, KeyEpoch: 0, PriorWrappedDigest: pseudo("d1"), DestroyedAt: time.Unix(1000, 0)},
		},
		CachesPurged:      []string{"b", "a"},
		ResidualPseudonym: ResidualUnresolvableToken,
		StorageResidual:   StorageResidualNone,
		ComplianceNote:    ComplianceNote,
		CompletedAt:       time.Unix(3000, 0),
	}
	d0, err := base.Digest()
	if err != nil {
		t.Fatalf("Digest: %v", err)
	}

	// Order independence: the digest must not depend on store iteration order.
	reordered := base
	reordered.Versions = []DestroyedKeyVersion{base.Versions[1], base.Versions[0]}
	reordered.CachesPurged = []string{"a", "b"}
	if d, _ := reordered.Digest(); d != d0 {
		t.Fatal("the digest depends on slice order; two runs of the same erasure would disagree")
	}

	// Timezone independence: a receipt digested in one location must re-digest identically.
	tz := base
	loc, err := time.LoadLocation("Europe/London")
	if err == nil {
		tz.CompletedAt = base.CompletedAt.In(loc)
		if d, _ := tz.Digest(); d != d0 {
			t.Fatal("the digest depends on the reader's timezone")
		}
	}

	// Sensitivity: changing ANY field must change the digest, or the receipt could be altered
	// without the tombstone noticing.
	mutations := map[string]func(*DestructionReceipt){
		"schema":      func(r *DestructionReceipt) { r.Schema = "other/v2" },
		"operation":   func(r *DestructionReceipt) { r.OperationID = pseudo("other") },
		"tenant":      func(r *DestructionReceipt) { r.TenantID = "t2" },
		"subject":     func(r *DestructionReceipt) { r.SubjectPseudonym = pseudo("bob") },
		"nonce":       func(r *DestructionReceipt) { r.Nonce = pseudo("other") },
		"version num": func(r *DestructionReceipt) { r.Versions[0].KeyVersion = 9 },
		"epoch":       func(r *DestructionReceipt) { r.Versions[0].KeyEpoch = 1 },
		"prior":       func(r *DestructionReceipt) { r.Versions[0].PriorWrappedDigest = pseudo("x") },
		"destroyed":   func(r *DestructionReceipt) { r.Versions[0].DestroyedAt = time.Unix(2001, 0) },
		"caches":      func(r *DestructionReceipt) { r.CachesPurged = []string{"c"} },
		"residual":    func(r *DestructionReceipt) { r.StorageResidual = StorageResidualMVCCAndBackup },
		"compliance":  func(r *DestructionReceipt) { r.ComplianceNote = "everything is fine" },
		"completed":   func(r *DestructionReceipt) { r.CompletedAt = time.Unix(3001, 0) },
		"drop a version": func(r *DestructionReceipt) {
			r.Versions = r.Versions[:1]
		},
	}
	for name, mutate := range mutations {
		m := base
		m.Versions = append([]DestroyedKeyVersion(nil), base.Versions...)
		m.CachesPurged = append([]string(nil), base.CachesPurged...)
		mutate(&m)
		d, err := m.Digest()
		if err != nil {
			continue // an incomplete receipt legitimately refuses to digest
		}
		if d == d0 {
			t.Errorf("mutating %q did not change the digest", name)
		}
	}

	// A receipt missing a residual or compliance field must REFUSE to digest. An omitted residual
	// would read as "no residual", which is a claim this package must never make silently.
	for name, mutate := range map[string]func(*DestructionReceipt){
		"no residual":   func(r *DestructionReceipt) { r.ResidualPseudonym = "" },
		"no storage":    func(r *DestructionReceipt) { r.StorageResidual = "" },
		"no compliance": func(r *DestructionReceipt) { r.ComplianceNote = "" },
		"no nonce":      func(r *DestructionReceipt) { r.Nonce = "" },
		"no prior":      func(r *DestructionReceipt) { r.Versions[0].PriorWrappedDigest = "" },
		"zero time":     func(r *DestructionReceipt) { r.Versions[0].DestroyedAt = time.Time{} },
	} {
		m := base
		m.Versions = append([]DestroyedKeyVersion(nil), base.Versions...)
		mutate(&m)
		if _, err := m.Digest(); !errors.Is(err, ErrReceiptIncomplete) {
			t.Errorf("a receipt with %s digested successfully (err=%v)", name, err)
		}
	}
}

// ---------------------------------------------------------------------------------------------
// Gaps found by the mutation sweep (subjectkey/mutation-check.sh), added here rather than
// weakening the mutations. Each of these closes a guard that was previously unproven: M6 (the
// proof's inconclusive arm) and M8 (the saga's destruction certification).
// ---------------------------------------------------------------------------------------------

// lyingStore reports every destruction as successful while destroying nothing.
//
// It is the mechanised form of the failure the certification step exists for: a KMS or a database
// that returns 200 and does not act. Note the result it returns is PLAUSIBLE — a real digest and a
// real timestamp — because a stub whose failure value is obviously wrong tests nothing.
type lyingStore struct {
	*MemoryStore
}

func (l lyingStore) DestroyVersion(ctx context.Context, scope KeyScope, now time.Time) (DestroyResult, error) {
	rec, err := l.MemoryStore.GetVersion(ctx, scope)
	if err != nil {
		return DestroyResult{}, err
	}
	return DestroyResult{
		Scope:              scope,
		PriorWrappedDigest: WrappedDigest(rec.WrappedDEK),
		DestroyedAt:        now.UTC(),
	}, nil
}

// M8: the saga must CERTIFY by read-back, not trust the destroy calls' return values.
//
// Without certifyAllDestroyed the saga would advance to keys_destroyed, clear caches, record a
// receipt digest and report success — attesting to a destruction that never happened, with every
// other test in this file still green because in the happy path the destroy really does destroy.
func TestErasureSaga_CertifiesDestructionByReadBackNotByReturnValue(t *testing.T) {
	ctx := context.Background()
	inner := NewMemoryStore()
	h := testHierarchy(t)
	cache := NewPlaintextDEKCache()
	s, err := NewSaga(SagaConfig{
		Hierarchy: h, Store: lyingStore{inner}, Cache: cache,
		Pseudonymiser: fakePseudonymiser{}, StorageResidual: StorageResidualNone, Now: fixedClock(),
	})
	if err != nil {
		t.Fatalf("NewSaga: %v", err)
	}

	p, _ := fakePseudonymiser{}.Pseudonym("t1", "alice")
	if _, err := inner.Provision(ctx, "t1", p, 0, func(sc KeyScope) ([]byte, error) {
		dek, err := NewDEK()
		if err != nil {
			return nil, err
		}
		cache.Put(sc, dek)
		return h.WrapDEK(sc, dek)
	}, time.Now()); err != nil {
		t.Fatalf("provision: %v", err)
	}

	if _, err := s.Erase(ctx, "t1", "alice"); err == nil {
		t.Fatal("the saga reported success against a store that destroyed nothing; it trusted the " +
			"destroy call's return value instead of reading the key back")
	}

	// And the invariant holds through the failure: no receipt digest was recorded.
	opID, _ := s.OperationID("t1", p)
	saga, err := inner.LoadSaga(ctx, opID)
	if err != nil {
		t.Fatalf("LoadSaga: %v", err)
	}
	if saga.ReceiptDigest != "" {
		t.Fatalf("a receipt digest (%s) was recorded for a destruction that did not happen", saga.ReceiptDigest)
	}
	if saga.State != StatePending {
		t.Fatalf("the saga advanced to %q without certified destruction", saga.State)
	}
	recs, _ := inner.ListVersions(ctx, "t1", p)
	for _, r := range recs {
		if _, err := h.UnwrapDEK(r.Scope(), r.WrappedDEK); err != nil {
			t.Fatalf("version %d was actually destroyed; the lying store is not lying and this test "+
				"asserts nothing", r.KeyVersion)
		}
	}
}

// M6: target unwrap fails AND control unwrap fails must be INCONCLUSIVE, never a pass.
//
// This is the arm that distinguishes "the key was destroyed" from "the key path is broken". Both
// produce an identical error at the target. The previously-written proof test covered the
// no-control and no-control-keys cases, both of which return before the verdict switch — so the
// switch's inconclusive branch was unproven until the mutation sweep found it.
func TestErasureSaga_ProofIsInconclusiveWhenTheControlAlsoFails(t *testing.T) {
	ctx := context.Background()
	x := newHarness(t, nil)
	targetP, _ := x.provision("t1", "alice", 1)
	controlP, controlScopes := x.provision("t1", "bob", 1)

	receipt, err := x.saga.Erase(ctx, "t1", "alice")
	if err != nil {
		t.Fatalf("Erase: %v", err)
	}
	priors := map[int]string{}
	for _, v := range receipt.Versions {
		priors[v.KeyVersion] = v.PriorWrappedDigest
	}

	// Sanity: with a WORKING control this is a pass. Without this the test below could not tell a
	// correct inconclusive verdict from a proof that never passes anything.
	ok, err := x.saga.VerifyDestroyed(ctx, "t1", targetP, controlP, priors)
	if err != nil || ok.Verdict != VerdictDestroyed {
		t.Fatalf("precondition: a working control must yield %q, got %q (%v)", VerdictDestroyed, ok.Verdict, err)
	}

	// Now break the control's key material in place — the control still HAS a live, undestroyed row,
	// it simply no longer opens. That is exactly what a wrong master key or a corrupt store looks
	// like, and it must not be reported as a successful erasure of the target.
	rec := x.store.keys[cacheKey(controlScopes[0])]
	rec.WrappedDEK = TamperWrapped(rec.WrappedDEK)

	broken, err := x.saga.VerifyDestroyed(ctx, "t1", targetP, controlP, priors)
	if err == nil {
		t.Fatal("VerifyDestroyed returned success while the control could not unwrap")
	}
	if broken.Verdict == VerdictDestroyed {
		t.Fatal("a proof whose control ALSO failed reported 'destroyed'; the key path could be " +
			"entirely broken and this would read as a discharged compliance claim")
	}
	if broken.Verdict != VerdictInconclusive {
		t.Fatalf("verdict is %q, expected %q", broken.Verdict, VerdictInconclusive)
	}
	if broken.Control.UnwrapSucceeded {
		t.Fatal("the proof recorded a successful control unwrap that did not happen")
	}
	if broken.Control.UnwrapError == "" {
		t.Fatal("the proof does not record WHY the control failed; an operator cannot act on it")
	}
}

// M4: MemoryStore's repeat-destroy guard, which had no test until the mutation sweep found it.
//
// TestSubjectKeyPG_RepeatDestroyPreservesTheOriginalTimestamp covers the SQL half via the
// `destroyed_at IS NULL` predicate, and it is DSN-gated — so on a run without PostgreSQL the whole
// property was uncovered. The two stores share no code, so one test cannot stand in for the other.
func TestErasureSaga_MemoryStoreRepeatDestroyPreservesOriginalTimestamp(t *testing.T) {
	ctx := context.Background()
	x := newHarness(t, nil)
	p, scopes := x.provision("t1", "alice", 1)
	_ = p

	t1 := time.Date(2026, 9, 10, 10, 0, 0, 0, time.UTC)
	t2 := time.Date(2026, 9, 11, 10, 0, 0, 0, time.UTC)

	first, err := x.store.DestroyVersion(ctx, scopes[0], t1)
	if err != nil {
		t.Fatalf("first destroy: %v", err)
	}
	if first.AlreadyDestroyed {
		t.Fatal("the first destroy reported the version was already destroyed")
	}
	second, err := x.store.DestroyVersion(ctx, scopes[0], t2)
	if err != nil {
		t.Fatalf("repeat destroy: %v", err)
	}
	if !second.AlreadyDestroyed {
		t.Fatal("a repeat destroy did not report AlreadyDestroyed; it destroyed a second time")
	}
	if !first.DestroyedAt.Equal(second.DestroyedAt) {
		t.Fatalf("a repeat destroy moved destroyed_at from %s to %s; a resumed saga would rebuild a "+
			"different receipt and disagree with an already-published tombstone",
			first.DestroyedAt, second.DestroyedAt)
	}
	if first.PriorWrappedDigest != second.PriorWrappedDigest {
		t.Fatalf("a repeat destroy re-digested the OVERWRITE bytes (%s) instead of preserving the "+
			"pre-destruction digest (%s)", second.PriorWrappedDigest, first.PriorWrappedDigest)
	}

	// And the stored bytes really were replaced, not just flagged.
	rec, err := x.store.GetVersion(ctx, scopes[0])
	if err != nil {
		t.Fatalf("GetVersion: %v", err)
	}
	if WrappedDigest(rec.WrappedDEK) == first.PriorWrappedDigest {
		t.Fatal("the row still holds the pre-destruction bytes")
	}
	if !rec.DestroyedAt.Equal(t1.UTC()) {
		t.Fatalf("the durable destroyed_at is %s, expected the FIRST destruction at %s", rec.DestroyedAt, t1.UTC())
	}
}
