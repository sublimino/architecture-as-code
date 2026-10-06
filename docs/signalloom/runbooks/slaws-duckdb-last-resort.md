# Runbook — reading the signal store with DuckDB when signal-ingest is down

**Status:** current. Written 2026-10-04 for SLAWS P1-1. Every command below was executed; the
output is pasted verbatim, not illustrative.

## When to use this

signal-ingest is the only writer of the signal store and normally the only reader: observations
come back out through `GET /api/v1/observations` and the Weave. This runbook is for when that path
is unavailable and you still need to answer a question from the backlog:

- the pod is `CrashLoopBackOff`, `Pending` on its claim, or its image is being rolled back
- the API answers but you do not trust it, and want to read the bytes on disk instead
- you are checking whether observations were actually persisted, rather than held in RAM

It is a **read-only, out-of-band** procedure. DuckDB opens the Parquet files directly and never
talks to signal-ingest, so it works with the pod scaled to zero — which is the recommended state
before you start, because FrostDB holds its directory open.

## What you are reading

The store is FrostDB with Parquet durability. Two settings have to be true for anything to be on
disk at all, and both are asserted by `TestReconciledManifestStoresSignalsDurably`:

| Setting | Value | Why it matters |
| :--- | :--- | :--- |
| `SIGNAL_STORE` | `frostdb` | Any other value, including unset, selects the in-memory store. The claim is then mounted and never written to. |
| `SIGNAL_STORE_DIR` | `/data/signals` | The Parquet root. This is the path you copy out. |
| `signal-store` volume | PersistentVolumeClaim | An ephemeral volume is deleted with the pod, so there would be no backlog to read. |

The binary must also have been built `-tags frostdb`; without the tag the untagged store factory is
compiled in and ignores `SIGNAL_STORE` entirely.

Layout under the root is `<database>/<table>/<ulid>/data.parquet`, so a recursive glob is required:

```text
/data/signals/signaldb/observations/01M42W95V2N62PHJ2N02A909V0/data.parquet
```

### Two things that will mislead you

**Actors are HMAC pseudonyms, not identities.** From segment column-schema
`signalloom.observations/v2` the columnar store holds `hmac_actor_hint`, `hmac_actor_id`,
`hmac_principal_id`, `hmac_session_id` and `hmac_impersonated_user` *instead of* the cleartext
fields. There is no `actor_hint` column to select. The values are keyed HMACs: you can group and
join on them to correlate one actor's activity across layers, and you cannot recover the ARN,
username or session from them. `raw_evidence_ref` is likewise replaced by `evidence_ref_digest`;
the evidence itself stays in the customer's bucket. `schema_version` tells you which schema a row
came from, so an erased identifier is distinguishable from an absent one.

**`description` is plaintext.** It is authored, one line per observation, and it is the one column
that may carry text from the observed event. Treat query output as potentially sensitive and handle
it as you would the events themselves.

## Procedure

### 1. Get the Parquet directory

With the pod stopped, copy the claim's contents out. In-cluster, against a scaled-down Deployment:

```bash
kubectl -n fe-signalloom scale deployment/signal-ingest --replicas=0
kubectl -n fe-signalloom debug node/"$NODE" -it --image=busybox -- \
  tar -C /host/var/lib/.../signal-store -cf - . | tar -C ./signal-store -xf -
```

If you can still exec into a running pod, `kubectl cp` the directory instead. Either way you end up
with a local directory; the rest of this runbook only needs that.

### 2. Query it

`duckdb` needs no configuration and no extension to read local Parquet. Substitute your directory
for `/tmp/signal-store-fixture`.

Observation count by layer — the first thing to ask, because it tells you which collectors were
actually feeding the store:

```bash
duckdb -c "SELECT layer, count(*) FROM read_parquet('/tmp/signal-store-fixture/**/*.parquet') GROUP BY 1"
```

```text
┌────────────────────────┬──────────────┐
│         layer          │ count_star() │
│        varchar         │    int64     │
├────────────────────────┼──────────────┤
│ application_saas       │            5 │
│ network_egress         │            5 │
│ cloud_control_plane    │            5 │
│ behavioural            │            5 │
│ identity_authorization │            5 │
│ endpoint_host          │            5 │
└────────────────────────┴──────────────┘
```

Confirm the schema before writing anything more specific. This is also how you check which schema
version you are dealing with:

```bash
duckdb -c "DESCRIBE SELECT * FROM read_parquet('/tmp/signal-store-fixture/**/*.parquet')"
```

