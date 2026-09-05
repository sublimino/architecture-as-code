# SFDP-P3-3 Archivista runtime evidence

Date: 2026-09-05 (Europe/London)

## Verdict

**PASS.** The exact repository-pinned Archivista image accepted and returned
newly generated segment, segment-checkpoint, and audit-checkpoint DSSEs. The
root segment proof passed against Archivista. The combined audit-and-segment
proof passed against isolated PostgreSQL and Archivista, then detected both an
audit-row modification and deletion.

The run used dedicated disposable Docker resources bound to loopback. No
Kubernetes command, sibling or principal checkout write, key or policy change,
commit, push, or public-remote write occurred.

## Compatibility corrections proven

- `segment_attestor.go` validates Archivista receipts using Git blob framing:
  `sha256("blob " + decimal_length + NUL + envelope)`.
- Segment and checkpoint envelopes are both published to Archivista.
- `anchor.py` probes the real `/query` GraphQL API instead of nonexistent
  `/v1/health`.
- Python validates JSON or plain-text Archivista GitOID receipts against the
  exact uploaded bytes.
- `audit-anchor-tamper-demo.sh` forwards the protected `--expected-key-id` to
  each root audit anchor operation.

Focused verification before runtime execution:

```console
$ CGO_ENABLED=0 go -C d2-signalloom/apps/signal-ingest test ./store -count=1
ok github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store 0.820s

$ python3 -m pytest -o addopts='' -q tests/test_audit_anchor_envelope.py
28 passed in 2.07s

$ bats test/sfdp-p3-3-root-wiring.bats
1..14
ok 14 owned shell scripts parse as bash
```

## Exact isolated services

The image in `d2-osramp-apps/components/backend/base/archivista.yaml` is
`ghcr.io/in-toto/archivista:0.11.0`. Its pulled manifest digest was:

```text
sha256:ff001ecf8c9084f8b2304270e0bc872edd9f54d5f0966673ac613a1b4c3292b2
```

The successful runtime shape was:

```bash
docker network create sfdp-p3-3-runtime-net-v2

docker run --rm -d --name sfdp-p3-3-postgres-runtime-v2 \
  --network sfdp-p3-3-runtime-net-v2 \
  -p 127.0.0.1:25432:5432 \
  -e POSTGRES_USER=signalloom \
  -e POSTGRES_PASSWORD=signalloom \
  -e POSTGRES_DB=signalloom \
  postgres:16-alpine

docker exec sfdp-p3-3-postgres-runtime-v2 \
  createdb -U signalloom archivista

docker run --rm -d --name sfdp-p3-3-archivista-runtime-v2 \
  --network sfdp-p3-3-runtime-net-v2 \
  -p 127.0.0.1:28082:8082 \
  -e ARCHIVISTA_LISTEN_ON=tcp://0.0.0.0:8082 \
  -e ARCHIVISTA_ENABLE_SPIFFE=FALSE \
  -e ARCHIVISTA_SQL_STORE_BACKEND=PSQL \
  -e 'ARCHIVISTA_SQL_STORE_CONNECTION_STRING=postgresql://signalloom:signalloom@sfdp-p3-3-postgres-runtime-v2:5432/archivista?sslmode=disable' \
  -e ARCHIVISTA_STORAGE_BACKEND=FILE \
  -e ARCHIVISTA_FILE_DIR=/tmp/archivista \
  ghcr.io/in-toto/archivista:0.11.0
```

Archivista's Atlas migration requires a clean database. The application audit
table therefore lived in `signalloom`, while Archivista metadata used the clean
`archivista` database in the same isolated PostgreSQL container.

The audit table used the schema already recorded by the SFDP-P3-3 runtime test:

```sql
CREATE TABLE public.audit_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id TEXT NOT NULL DEFAULT 'tenant-demo',
  timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  event_type TEXT NOT NULL,
  agent_id UUID,
  agent_name VARCHAR(255),
  actor VARCHAR(255) NOT NULL,
  detail JSONB NOT NULL
);
CREATE INDEX idx_audit_events_tenant_timestamp
  ON public.audit_events (tenant_id, timestamp DESC);
```

Runtime schema inspection confirmed all eight columns and their nullability.
Both published ports were loopback-only:

```text
127.0.0.1:25432->5432/tcp
127.0.0.1:28082->8082/tcp
```

## Root segment proof

The Archivista database was empty before this proof, preventing old envelopes
from satisfying retrieval assertions.

