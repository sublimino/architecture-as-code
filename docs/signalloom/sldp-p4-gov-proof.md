# SLDP-P4-GOV — Phase 4 Governor Certification (pointer)

**Verdict: FAIL (one property of six). Phase 4 does not certify.**

The full certification proof lives in a single file:

→ **[`sldp-p4-governor-proof.md`](./sldp-p4-governor-proof.md)**

This file is a pointer, deliberately, rather than a second copy. The card names the evidence
artefact under two spellings (`sldp-p4-gov-proof.md` in *Required Evidence*,
`sldp-p4-governor-proof.md` in *Deliverables*) and earlier phases resolved that by duplicating the
content — `amxo-p1-gov-proof.md` and `amxo-p1-governor-proof.md` are byte-identical twins, as are
the P2 pair. Two copies of a certification is one copy and one future lie: the next edit lands in
whichever the author opened.

## The finding, in one paragraph

SLDP-P4-1 produces a destruction receipt carrying `OperationID`, `ReceiptSchema` and
`ReceiptDigest` — the last documented in its own source as *"the hex SHA-256 a tombstone
references."* `tombstone.MintRequest` accepts none of the three. `ReceiptCommitment` is computed
over a **freshly drawn nonce** and the caller's own scalars, `ProjectReceipt` has no production
caller, and `VerifyReceiptCommitment` recomputes from the tombstone's own published fields — so it
returns true for a tombstone recording a destruction that never occurred. The control cannot fail,
therefore it certifies nothing. `privacy/tombstone` has zero non-test importers.

Evidence: `d2-signalloom/apps/signal-ingest/privacy/tombstone/governor_seam_test.go`.

See [`sldp-p4-governor-proof.md` §3](./sldp-p4-governor-proof.md) for the full finding, §4 for
published residuals, §5 for what was assumed rather than tested, and §6 for what Phase 5 inherits.
