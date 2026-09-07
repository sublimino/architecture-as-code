# SFDP-P3-3 persisted segment attestation contract

This is the shared Go-writer/Python-verifier contract for strictly append-only
FrostDB objects in the store scope `signaldb/observations`. That persistence
model is authorised. Supersession, compaction, predecessor retirement, and
crash-WAL-replay reconciliation are explicitly deferred until the store has a
real rewrite producer and a trusted lineage contract; they are not active
blockers for this append-only scope.

## Files and successful records

The persisted object is the exact FrostDB upload at
`signaldb/observations/*/data.parquet`. The bucket decorator hashes and counts
those bytes during the successful upload, then offers the object identity,
digest, and length to a bounded background worker. An explicit `Flush` waits for
the Parquet upload, not for that worker.

For a successfully processed object, the worker writes one segment DSSE, writes
and optionally publishes one rolling checkpoint, appends one UTF-8 JSON object
plus `\n` to `segments.jsonl`, then atomically advances protected high-water
state. When `ARCHIVISTA_URL` is configured, both the segment DSSE and its
checkpoint DSSE must receive matching content-addressed GitOID receipts before
the `state=ok` journal record is appended. The journal is never rewritten.

`segment_id` is the complete slash-separated bucket object name. The verifier
resolves it beneath a configured segment root and rejects absolute paths, `..`,
or any name outside `signaldb/observations/`.

Each successful line has exactly these fields:

```json
{"schema_version":"signalloom.segment/v1","sequence":1,"segment_id":"signaldb/observations/01/data.parquet","digest":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","byte_length":123,"signer_key_id":"SPKI_SHA256_HEX","state":"ok","error":"","attestation":"attestations/00000000000000000001.dsse.json","checkpoint_inclusion":{"checkpoint_index":0,"leaf_index":0}}
```

`sequence` starts at 1 and increases by exactly one. `digest` is lowercase hex
SHA-256 over the uploaded object bytes; `byte_length` counts those same bytes.
`signer_key_id` is lowercase SHA-256 over DER SubjectPublicKeyInfo. The current
Go writer appends only `state=ok` records with an empty `error`. The verifier
also recognizes `pending` as could-not-run and `error` with a non-empty message
as divergence, but asynchronous writer failures are recorded in
`segments.errors.jsonl` rather than appended to the success journal.

`attestation` is a safe relative DSSE path. Current successful records carry
`checkpoint_inclusion={"checkpoint_index":sequence-1,"leaf_index":0}`.

## Segment DSSE and signer history

The envelope uses payload type `application/vnd.in-toto+json`. Its payload is a
compact, key-sorted UTF-8 in-toto Statement v1 with predicate type
`https://controlplane.io/attestations/signalloom-segment/v1`. The sole subject is
named by `segment_id` and has the journal `sha256` digest. The predicate is the
complete journal object except `attestation` and `checkpoint_inclusion`.

Sign Ed25519 over standard DSSE PAE:

```text
"DSSEv1 " || decimal(len(typeBytes)) || " " || typeBytes || " " ||
decimal(len(payloadBytes)) || " " || payloadBytes
```

The envelope signature `keyid` and predicate `signer_key_id` must both identify
a public key supplied to the verifier and explicitly permitted by
`--expected-key-id`. Historical signatures remain verifiable only while their
public keys remain in the supplied keyring, their identifiers remain expected,
and those identifiers are not supplied through `--revoked-key-id`. A revoked
identifier is rejected even when its signature is cryptographically valid.

The current root signing policy pins the application signer identity. It is not
a Witness policy entrypoint, and this contract claims no standalone `witness
verify` policy result. The Go writer loads one private key when it starts;
automatic key rotation and live key reload are not implemented here.

## Rolling inventory checkpoints and cadence

Checkpoint boundaries are decimal sequences rendered as exactly twenty digits.
The first window is `(beginning, boundary]`; later windows are `(previous,
boundary]`. `boundary_basis` is `segment_sequence`, tenant scope is exactly
`signaldb/observations`, and canonical Merkle leaves are the existing
`signalloom.audit.row/v1` encoding of the validated journal projection. The
projection fixes `ts` to the twenty-digit sequence, `id` to `segment_id`, event
type to `segment.persisted`, actor to `signer_key_id`, and detail to the complete
journal object. Digest swaps, reordering, insertion, and metadata changes
therefore alter the RFC6962 Merkle root.

