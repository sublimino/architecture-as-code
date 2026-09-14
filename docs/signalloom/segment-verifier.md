# Independent segment evidence verifier

SLDP-P1-3 provides the standard-library-only Go package
`signal-ingest/store/verify` and the standalone `segment-verify` command.
It does not call, import, or modify the signer implementation. Store integration
tests use the existing signer to generate fixtures; verification code does not.

## Auditor quick start

Build once in `d2-signalloom/apps/signal-ingest`:

```sh
CGO_ENABLED=0 go build -trimpath -o segment-verify ./cmd/segment-verify
```

Hand the binary, an **immutable offline snapshot**, independently trusted public
keys, and a separately protected high-water file to the auditor. The executable
needs neither a repository checkout, Go toolchain, private signing key, Python,
Witness, nor a network service at audit time.

```sh
/opt/audit/segment-verify \
  -evidence-dir /snapshot/evidence \
  -segment-root /snapshot/store \
  -highwater /trusted/highwater.json \
  -public-key /trusted/keys/version-1.pem \
  -public-key /trusted/keys/version-2.pem
```

Expected input layout:

```text
evidence/segments.jsonl
evidence/attestations/00000000000000000001.dsse.json
evidence/checkpoints/00000000-<12-hex-checkpoint-digest>.dsse.json
store/signaldb/observations/<block>/data.parquet
trusted/highwater.json
trusted/keys/<version>.pem
```

Success exits 0 and prints JSON. Malformed evidence, untrusted keys, broken
continuity, missing files, or partial coverage exit 1 by default. Help exits 0.
The explicit `-audit-only` option allows reporting a partial corpus; it is **not
an acceptance gate**. Never add it to a release, privacy, or erasure gate.

The library APIs are `VerifyCorpus(context.Context, Config)` and
`VerifySegment(context.Context, SegmentConfig)`. Both take explicit public-key
paths. `VerifySegment` accepts one envelope and one segment file independently
of the journal; it proves neither corpus inclusion nor completeness.
`VerifyCorpus` returns errors for invalid evidence and a result with
`integrity_scope: partial` for valid but incomplete coverage. **Library callers
must require `IntegrityScopeComplete` in addition to checking the error.**

## What the result means

| Field | Meaning |
|---|---|
| `signatures_verified` | Segment and checkpoint signatures were verified against supplied trust material; false for empty corpus |
| `integrity_scope` | `complete` only for nonempty, fully attested inventory without reported lost errors; otherwise `partial` |
| `semantic_redaction` | Always `not_assessed`; cryptographic validity cannot establish removal of identifiers |
| `unattested_historical_segments` | Pre-attestation inventory entries lack signed byte digests; their content is not verified |
| `lost_error_count` | Protected writer-reported error loss; nonzero prevents default acceptance without invalidating surviving signatures |
| `segments`, `checkpoints` | Number of verified records and checkpoints |
| `cumulative_row_count` | Attested **segment records**, not Parquet observation rows, in the v1 checkpoint format |
| `tip_checkpoint_digest` | Independently derived digest of the final verified checkpoint |

The verifier streams each segment through SHA-256 and compares actual byte
length, signed subject, signed predicate, journal metadata, and signer key ID.
It independently implements DSSE pre-authentication encoding and the v1
checkpoint digest and Merkle-leaf encoding. It verifies checkpoint index,
sequence windows, cumulative counts, predecessor digest, journal inclusion,
and protected high-water counts, journal size, last segment ID and last digest.

The v1 writer emits one segment record per checkpoint. That is a versioned wire
contract, not a generic Merkle-tree batching assumption. A batching writer must
introduce a supported schema and verification tests before use.

Unknown schemas are refused at the journal, signed segment predicate, signed
checkpoint predicate and high-water boundaries. Unknown JSON fields, duplicate
keys, case aliases, trailing values, malformed signatures and unsafe paths also
refuse. DSSE envelopes are limited to 4 MiB. Existing writer-generated v1 and
real FrostDB Parquet evidence pass without rewriting bytes.

## Trust and external-anchor limits

**A locally signed forgery can verify successfully.** This verifier establishes
integrity relative to trusted public keys and protected high-water state, not
independent proof that observations happened or that the signer was honest.

