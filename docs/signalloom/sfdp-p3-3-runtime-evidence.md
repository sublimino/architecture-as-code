# SFDP-P3-3 root wiring runtime evidence

Date: 2026-09-05 (Europe/London)

This evidence was produced from the detached SFDP worktree. The recorded runtime
proofs used real FrostDB Parquet, real PostgreSQL, and, in the later isolated
run, the repository-pinned real Archivista image. They are local runtime evidence,
not evidence of a Kubernetes, shared-cluster, or production deployment. No
Kubernetes mutation, sibling-worktree operation, commit, or push was performed.
Disposable PostgreSQL and Archivista containers were removed after their runs.

The earlier supersession blocker is **resolved for this scope by explicit
deferral**. Persisted FrostDB block objects are treated as strictly append-only.
Supersession, compaction, predecessor retirement, and crash-WAL-replay
reconciliation remain deferred; none is represented as implemented here.

## Protected application signer policy

`make signing-keys` now bootstraps
`$KEYS_DIR/segment-signing-policy.json` once, beside the approved local Witness
key. Later runs recompute the public key's DER SPKI SHA-256 and fail closed if it
does not equal the protected policy identifier. Segment verification reads the
expected identifier from that policy; supplying another public key does not
change the trust decision.

This JSON file is an application signer allowlist consumed by the Make/Python
verification path. It is not a Witness policy entrypoint, and no standalone
`witness verify` policy result is claimed. The verifier can validate historical
signatures when each public key and expected identifier is supplied; an explicit
`--revoked-key-id` rejects that signer even when its signature is valid.

Successful command:

```bash
make signing-keys
```

Policy outcome (the identifier is public key metadata, not secret material):

```json
{"schema_version":"signalloom.segment.signing-policy/v1","expected_key_ids":["e832a15ca62a292aedac2a81a50614e0e105fa982a5f6bd337d98d4b3e7ce0ea"]}
```

The BATS mutation test replaces that identifier with 64 zeroes and confirms a
subsequent `make signing-keys` fails with `protected segment signing policy
rejects .../witness-pub.pem`. The target has no `workload-key` dependency and
does not contact Kubernetes.

## Real FrostDB Parquet proof, local anchor

Successful command (exit 0):

```bash
proof_dir="$(mktemp -d /tmp/opencode/sfdp-p3-3-root-proof.XXXXXX)"
env -u ARCHIVISTA_URL -u AUDIT_ANCHOR_REQUIRE_LOG \
  SIGNAL_SEGMENT_PROOF_DIR="$proof_dir" \
  SFDP_GO_CACHE_ROOT=/tmp/opencode/sfdp-p3-3-go \
  make attested-test ATTESTED_TEST_SOURCE=segments
```

The retained Go integration test passed, generated a real FrostDB Parquet
object, and left the journal, DSSE, rolling checkpoint, protected high-water,
and Parquet bytes for independent root verification. Machine outcomes:

```json
{"status":"intact","anchor_store":"file:/tmp/opencode/sfdp-p3-3-root-proof.RKjQIQ/evidence/checkpoints","checkpoints_checked":1,"anchored_row_count":1,"unanchored_row_count":0,"proves_anything":true,"chain_issues":[],"divergences":[]}
{"status":"diverged","proves_anything":false,"checkpoints_checked":0,"unanchored_row_count":null,"integrity_error":"persisted byte digest mismatch for segment signaldb/observations/01M1SF4XHB6MK32YVX6S2CEJZC/data.parquet"}
{"status":"intact","anchor_store":"file:/tmp/opencode/sfdp-p3-3-root-proof.RKjQIQ/evidence/checkpoints","checkpoints_checked":1,"anchored_row_count":1,"unanchored_row_count":0,"proves_anything":true,"chain_issues":[],"divergences":[]}
```

The tampered verification exited 2. After the script restored the original
Parquet bytes, verification returned to exit 0 and `status=intact`.