The checkpoint predicate remains `signalloom.audit.checkpoint/v1` for verifier
compatibility, but its subject prefix is
`signalloom-segment-checkpoint/signaldb/observations/`. It chains the previous
checkpoint digest and cumulative count through the existing checkpoint digest
algorithm.

The worker creates one checkpoint for each segment upload it processes
successfully, including uploads induced by explicit `Flush`. This is processing
cadence, not a hard wall-clock SLA: `Flush` does not wait for attestation, queue
drain can lag ingestion, and local filesystem calls have no independent
deadline. Each Archivista HTTP publication has a ten-second context deadline,
but a wedged filesystem can still prevent bounded completion.

## Bounded queues and failure semantics

The successful-upload queue is bounded and defaults to 16 entries. Enqueue is
non-blocking. If it overflows, the Parquet upload has already succeeded and the
ingestion path still returns success, but that object receives no successful
journal record, segment attestation, checkpoint, or high-water advancement.
Overflow therefore fails the evidence path, not ingestion; complete inventory
verification subsequently rejects the unjournaled object.

Failures are offered to a separate bounded error queue, which defaults to 128
entries, for append-only recording in `segments.errors.jsonl`. If this secondary
queue also overflows, individual error records can be lost. The writer increments
`lost_error_count` in protected high-water state, and the Python verifier treats
any nonzero value as divergence. `Status` exposes successful-queue overflow,
error-queue overflow, durable-error counts, and terminal worker failure.

An attestation, filesystem, or publication failure degrades the worker. It does
not retroactively fail the completed object upload. `WaitForAttestations` is a
test and controlled-shutdown observation seam; normal ingestion does not call it.

## Protected freshness and complete inventory

Protected high-water state lives in `.keys` or another operator-protected
directory and is atomically replaced only after successful evidence processing:

```json
{"schema_version":"signalloom.segment.highwater/v1","max_sequence":12,"journal_size":4821,"attestation_count":12,"checkpoint_count":12,"last_segment_id":"signaldb/observations/01/data.parquet","last_digest":"LOWERCASE_SHA256","historical_segments":["signaldb/observations/pre-attestor/data.parquet"],"lost_error_count":0}
```

At first protected-state creation, the Go writer records matching Parquet object
names already present beneath the segment root in `historical_segments`. This is
a no-backfill inventory baseline. Those objects must remain present and no
unknown matching object may appear, but their pre-attestor bytes have no journal
digest or DSSE and therefore are not protected against in-place byte mutation by
this contract.

Go startup and the Python verifier enforce that the current Parquet inventory
equals the union of `historical_segments` and journaled segments. Both reject
missing historical objects and unknown objects. Python additionally rejects
malformed or duplicate historical entries, overlap between historical and
journaled identifiers, and any nonzero `lost_error_count`.

The threat model excludes attacker writes to protected high-water state, the
signer policy, and private signing keys. Verification rejects journal rollback,
segment-tip changes, regressed attestation or checkpoint inventories, persisted
byte changes for journaled segments, complete-inventory differences, and
recorded error loss. Signatures alone do not establish freshness.

## Transparency services and outcomes

`--require-archivista` or `AUDIT_ANCHOR_REQUIRE_LOG=1` requires a healthy
configured Archivista and forbids file fallback. Archivista health uses its real
GraphQL `/query` endpoint. Upload receipts are accepted as JSON or plain text and
must equal the Git blob GitOID of the exact uploaded envelope bytes. A configured
unavailable Rekor remains an explicit could-not-run error, never an ignored
warning.

Successful verification requires exit 0, `status=intact`,
`proves_anything=true`, `checkpoints_checked>0`, and
`unanchored_row_count=0` for each selected source. Proven divergence exits 2;
inability to verify exits 1.

Real Archivista and PostgreSQL proofs have passed with disposable loopback-only
local services. That evidence does not establish a Kubernetes, shared-cluster,
or production deployment.

## Explicitly unresolved or deferred

- Supersession, compaction, predecessor retirement, and WAL-replay reconciliation
  are resolved for this scope by explicit deferral, not implementation.
- No hard wall-clock checkpoint-completion SLA exists under a wedged filesystem.
- Pre-attestor historical object names are inventory-protected; their bytes are
  not retroactively hashed or attested.
- Automatic signing-key rotation and live key reload are not implemented.
- No standalone Witness policy verification is claimed.
- No Kubernetes or production deployment has been proven by the local runtime
  evidence.