```text
┌────────────────────────┬─────────────┬─────────┬─────────┬─────────┬─────────┐
│      column_name       │ column_type │  null   │   key   │ default │  extra  │
│        varchar         │   varchar   │ varchar │ varchar │ varchar │ varchar │
├────────────────────────┼─────────────┼─────────┼─────────┼─────────┼─────────┤
│ confidence             │ DOUBLE      │ YES     │ NULL    │ NULL    │ NULL    │
│ delegation_depth       │ BIGINT      │ YES     │ NULL    │ NULL    │ NULL    │
│ description            │ VARCHAR     │ YES     │ NULL    │ NULL    │ NULL    │
│ evidence_ref_digest    │ VARCHAR     │ YES     │ NULL    │ NULL    │ NULL    │
│ fidelity               │ VARCHAR     │ YES     │ NULL    │ NULL    │ NULL    │
│ hmac_actor_hint        │ VARCHAR     │ YES     │ NULL    │ NULL    │ NULL    │
│ hmac_actor_id          │ VARCHAR     │ YES     │ NULL    │ NULL    │ NULL    │
│ hmac_impersonated_user │ VARCHAR     │ YES     │ NULL    │ NULL    │ NULL    │
│ hmac_principal_id      │ VARCHAR     │ YES     │ NULL    │ NULL    │ NULL    │
│ hmac_session_id        │ VARCHAR     │ YES     │ NULL    │ NULL    │ NULL    │
│ id                     │ VARCHAR     │ YES     │ NULL    │ NULL    │ NULL    │
│ layer                  │ VARCHAR     │ YES     │ NULL    │ NULL    │ NULL    │
│ schema_version         │ VARCHAR     │ YES     │ NULL    │ NULL    │ NULL    │
│ source                 │ VARCHAR     │ YES     │ NULL    │ NULL    │ NULL    │
│ timestamp              │ BIGINT      │ YES     │ NULL    │ NULL    │ NULL    │
└────────────────────────┴─────────────┴─────────┴─────────┴─────────┴─────────┘
```

Note what is *not* there: no `actor_hint`, no `raw_evidence_ref`.

A sample row, showing the pseudonymised actor and the plaintext description together:

```bash
duckdb -c "SELECT schema_version, layer, hmac_actor_hint, description FROM read_parquet('/tmp/signal-store-fixture/**/*.parquet') ORDER BY timestamp LIMIT 3"
```

```text
┌────────────────────────────┬────────────────┬──────────────────────────────────────────────────────────────────┬────────────────────────────────────────────────────────┐
│       schema_version       │     layer      │                         hmac_actor_hint                          │                      description                       │
│          varchar           │    varchar     │                             varchar                              │                        varchar                         │
├────────────────────────────┼────────────────┼──────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────┤
│ signalloom.observations/v2 │ network_egress │ 5e8e2c64c7fd9fb63c805bf5130dc492db0cb53bfcd1b21989786416682889b8 │ fixture observation for the DuckDB last-resort runbook │
│ signalloom.observations/v2 │ network_egress │ 5e8e2c64c7fd9fb63c805bf5130dc492db0cb53bfcd1b21989786416682889b8 │ fixture observation for the DuckDB last-resort runbook │
│ signalloom.observations/v2 │ network_egress │ 5e8e2c64c7fd9fb63c805bf5130dc492db0cb53bfcd1b21989786416682889b8 │ fixture observation for the DuckDB last-resort runbook │
└────────────────────────────┴────────────────┴──────────────────────────────────────────────────────────────────┴────────────────────────────────────────────────────────┘
```

`timestamp` is a `BIGINT` of Unix nanoseconds, not a Parquet timestamp, so it needs converting
before it reads as a time:

```bash
duckdb -c "SELECT id, to_timestamp(timestamp/1000000000) AS ts FROM read_parquet('/tmp/signal-store-fixture/**/*.parquet') ORDER BY timestamp LIMIT 2"
```

```text
┌───────────┬──────────────────────────┐
│    id     │            ts            │
│  varchar  │ timestamp with time zone │
├───────────┼──────────────────────────┤
│ fixture-0 │ 2026-10-04 10:00:00+01   │
│ fixture-1 │ 2026-10-04 10:00:01+01   │
└───────────┴──────────────────────────┘
```

The rendered zone is DuckDB's local zone, not the stored value; the stored value is UTC.

## Reproducing the fixture used above

The output in this runbook came from a generated store, not from production, so it can be
regenerated and the commands re-checked whenever the schema moves:

```bash
export GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache CGO_ENABLED=0
cd d2-signalloom/apps/signal-ingest
SIGNAL_STORE_FIXTURE_DIR=/tmp/signal-store-fixture \
  go test -tags frostdb -run TestWriteDuckDBFixture -count=1 ./store/
```

That writes 30 observations across the six in-scope layers and flushes them, which is the step that
matters: without the flush the rows stay in the active in-memory block and the directory contains
no Parquet object at all. The generator is
[`duckdb_fixture_test.go`](../../../d2-signalloom/apps/signal-ingest/store/duckdb_fixture_test.go);
it uses a fixed HMAC root key and fixed timestamps, so the values above are reproducible, and it
fails if the flush produces no Parquet.

## Limits

- **Read-only.** Never write to the claim out of band. FrostDB owns the directory and its
  attestation high-water mark; an edited or rewritten segment invalidates the signature chain that
  the segment verifier checks.
- **Unflushed data is invisible.** Anything still in the active block is not in any Parquet file.
  What you read is the flushed backlog, not necessarily everything accepted.
- **No tenant enforcement.** The API applies tenant scoping; a direct Parquet read does not. You
  are seeing every tenant's rows, which is a reason to treat the output accordingly and a reason
  this is a break-glass procedure rather than a reporting tool.
- **Pseudonyms are per key and epoch.** HMAC values from stores keyed differently are not
  comparable, so do not join across them.

## Related

- [`../../../d2-signalloom/apps/signal-ingest/base/pvc.yaml`](../../../d2-signalloom/apps/signal-ingest/base/pvc.yaml)
  — the claim that makes the backlog outlive a pod
- [`../../../d2-signalloom/apps/signal-ingest/store/FROSTDB_BENCHMARK.md`](../../../d2-signalloom/apps/signal-ingest/store/FROSTDB_BENCHMARK.md)
  — measured write throughput of the same store