The same retained evidence passed through the root Make target (exit 0):

```bash
p="$(cat /tmp/opencode/sfdp-p3-3-root-proof.path)"
env -u ARCHIVISTA_URL -u AUDIT_ANCHOR_REQUIRE_LOG \
  AUDIT_ANCHOR_DIR="$p/evidence/checkpoints" \
  make audit-anchor-verify \
  ARGS="--source segments --segment-journal $p/evidence/segments.jsonl --segment-root $p/store --protected-high-water $p/protected/highwater.json" \
  COMMAND_ARGS="--json"
```

That command reported `status=intact`, `checkpoints_checked=1`,
`unanchored_row_count=0`, and `proves_anything=true`.

## Combined audit and segment proof against real PostgreSQL

A cached `postgres:16-alpine` image was started only on
`127.0.0.1:25432`. A minimal real `public.audit_events` table matching the
reader's columns was created in that disposable server. No fixture reader was
used. The successful setup commands were:

```bash
docker run --rm -d --name sfdp-p3-3-postgres \
  -e POSTGRES_USER=signalloom \
  -e POSTGRES_PASSWORD=signalloom \
  -e POSTGRES_DB=signalloom \
  -p 127.0.0.1:25432:5432 postgres:16-alpine

docker exec sfdp-p3-3-postgres psql -U signalloom -d signalloom \
  -v ON_ERROR_STOP=1 -c \
  "CREATE TABLE public.audit_events (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id TEXT NOT NULL DEFAULT 'tenant-demo', timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(), event_type TEXT NOT NULL, agent_id UUID, agent_name VARCHAR(255), actor VARCHAR(255) NOT NULL, detail JSONB NOT NULL); CREATE INDEX idx_audit_events_tenant_timestamp ON public.audit_events (tenant_id, timestamp DESC);"
```

The proof command was:

```bash
env -u ARCHIVISTA_URL -u AUDIT_ANCHOR_REQUIRE_LOG \
  DATABASE_URL=postgresql://signalloom:signalloom@127.0.0.1:25432/signalloom \
  AUDIT_ANCHOR_TAMPER_SOURCE=all \
  SFDP_GO_CACHE_ROOT=/tmp/opencode/sfdp-p3-3-go \
  make audit-anchor-tamper-demo
```

It exited 0. Before tampering, the single `--source both` verification produced:

```json
{"status":"intact","anchor_store":"file:/tmp/tmp.O4V6837tJa/evidence/checkpoints","checkpoints_checked":3,"anchored_row_count":7,"unanchored_row_count":0,"proves_anything":true,"chain_issues":[],"divergences":[]}
```

The audit modification then returned exit 2 and localized divergence to
checkpoint 0 while checkpoint 1 remained clean. Restoring the original JSONB
returned exit 0 and `INTACT`. Reordering equivalent JSONB keys remained intact.
Deleting one anchored row returned exit 2 with `row_count_mismatch`. The EXIT
trap removed the task tenant's rows, and the disposable server was removed.

```bash
docker rm -f sfdp-p3-3-postgres
```

## Real Archivista and PostgreSQL proof, isolated locally

The later run recorded in
[`sfdp-p3-3-archivista-evidence.md`](sfdp-p3-3-archivista-evidence.md) used the
repository-pinned `ghcr.io/in-toto/archivista:0.11.0` image and a real PostgreSQL
16 service on a dedicated Docker network. Both published ports were bound only
to loopback. Archivista health used its real GraphQL `/query` API, and upload
receipts were checked as Git blob GitOIDs over the exact envelope bytes.

The isolated root segment proof exited 0, retrieved the newly generated segment
and segment-checkpoint envelopes by their bound GitOIDs, detected a Parquet byte
mutation, and returned to intact after restoration. The isolated combined proof
also exited 0 against real PostgreSQL and Archivista. Its single `--source both`
verification reported:

