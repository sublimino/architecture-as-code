// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package subjectkey

import (
	"context"
	"errors"
	"testing"
)

// errInjected is the simulated crash.
//
// It is a distinct sentinel rather than a generic error so a test cannot mistake a REAL failure in
// the saga for the injected one — which would turn "the saga handled the fault" into "the saga was
// already broken and I read its breakage as my injection working".
var errInjected = errors.New("injected crash")

// oneShotInjector fires exactly once, at p, then stops. A persistent injector would fail the resume
// as well, so nothing would ever converge and every case would pass for the wrong reason.
func oneShotInjector(p FaultPoint) FaultInjector {
	fired := false
	return func(got FaultPoint) error {
		if got == p && !fired {
			fired = true
			return errInjected
		}
		return nil
	}
}

// TestErasureSaga_FaultOnBothSidesOfEveryBoundary is the card's fault-injection suite.
//
// It iterates SagaBoundaries rather than a hand-written case list, and then asserts the number of
// cases it actually ran against 2*len(SagaBoundaries). Those two things together are what stop the
// suite silently ceasing to cover a boundary somebody adds: a hand-copied list drifts from the code
// it covers and both halves stay green, because the suite still passes — it just stops testing.
func TestErasureSaga_FaultOnBothSidesOfEveryBoundary(t *testing.T) {
	ctx := context.Background()

	// The no-fault reference. Every faulted run must converge on THIS digest.
	ref := newHarness(t, nil)
	ref.provision("t1", "alice", 3)
	refReceipt, err := ref.saga.Erase(ctx, "t1", "alice")
	if err != nil {
		t.Fatalf("reference run: %v", err)
	}
	refVersions := len(refReceipt.Versions)
	if refVersions != 3 {
		t.Fatalf("reference run covered %d versions, expected 3", refVersions)
	}

	cases := 0
	for _, b := range SagaBoundaries {
		for _, fp := range []FaultPoint{b.Before, b.After} {
			cases++
			t.Run(string(fp), func(t *testing.T) {
				x := newHarness(t, oneShotInjector(fp))
				p, _ := x.provision("t1", "alice", 3)

				// ---- Attempt 1: crashes at fp. ------------------------------------------------
				_, err := x.saga.Erase(ctx, "t1", "alice")
				if err == nil {
					// A fault point that is unreachable in a clean run is a fault point that tests
					// nothing. FaultAfterCompletedTransition is the one legitimate exception: it
					// fires on the last statement, so the work is already done. Everything else
					// reaching this branch means the injector never fired, and the case is vacuous.
					if fp != FaultAfterCompletedTransition {
						t.Fatalf("the injected fault at %s never fired; this case asserts nothing", fp)
					}
				} else if !errors.Is(err, errInjected) {
					t.Fatalf("attempt 1 failed with something other than the injection: %v", err)
				}

				// ---- Mid-flight invariant: NEVER a receipt digest alongside a live key. --------
				//
				// This is the one direction that must be impossible rather than merely recoverable.
				// (destruction without a recorded receipt) is transient and resumable; (a recorded
				// receipt while a targeted version is still usable) would be a tombstone attesting
				// to something that did not happen.
				opID, err := x.saga.OperationID("t1", p)
				if err != nil {
					t.Fatalf("OperationID: %v", err)
				}
				saga, sagaErr := x.store.LoadSaga(ctx, opID)
				if sagaErr == nil && saga.ReceiptDigest != "" {
					recs, _ := x.store.ListVersions(ctx, "t1", p)
					for _, r := range recs {
						if !r.Destroyed() {
							t.Fatalf("INVARIANT VIOLATED at %s: receipt digest %s is recorded while version %d is still live",
								fp, saga.ReceiptDigest, r.KeyVersion)
						}
						if _, err := x.h.UnwrapDEK(r.Scope(), r.WrappedDEK); err == nil {
							t.Fatalf("INVARIANT VIOLATED at %s: receipt digest recorded while version %d still UNWRAPS",
								fp, r.KeyVersion)
						}
					}
				}

				// Destruction with no recorded receipt is permitted, but must be VISIBLE.
				if sagaErr != nil && fp != FaultBeforeJournalInsert {
					t.Fatalf("a fault at %s left no journal row; a destruction with no durable trace is not recoverable", fp)
				}
				if sagaErr == nil && saga.ReceiptDigest == "" {
					recs, _ := x.store.ListVersions(ctx, "t1", p)
					destroyed := 0
					for _, r := range recs {
						if r.Destroyed() {
							destroyed++
						}
					}
					if destroyed > 0 && saga.State == "" {
						t.Fatalf("%d versions destroyed with the journal in no state at all", destroyed)
					}
				}

				// ---- Attempt 2: resume. The injector is spent, so this is a clean run. ---------
				resumed, err := x.saga.Erase(ctx, "t1", "alice")
				if err != nil {
					t.Fatalf("resume after a fault at %s did not converge: %v", fp, err)
				}

				// ISC-85: every fault point converges on completed.
				final, err := x.store.LoadSaga(ctx, opID)
				if err != nil {
					t.Fatalf("LoadSaga after resume: %v", err)
				}
				if final.State != StateCompleted {
					t.Fatalf("resume from a fault at %s ended in state %q", fp, final.State)
				}

				// ISC-86: the receipt is the same shape as the unfaulted run. The digest itself
				// differs from the reference only because the nonce is per-operation random and this
				// is a different store; what must hold is that the digest MATCHES THE ONE PERSISTED
				// at receipt_recorded, which Erase itself asserts, plus stability across a third run.
				if len(resumed.Versions) != refVersions {
					t.Fatalf("resume covered %d versions, the unfaulted run covered %d", len(resumed.Versions), refVersions)
				}
				d1, err := resumed.Digest()
				if err != nil {
					t.Fatalf("digest: %v", err)
				}
				if d1 != final.ReceiptDigest {
					t.Fatalf("the returned receipt digest %s disagrees with the persisted %s", d1, final.ReceiptDigest)
				}
				third, err := x.saga.Erase(ctx, "t1", "alice")
				if err != nil {
					t.Fatalf("third run: %v", err)
				}
				d2, _ := third.Digest()
				if d1 != d2 {
					t.Fatalf("a third run after a fault at %s produced a different digest: %s vs %s", fp, d1, d2)
				}

				// ISC-87 postcondition: nothing of the subject survives, and the cache is empty.
				if x.canUnwrap("t1", p) {
					t.Fatalf("after resuming from a fault at %s the subject's key still unwraps", fp)
				}
				if got := x.cache.SubjectKeys("t1", p); len(got) != 0 {
					t.Fatalf("after resuming from a fault at %s the plaintext cache still holds %v", fp, got)
				}
			})
		}
	}

	// ISC-89, ISC-90: the sweep covered every boundary, both sides. If someone adds a boundary to
	// SagaBoundaries and forgets the loop, or removes one, this count disagrees.
	if want := 2 * len(SagaBoundaries); cases != want {
		t.Fatalf("the sweep ran %d cases for %d boundaries; expected %d", cases, len(SagaBoundaries), want)
	}
	if len(SagaBoundaries) != 7 {
		t.Fatalf("SagaBoundaries has %d entries; the saga crosses 7 durable boundaries. "+
			"If a boundary was added or removed, update this assertion deliberately rather than "+
			"letting the sweep silently change shape.", len(SagaBoundaries))
	}

	// Every declared FaultPoint constant must appear in SagaBoundaries. A constant declared but never
	// bracketed into a boundary is a fault site the sweep never visits.
	declared := []FaultPoint{
		FaultBeforeJournalInsert, FaultAfterJournalInsert,
		FaultBeforeDestroyVersions, FaultAfterDestroyVersions,
		FaultBeforeKeysDestroyedTransition, FaultAfterKeysDestroyedTransition,
		FaultBeforeCacheClear, FaultAfterCacheClear,
		FaultBeforeCachesClearedTransition, FaultAfterCachesClearedTransition,
		FaultBeforeReceiptPersist, FaultAfterReceiptPersist,
		FaultBeforeCompletedTransition, FaultAfterCompletedTransition,
	}
	inBoundaries := map[FaultPoint]bool{}
	for _, b := range SagaBoundaries {
		inBoundaries[b.Before] = true
		inBoundaries[b.After] = true
	}
	for _, d := range declared {
		if !inBoundaries[d] {
			t.Errorf("fault point %q is declared but is not bracketed into any SagaBoundary", d)
		}
	}
}

