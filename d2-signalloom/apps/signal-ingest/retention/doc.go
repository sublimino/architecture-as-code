// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package retention enforces storage limitation (GDPR Article 5(1)(e)) across every copy of
// personal data Signal Loom holds, and leaves a per-copy receipt proving it did.
//
// SLDP-P6-1 builds this from nothing. Before it, retention was an evaluator with no executor:
// privacy.Retention decided whether a record MAY be deleted and stopped there, audit
// EventPartitionDropped was an enum value whose only call site logged Article 17 decisions,
// FrostDBStore.DropPartition moved an in-memory timestamp and unlinked no bytes, and the only
// reaper in the tree flipped delegations.status to 'expired'. There is no DELETE FROM anywhere in
// d2-signalloom. So "retention configured" read as satisfied while expired personal data survived
// indefinitely in every copy of the inventory.
//
// # The denominator is the control
//
// AllSinkSpecs is the UNION of SLDP-P6-PRE §3 (23 numbered rows) and the SLDP-P0 boundary map's
// personal-data storage-copy inventory (21 rows), plus three copy classes the P6-1 card names and
// neither document enumerates. Neither document is a subset of the other, and taking either alone
// would have been worse than a gap: the sink set is the denominator of every coverage and overdue
// figure, so a forgotten copy raises apparent coverage rather than showing up as a hole. The overdue
// gauge iterates the outstanding set, the outstanding set is built from this enumeration, and a copy
// never enumerated can never go overdue — so the strongest correcting loop in the design would be
// blind to precisely the failure that defeats it. inventory_parity_test.go therefore derives the
// expected set by PARSING both documents, and fails when either gains a row this table does not carry.
//
// # Four outcomes, never collapsed
//
// The controller records one receipt per COPY, not per sweep, and every receipt carries exactly one
// of five dispositions:
//
//	purged                       — rows or bytes were removed
//	already_absent               — the copy was not there; the ledger says so rather than staying silent
//	held                         — an active legal hold blocked deletion
//	unreachable                  — the sink could not be reached at deletion time
//	retained_unresolvable_token  — attested bytes retained; their linkage copies purged (see below)
//
// A per-sweep receipt cannot express "fourteen sinks purged, one unreachable", which is exactly the
// state that matters: a sweep that skips an unreachable sink and reports success is the specific
// failure the receipt ledger exists to expose. Consequently only purged, already_absent and
// retained_unresolvable_token are Complete(); held and unreachable leave the copy OUTSTANDING, and
// an outstanding copy past its propagation deadline is counted by the overdue gauge. Legal hold is
// therefore not a laundering path for indefinite retention — a permanently held copy goes overdue
// and a DPO sees it.
//
// # Precedence, stated once
//
// A legal hold beats retention expiry. This package does not re-decide that; it delegates to
// privacy.Retention.Evaluate, which is the single implementation, and which additionally fails
// closed on an undetermined hold lookup (ErrIncidentStateUnavailable) and on a source with no
// jurisdiction (ErrNoJurisdiction). Re-implementing precedence here would give the system two copies
// of the rule and a way for them to drift.
//
// # Retention versus checkpoint continuity
//
// The genuinely hard case, resolved rather than assumed away.
//
// Deleting an expired Parquet segment is NOT available. store/verify/verify.go:203 re-reads each
// segment's bytes to re-verify its DSSE claim, and verify.go:650-656 requires the on-disk segment
// inventory to be set-equal to high_water.HistoricalSegments union journal.SegmentID. Unlinking one
// expired segment turns VerifyCorpus from a pass into a hard error. Crypto-shredding does not answer
// this either: it is an Article 17 tool, and a shredded-but-retained blob is still retained, so it
// says nothing about Article 5(1)(e).
//
// The resolution is that retention on the columnar and attestation plane is enforced at the LINKAGE
// copies, not at the attested bytes. A segment payload holds an HMAC pseudonym. What makes that
// pseudonym personal data is the linkage: segment_reidentification_map (pseudonym -> actor_id) and
// subject_keys (the wrapped DEK that makes it resolvable). Neither is read by any verifier and
// neither is chained into any attestation, so both are deletable without touching a byte of
// evidence. At expiry the controller purges them and then emits a receipt for the segment sink
// itself with DispositionRetainedUnresolvableToken, cross-referencing the linkage receipt digests
// and stating the residual in words.
//
// Two things make that honest rather than a euphemism. The segment sink still carries a propagation
// deadline, so if the linkage purge does not complete in time the segment counts as overdue and the
// gauge fires — the attested plane is covered by the gate, not excused from it. And the receipt does
// not claim compliance: whether an unresolvable token is still personal data under Recital 26 is a
// controller determination, and ResidualState is where the controller is told what survives.
//
// # Time is an input
//
// Retention computed from a drifting local clock expires data early or late with no signal, so
// Clock is injected and carries its own provenance. A Controller in enforcing mode refuses a clock
// whose Source() is local_unverified, and a TrustedClock refuses to answer at all once its last
// sync is staler than its freshness window or its observed drift exceeds tolerance. A sweep that
// cannot read a trusted clock purges NOTHING, returns an error, and leaves outstanding copies
// outstanding — so the failure shows up as overdue objects rather than as a clean sweep.
package retention