```json
{"status":"intact","anchor_store":"archivista:http://127.0.0.1:28082","checkpoints_checked":3,"anchored_row_count":7,"unanchored_row_count":0,"proves_anything":true,"chain_issues":[],"divergences":[]}
```

That combined run subsequently detected an audit-row modification and deletion,
while equivalent JSON key reordering remained intact. All four newly generated
segment, segment-checkpoint, and audit-checkpoint envelopes were fetched
individually from Archivista with HTTP 200. This proves compatibility with those
disposable local services; no in-cluster Archivista or application deployment
was performed.

## Historical inventory, error-loss, and signer-history verification

The current Python verifier enforces the protected `historical_segments`
inventory as a disjoint no-backfill baseline: missing historical objects,
unknown Parquet objects, malformed entries, duplicate entries, and overlap with
journaled segments are rejected. It also treats any nonzero protected
`lost_error_count` as divergence. Historical signing keys are accepted only when
their public keys and identifiers are explicitly pinned, and an explicitly
revoked identifier is rejected.

Fresh focused verifier and explicit-rotation checks from this worktree:

```console
$ cd d2-signalloom/apps/fe-signalloom/src
$ python3 -m pytest -o addopts='' -q tests/test_audit_anchor_segments.py
.........................................                                [100%]
41 passed in 0.24s

$ cd d2-signalloom/apps/signal-ingest
$ env LC_ALL=C LANG=C CGO_ENABLED=0 GOCACHE=/tmp/opencode/gocache \
    GOMODCACHE=/tmp/opencode/gomodcache GOTMPDIR=/tmp/opencode/gotmp \
    go test -tags=frostdb ./store \
    -run '^TestFrostDBExplicitRotationsAttestRealParquetBytes$' -count=1
ok github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store 0.193s
```

The fresh Go store result and real-service proof are recorded in
`sfdp-p3-3-archivista-evidence.md`; the current count-10 benchstat result is
recorded in `sfdp-p3-3-go.md`.

## Strict Archivista failure

The root Make target now makes a configured `ARCHIVISTA_URL` strict rather than
allowing silent file fallback. Isolating the transport from database
availability produced this expected failure:

```bash
ARCHIVISTA_URL=http://127.0.0.1:1 \
DATABASE_URL=postgresql://unused:unused@127.0.0.1:1/unused \
make audit-anchor-checkpoint
```

Outcome: nonzero Make exit 2, with
`strict Archivista mode configured but Archivista at http://127.0.0.1:1 is unavailable`.
The literal command requested without `DATABASE_URL` also exits nonzero; it
stops earlier at the CLI's required-DSN validation, so the command above is the
stronger transport-specific falsification.

## Static and shell gates

```bash
bats test/sfdp-p3-3-root-wiring.bats
bash -n scripts/segment-attestation-proof.sh scripts/attested-test.sh scripts/audit-anchor-tamper-demo.sh
git diff --check -- Makefile scripts/segment-attestation-proof.sh scripts/attested-test.sh scripts/audit-anchor-tamper-demo.sh test/sfdp-p3-3-root-wiring.bats
```

The earlier local-file run recorded 13 BATS tests passing. After the real
Archivista compatibility corrections, the fresh focused run recorded all 14
tests passing; the shell syntax gate also passed. The count belongs to this
named file only and is not a repository-wide test count.

## Runtime scope and remaining external gates

Final local regression run after transport and fail-closed inventory fixes:
`python3 -m pytest -o addopts='' .../tests/test_audit_anchor*.py -q` passed
181 tests; the full `go test -tags frostdb ./...` suite passed with
`LC_ALL=C LANG=C CGO_ENABLED=0`; root wiring passed 14 tests. The retained
`/tmp/opencode/sfdp-p3-3-final-proof` run passed intact/diverged/restored JSON
gates without a Python executable shim: the integration test supplies its
expected signer pin directly.