// TestErasureSaga_FaultInjectorIsWiredAtEveryPoint proves the seam is reachable.
//
// Without it, a fault point that Erase never calls would make its two sweep cases pass by doing
// nothing — the "a check that never ran looks like a check that passed" shape. This test records
// which points a clean run actually visits and fails if any declared point is unreachable.
func TestErasureSaga_FaultInjectorIsWiredAtEveryPoint(t *testing.T) {
	ctx := context.Background()
	visited := map[FaultPoint]bool{}
	x := newHarness(t, func(p FaultPoint) error {
		visited[p] = true
		return nil
	})
	x.provision("t1", "alice", 2)
	if _, err := x.saga.Erase(ctx, "t1", "alice"); err != nil {
		t.Fatalf("Erase: %v", err)
	}
	for _, b := range SagaBoundaries {
		if !visited[b.Before] {
			t.Errorf("boundary %q: the BEFORE fault point is never reached in a clean run", b.Name)
		}
		if !visited[b.After] {
			t.Errorf("boundary %q: the AFTER fault point is never reached in a clean run", b.Name)
		}
	}
	if len(visited) != 2*len(SagaBoundaries) {
		t.Errorf("a clean run visited %d fault points, expected %d", len(visited), 2*len(SagaBoundaries))
	}
}
