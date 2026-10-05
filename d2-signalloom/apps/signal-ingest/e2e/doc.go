// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package e2e is the offline end-to-end test of the Kusari pilot's AWS signal
// path: fixtures and a deterministic synthetic stream, through the PRODUCTION
// composition, against the bundles Flux actually reconciles.
//
// Run it with `make test-kusari-e2e`, which runs it in both store modes.
//
// # What is production here and what is not
//
// Production: the awslogs Projector, the tenant binder, the ingest deduper, the
// obscel evaluator, the stage-1/stage-2 policy sink, the boot-time bundle
// loader, and the bundle files under policy/bundles/kusari/. The composition
// order is the order main.go wires:
//
//	BindTenant -> DedupeSink -> policy.Sink -> StoreSink -> store
//
// with the sink's OWN output (findings and decisions) going back out through a
// second DedupeSink over the SAME accepted-ID set. That shape is not cosmetic:
// the source observation is claimed upstream of stage 1, so routing it back
// through a sink guarding the same set would refuse the first write as a
// duplicate of its own claim. Only derived records, whose IDs are their own, are
// offered to the dedupe seam.
//
// Not production: the store (MemoryStore by default, FrostDBStore under
// `-tags frostdb`) and the corpus. Nothing else is substituted, and in
// particular there is no second copy of any rule — a rule is only ever the text
// in the bundle file.
//
// # The clock
//
// There is none. Observations carry fixture timestamps, findings inherit them,
// and a stage-2 window is anchored on the ARRIVING finding's timestamp rather
// than on wall-clock, so the whole suite runs with no sleeps and no fake clock.
// That is also what makes replay comparable to live: a wall-clock reading
// anywhere in the chain would make the two disagree by construction.
//
// # What the suite claims
//
//   - Every rule in every loaded bundle produces exactly the findings the
//     expectation table names, and every rule has a fixture that does NOT fire
//     it. A rule with no negative is reported as a gap, because a rule that
//     fires on everything passes a positive-only suite.
//   - Every declared window produces exactly the decisions the table names.
//   - Replay over the stored observations reproduces the live run byte for byte,
//     on the canonical projection both sides share.
//   - A second pass of the same corpus changes nothing: no row, no finding, no
//     decision, and — the part that matters — stage 1 and stage 2 never see the
//     replayed record at all, so a burst counter cannot be reached by a
//     redelivery.
//
// # The mutation gate
//
// Each claim above is paired with its inverse, run in-test, so the green bar
// cannot rot into a tautology: an empty bundle directory must produce nothing,
// and a corpus with the attack records removed must produce no decision. See
// TestKusariE2E_MutationGates.
package e2e