- `fe-signalloom/src/audit_anchor/anchor.py:407` explicitly refuses Rekor
  publication: `Rekor anchoring is not implemented; no checkpoint was published to Rekor`.
- Archivista publication is optional in `SegmentAttestorConfig`; the writer
  rejects missing URLs only when `RequireArchivista` is set. The Python anchor
  store also supports non-strict local-file fallback.
- Thus there is **no mandatory external anchor today**. This offline command
  does not query or certify Archivista receipts, Rekor inclusion, trusted time,
  revocation policy, tenant authorization, or legal erasure.
- Replacing keys, corpus and high-water together defeats local verification.
  Supplying the high-water file from the same untrusted snapshot does not prove
  rollback resistance. Retain an independently protected copy outside the
  writer's evidence directory and authenticate its provenance.
- `segments.errors.jsonl` is an operational log, not a signed checkpoint chain
  in the current writer. The verifier does not certify its contents or upstream
  observation completeness. Loss absent from protected state is not detectable.
- Roots and trust files are auditor-selected trusted paths. Descendant symlinks
  are refused, but path checks are not a defense against concurrent filesystem
  replacement. Freeze the snapshot before verification; do not run against a
  malicious live writer or mutate files during the scan.

## Rotation and public-material retention contract

Retain **every public key version** in the auditor-controlled key archive for at
least as long as evidence signed by that version is retained. Supply each with
repeatable `-public-key`. Key identifiers are lowercase SHA-256 of the public
key's DER SubjectPublicKeyInfo, independently derived by the verifier. Never
trust a key merely because it accompanies a segment.

The verifier never deletes or overwrites public key material. Its rotation test
restarts the existing writer under a second key, removes both disposable private
keys, verifies the two-segment chain with retained public keys, and proves that
omitting the retired public key fails. This proves verification across rotation,
not an operational key-archive deployment. KMS delivery must persist and publish
the public version before first signing and must not rotate away historical
public material. The reviewed plan assigns KMS abstraction to **P5-1**, not P4-1;
P4-1 owns the erasure key hierarchy.

## Acceptance integration

`make test-signal-ingest` and `make test-signal-ingest-frostdb` both depend on
`test-signal-segment-verifier`. These tests exercise corruption, correctly
re-signed broken checkpoints, sequence/count/Merkle changes, unknown schemas,
retired keys, rollback, partial coverage, strict JSON, symlink escape, and a
compiled auditor run outside the repository. The FrostDB target additionally
verifies three actual Parquet segments and rejects a same-length byte mutation.

For a one-key snapshot, from the repository root:

```sh
export SIGNAL_VERIFY_EVIDENCE=/snapshot/evidence
export SIGNAL_VERIFY_ROOT=/snapshot/store
export SIGNAL_VERIFY_HIGHWATER=/trusted/highwater.json
export SIGNAL_VERIFY_PUBLIC_KEY=/trusted/keys/version-1.pem
make verify-signal-segments
```

For rotated corpora use the compiled command with repeated `-public-key` as
above. The Make target deliberately has no audit-only bypass and refuses missing
inputs. No test-fixture fallback substitutes for the supplied corpus.

**Later phase contract:** run `VerifyCorpus` over the actual post-operation
snapshot, assert a nil error and complete integrity scope, then separately assert
semantic minimisation/unlinkability against the subject fixture. Run a corrupt
copy as a negative control. A signature pass alone is never an erasure result.
Unattested history remains partial; do not rewrite historical bytes to turn it
green. Retention and Article 17 need a new explicitly supported proof contract.

## Cost and scaling

Measurements and environment are recorded in `sldp-p1-3-proof.md`. Checkpoint
directories are indexed once, avoiding the initial quadratic glob scan. Work is
O(total segment bytes + N log N) including inventory sorting; memory is O(N)
for the journal and indexes, plus bounded per-envelope decoding. It is an offline
audit path, not inserted into `SignalStore.Query` or the 2.75 ms query path.

Do not use the warm small-fixture benchmark as a cold production-corpus SLA.
Large Parquet files, filesystem latency, page cache, cryptographic CPU cost and
O(N) journal memory all affect the acceptance scan. Measure an authorized,
representative frozen corpus before setting a production gate timeout.