- **Optional Rekor anchoring is not enabled in this implementation.** Setting
  `REKOR_URL` fails explicitly even when the service answers: connectivity is
  not evidence of publication or inclusion. The reachable-service regression
  prevents that false green. No independent Rekor freshness guarantee is claimed.
  Archivista publication and protected `.keys/` high-water are the delivered
  persistence/trust boundary.

- **Real local Archivista publication: passed.** The exact pinned image accepted,
  indexed, returned, and served the newly generated envelopes in disposable
  loopback-only Docker services.
- **Real local PostgreSQL combined verification: passed.** The audit and segment
  sources verified together before the mutation and deletion demonstrations.
- **Kubernetes deployment: not done.** No namespace, workload, Service,
  NetworkPolicy, Flux object, or in-cluster route was created or validated for
  this work. The local proofs must not be described as cluster-green.
- **Production deployment: not done.** No production runtime, durability,
  capacity, recovery, or operational key-rotation claim follows from the local
  evidence.
- **Witness policy verification: not claimed.** A repository-pinned Witness
  binary was inspected, but the application signer allowlist is not a Witness
  policy. Python performed the complete evidence verification.
- **Checkpoint wall-clock SLA: unresolved.** The writer creates one checkpoint
  for each successfully processed segment and applies a ten-second context
  deadline to each Archivista HTTP publication. The bounded queue prevents
  ingestion blocking, but filesystem operations have no independent deadline;
  a wedged filesystem can prevent bounded completion.
- **Overflow semantics: explicit evidence failure.** If the successful-upload
  queue is full, ingestion still succeeds because the Parquet upload already
  completed, but that object is not journaled or attested. Inventory verification
  rejects it. If the bounded secondary error queue loses records,
  `lost_error_count` prevents an intact verdict.
- **Supersession and WAL reconciliation: resolved by deferral.** These are not
  active blockers, but neither behavior is implemented or runtime-proven.

## Prompt-to-artifact coverage checklist

Each row represents one explicit deliverable unless the same command and output
prove the grouped result.

