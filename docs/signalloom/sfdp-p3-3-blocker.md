# SFDP-P3-3: supersession provenance contract blocker

Status: **fail — not implemented, not runtime-proven**.

## Authorised baseline

Detached runtime worktree: `/home/andy/src/.worktrees/f92dd/osramp-demo`.
`git merge-base --is-ancestor integration/signal-fusion-v0.1.0 HEAD`
passed at `2efc851d`. No merge, push, sibling changes, or runtime board
mutation was performed.

## Blocking contract gap

The card requires benign crash-WAL-replay and compaction rewrites to retire
predecessor attestations through supersedes links. Its permitted hook is an
objstore bucket decorator receiving `Upload(ctx, name, reader)`.

The current integration does not supply a trusted predecessor relation:

- `d2-signalloom/apps/signal-ingest/store/frostdb.go:45-54` configures only
  `WithReadWriteStorage`; it does not enable WAL or a WAL storage path.
- The constructor exposes no compaction/replacement callback.
- Pinned FrostDB `TableBlock.Persist` uploads
  `<database>/<table>/<block ULID>/data.parquet`. These are additive block
  objects, not replacements of older sibling objects.
- The upload contract conveys neither source object identities nor a
  logical replacement commitment. New object names or equal individual
  rows are not sufficient evidence that old objects may be retired.

Implementing a supersedes field that remains unused would not satisfy the
required benign-rewrite evidence. Inferring predecessor retirement at this
boundary risks hiding deletion. A synthetic test manually supplying lineage
would not prove production wiring.

This is a stop under the card's decision policy for a plan that differs
materially from the implementation substrate. It is **not** a claim that
Parquet hashing, rotation, DSSE signing, or shared verification are impossible.
No tamper-detection failure was observed: that implementation was not built.

## Source evidence and provenance

Local `store/frostdb.go` was read directly. `go list -m -json
github.com/polarsignals/frostdb` identifies version
`v0.0.0-20260121113628-9e5cfe0171ad`. Local module-cache reads fail with
`EACCES`; this is an access restriction, not missing source.

Two read-only investigations examined the pinned upstream source. References
below are remote commit sources, **not** locally readable cache files:

- https://github.com/polarsignals/frostdb/blob/9e5cfe0171adff531d30a9df3e111686996f4a9f/store.go#L29-L61
- https://github.com/polarsignals/frostdb/blob/9e5cfe0171adff531d30a9df3e111686996f4a9f/db.go#L382-L387
- https://github.com/polarsignals/frostdb/blob/9e5cfe0171adff531d30a9df3e111686996f4a9f/table.go#L548-L623

`RotateBlock` is available and launches asynchronous persistence. Upload
observability is therefore feasible; the missing information is replacement
lineage, not a flush seam.

## Recommendation: escalate the scope decision

Choose explicitly between:

1. Authorising a production replacement/lineage contract above the bucket
   boundary, with replacement-first persistence and signed retirement before
   predecessor deletion; or
2. Declaring current persisted block objects append-only and deferring actual
   rewrite reconciliation until a real rewrite producer exists.

The worker must not silently select option 2: it removes an explicit
deliverable. No key lifecycle changes are needed for either option.

Separately, a signed monotonic counter cannot detect rollback of its own
checkpoint. The later implementation needs an independently retained tip,
such as protected high-water state under `.keys`, or independently verified
transparency-log state. State this alongside the threat-model restriction
that the attacker cannot modify `.keys`; a signature alone does not establish
freshness.

## Acceptance audit

| Required result | Evidence/status |
| --- | --- |
| Integration-derived isolated worktree | ancestry check passed |
| Persisted-byte hook and inducible rotation | feasible APIs identified; not implemented |
| Bounded attestor and overflow policy | not implemented or benchmarked |
| Shared segment/audit verifier and trust policy | not implemented |
| Production benign-rewrite reconciliation | blocked on trusted lineage contract |
| `make attested-test` / Archivista evidence | not run; no pass claimed |
| `make audit-anchor-tamper-demo` | not run; no divergence claimed |
| `make audit-anchor-verify` intact chain | not run; no pass claimed |
| Performance baseline, mutation matrix, rotation/revocation tests | not run |

Only this blocker report is delivered. It is not an implementation commit and
must not be reconciled as completion of SFDP-P3-3.

## HISTORICAL — RESOLVED (2026-09-05)

This report is retained as the historical record of the earlier scope decision.
Its title, opening failure status, stop statement, recommendation, and acceptance
table do **not** describe the current blocker state.

The decision described above as option 2 is now authorised: persisted FrostDB
block objects under `signaldb/observations/*/data.parquet` are treated as
strictly append-only. The absence of a trusted predecessor relation therefore no
longer blocks the append-only segment-attestation work. Supersession compaction,
predecessor retirement, and crash-WAL-replay reconciliation are explicitly
deferred until a real rewrite producer and trusted lineage contract exist.

This resolves the scope blocker; it is not fresh runtime or performance evidence.
It does not assert that the current Go or Python worktree is green, that a live
Archivista publication succeeded, or that the documented benchmark remains
representative after concurrent implementation changes.