```bash
SIGNAL_SEGMENT_PROOF_DIR=/tmp/opencode/sfdp-p3-3-real-segment-20260905-2134 \
SFDP_GO_CACHE_ROOT=/tmp/opencode/sfdp-p3-3-go-runtime \
ARCHIVISTA_URL=http://127.0.0.1:28082 \
  make attested-test ATTESTED_TEST_SOURCE=segments
```

The command exited 0. Its intact verification reported one checkpoint, one
anchored row, zero unanchored rows, and `anchor_store` equal to the isolated
Archivista URL. Mutation returned `diverged`; restoring the same Parquet bytes
returned `intact`.

Evidence was not accepted by counting recent envelopes. The generated segment
ID was read from that run's retained `segments.jsonl`; GraphQL returned GitOIDs,
then exact `GET /download/<gitoid>` requests returned HTTP 200 and subjects
matching both newly generated objects:

```text
BOUND_SEGMENT
  subject: signaldb/observations/01M1SMDT5PMKAHSJYGHMFD2RBS/data.parquet
  gitoid:  47505663e1a6b5d9cfd084e2095873eda38715149b5b893e47a5765851a41040
  GET:     200

BOUND_SEGMENT_CHECKPOINT
  subject: signalloom-segment-checkpoint/signaldb/observations/00000000
  gitoid:  abc5b6b357d69bcf1684348e5d8ff053aaa329b25b9a4980d041c39aa9cdd139
  GET:     200
```

The empty Archivista database held exactly those two envelopes.

## Combined audit-and-segment proof

Archivista was reset to another clean database before the combined proof, again
preventing prior runs from satisfying its checks.

```bash
DATABASE_URL=postgresql://signalloom:signalloom@127.0.0.1:25432/signalloom \
ARCHIVISTA_URL=http://127.0.0.1:28082 \
AUDIT_ANCHOR_TAMPER_SOURCE=all \
SFDP_GO_CACHE_ROOT=/tmp/opencode/sfdp-p3-3-go-runtime \
  make audit-anchor-tamper-demo
```

The command exited 0. The single `--source both` verification reported:

```json
{
  "status": "intact",
  "anchor_store": "archivista:http://127.0.0.1:28082",
  "checkpoints_checked": 3,
  "anchored_row_count": 7,
  "unanchored_row_count": 0,
  "proves_anything": true,
  "chain_issues": [],
  "divergences": []
}
```

The audit mutation produced exit 2 and localized
`merkle_root_mismatch` to checkpoint 0 while checkpoint 1 remained clean.
Byte-for-byte restoration returned `INTACT` with exit 0. Reordering equivalent
JSONB keys remained intact. Deleting an anchored row produced exit 2 and
`row_count_mismatch` at checkpoint 0. Cleanup left zero rows for
`tenant-anchor-tamper-demo`.

All four envelopes from this new combined run were fetched individually with
HTTP 200:

```text
signaldb/observations/01M1SMFE1SR3YESKQ3NZC1DFSW/data.parquet
  4dcadab8cbc4567bf1ffcd88233d99c9c402aece897a3256732a4840f8116a52
signalloom-segment-checkpoint/signaldb/observations/00000000
  84214d513be0c2ea00a83082a396a9fea52ed927f20bfbf40d56798ec9255a7e
signalloom-audit-checkpoint/tenant-anchor-tamper-demo/00000000
  88492533826b6838f99169d97dad275889ad8d5f9f4ef1153c9f26567840d06c
signalloom-audit-checkpoint/tenant-anchor-tamper-demo/00000001
  d009bd5f18e3d4285952995b5ca254e2a9a7edd343a4ae8f6e1f688cfe777c58
```

## Witness 0.9.1

The repository-pinned binary remained local to `/tmp/opencode`:

```console
$ /tmp/opencode/witness-0.9.1/witness version
witness v0.9.1-470e889
```

No standalone Witness verification was added. The protected
`segment-signing-policy.json` is an application signer allowlist, not a Witness
policy entrypoint. The existing Python verifier exercised the complete envelope,
expected signer identity, checkpoint chain, source bytes, and Archivista
retrieval; invoking Witness for signature-only verification would be weaker.

## Cleanup

Only resources created for this run were removed:

```bash
docker stop sfdp-p3-3-archivista-runtime-v2 sfdp-p3-3-postgres-runtime-v2
docker network rm sfdp-p3-3-runtime-net-v2
docker ps -a --filter name=sfdp-p3-3- --format '{{.Names}} {{.Status}}'
```

The final filtered container listing was empty. The exact Archivista image and
repository-pinned Witness binary remain cached locally; neither affects the
shared cluster.