| Explicit deliverable | Artifact or evidence | Status and boundary |
| --- | --- | --- |
| Integration-derived isolated worktree | Historical ancestry record in `sfdp-p3-3-blocker.md` | **PASS — recorded.** No merge, push, or sibling mutation. |
| Persisted-byte interception | `segment_attestor.go` bucket decorator; `frostdb_attestor_test.go` | **PASS — source test.** Hash and length cover successful Parquet upload bytes. |
| Inducible FrostDB rotation | `TestFrostDBExplicitRotationsAttestRealParquetBytes` | **PASS — fresh Go store suite.** Explicit flush rotation only; no production cadence claim. |
| Bounded successful-upload worker | `SegmentAttestorConfig.QueueSize`; overflow test | **PASS — fresh Go store suite.** Default capacity is 16. |
| Non-blocking ingestion on overflow | `TestSlowPublicationOverflowsVisiblyWithoutBlockingUpload` | **PASS — fresh Go store suite.** Evidence fails while the completed upload remains successful. |
| Bounded secondary error queue | `ErrorQueueSize`; `TestSecondaryErrorBufferIsBoundedAndLossIsProtected` | **PASS — fresh Go store suite.** Default capacity is 128. |
| Lost error cannot verify intact | Python `test_protected_lost_error_count_is_divergence` | **PASS — 41-test focused Python run.** Nonzero protected loss diverges. |
| Segment DSSE over persisted bytes | Root segment proof in `sfdp-p3-3-archivista-evidence.md` | **PASS — isolated real runtime.** Newly generated envelope retrieved by bound GitOID. |
| Rolling segment checkpoint | Root segment proof and segment checkpoint retrieval | **PASS — isolated real runtime.** One checkpoint covered the successful segment. |
| Shared segment verifier | `audit_anchor/segments.py`; root segment proof | **PASS — isolated real runtime.** Go evidence verified through Python. |
| Combined audit and segment verifier | `make audit-anchor-tamper-demo` real-service run | **PASS — isolated real runtime.** Three checkpoints and seven anchored rows. |
| Protected signer identity | `segment-signing-policy.json`; root Make wiring tests | **PASS — application policy.** This is not Witness policy verification. |
| Historical signer pins | Python `test_historical_rotation_accepts_both_pinned_keys` | **PASS — 41-test focused Python run.** Keys and expected identifiers must be supplied. |
| Explicit signer revocation | Python `test_revoked_historical_key_is_rejected` | **PASS — 41-test focused Python run.** No automatic key rotation is implied. |
| Protected rollback detection | Go startup tests; Python high-water tests | **PASS — focused source suites.** Protected storage remains outside the attacker boundary. |
| Historical Parquet inventory | Go genesis test; Python historical inventory tests | **PASS — focused source suites.** Names and presence are enforced; old bytes are not retroactively attested. |
| Unknown Parquet detection | Go restart test; Python unknown-inventory test | **PASS — focused source suites.** An unjournaled matching object is divergence. |
| Strict Archivista failure | Unreachable configured-URL command above; BATS gate | **PASS — local negative evidence.** No silent file fallback in strict mode. |
| Real Archivista publication | `sfdp-p3-3-archivista-evidence.md` | **PASS — isolated real runtime.** Exact pinned image, GraphQL health, GitOID receipt, and download verified. |
| Real PostgreSQL combined proof | `sfdp-p3-3-archivista-evidence.md` | **PASS — isolated real runtime.** Disposable PostgreSQL and Archivista only. |
| Tampered Parquet detection | Root segment proof | **PASS — isolated real runtime.** Mutation diverged; restoration returned intact. |
| Audit-row modification detection | Combined real-service proof | **PASS — isolated real runtime.** Earliest checkpoint localized. |
| Audit-row deletion detection | Combined real-service proof | **PASS — isolated real runtime.** `row_count_mismatch` reported. |
| Equivalent JSON-key reorder stability | Combined real-service proof | **PASS — isolated real runtime.** Semantically equivalent JSON remained intact. |
| Ingestion-visible performance budget | Count-10 benchstat in `sfdp-p3-3-go.md` | **PASS — one workstation.** No significant difference; observed result within 10% budget. Not capacity evidence. |
| HTTP publication deadline | `TestPublicationTimeoutBoundsCustomClientWithoutTimeout` | **PASS — fresh Go store suite.** Ten-second default per request; filesystem remains unbounded. |
| Supersession reconciliation | Resolution in `sfdp-p3-3-blocker.md` | **DEFERRED — not implemented.** Strict append-only scope removes the active blocker. |
| Compaction predecessor retirement | Resolution in `sfdp-p3-3-blocker.md` | **DEFERRED — not implemented.** Requires a real rewrite producer and trusted lineage. |
| Crash-WAL-replay reconciliation | Resolution in `sfdp-p3-3-blocker.md` | **DEFERRED — not implemented.** No runtime claim. |
| Hard wall-clock checkpoint completion | Contract cadence section | **UNRESOLVED.** Queue and HTTP are bounded; filesystem completion is not. |
| Historical object byte integrity | Protected historical inventory | **UNRESOLVED.** Presence is enforced, but pre-attestor bytes have no digest or DSSE. |
| Automatic signing-key rotation | Signer-history contract | **UNRESOLVED.** Historical verification and revocation exist; writer rollover does not. |
| Standalone Witness policy verification | Witness section in `sfdp-p3-3-archivista-evidence.md` | **NOT CLAIMED.** Application signer policy is verified by Python. |
| Kubernetes deployment proof | No deployment artifact produced | **NOT DONE.** Local Docker evidence must not be promoted to cluster status. |
| Production operational proof | No production artifact produced | **NOT DONE.** Recovery, capacity, and operational rotation remain outside this evidence. |
