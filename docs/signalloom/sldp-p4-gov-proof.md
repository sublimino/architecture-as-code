# SLDP-P4-GOV — Phase 4 Governor Certification (pointer)

**Verdict: PASS (all six properties certified, G1 remediated). Phase 4 certifies.**

The full certification proof lives in a single file:

→ **[`sldp-p4-governor-proof.md`](./sldp-p4-governor-proof.md)**

This file is a pointer, deliberately, rather than a second copy. The card names the evidence
artefact under two spellings (`sldp-p4-gov-proof.md` in *Required Evidence*,
`sldp-p4-governor-proof.md` in *Deliverables*) and earlier phases resolved that by duplicating the
content — `amxo-p1-gov-proof.md` and `amxo-p1-governor-proof.md` are byte-identical twins, as are
the P2 pair. Two copies of a certification is one copy and one future lie: the next edit lands in
whichever the author opened.

## Remediation summary

Initially, Property F failed as Hard Blocker G1 (the receipt↔tombstone seam was open; `MintRequest`
did not accept the receipt identity/nonce, `ProjectReceipt` had no production caller, and
`VerifyReceiptCommitment` was a self-consistency check).

In Tick #88 (commit `8e94b193`), G1 was fully remediated:
1. `privacy.KeyDestructionReceipt` carries `ReceiptNonce` from the saga journal.
2. `tombstone.MintRequest` accepts `OperationID`, `ReceiptSchema`, `ReceiptDigest`, and `ReceiptNonce`.
3. `ReceiptCommitment` binds `(nonce ‖ canonical(projection, receiptDigest))`.
4. `VerifyReceiptCommitment(t Tombstone, r privacy.KeyDestructionReceipt)` takes external genuine receipt and validates identity & commitment (rejecting fabricated tombstones).
5. `tombstone.Publisher` implements `privacy.TombstonePublisher` and is wired to `privacy.Service.Erase` and `main.go`.
6. 4 positive seam verification tests in `governor_seam_test.go` prove the seam is closed.

See [`sldp-p4-governor-proof.md`](./sldp-p4-governor-proof.md) for the complete certification proof.

