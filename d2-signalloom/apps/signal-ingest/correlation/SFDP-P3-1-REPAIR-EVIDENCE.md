# SFDP-P3-1 authorized SPIFFE-priority repair

Recorded 2026-09-05 20:03:12+01:00. This is a **repair checkpoint, not
complete delivery or Governor merge authorization**.

## Change

Supervisor-authorized remediation of the cardinal failure recorded in
`SFDP-P3-1-BLOCKER.md`. `identifierLess` places SPIFFE identifiers before generic
principal aliases, then uses the existing typed serialization as the tie-breaker.
Both `contractIdentifiers` (public Resolve / ResolvePair) and `representative`
(Engine epochs) use that same total order. Fixing just the former would leave
Engine re-sorting to the generic Kubernetes account.

The original `TestCardinalResolveDistinctTrustDomainsFalseMergeZero` is unchanged.
The new `TestSPIFFEFirstRepresentativeAcrossResolutionEntryPoints` supplies the
same-principal positive control, checks exact IDs through three entry points,
retains a distinct-domain twin, and compares reordered Engine partitions.

## Executed evidence

Working directory: isolated runtime worktree
`/home/andy/src/.worktrees/461f2/osramp-demo`, resolving via `pwd` to
`/home/andy/.cline/worktrees/461f2/osramp-demo`.

- `git merge-base --is-ancestor integration/signal-fusion-v0.1.0 HEAD`: exit 0
  before changes, at checkpoint `c428f346037c52d09fe75ae5f6bf9c291fd6f6c5`.
- From signal-ingest, with `LC_ALL=C LANG=C`,
  `GOCACHE=/tmp/opencode/go-cache-sfdp`, and
  `GOMODCACHE=/tmp/opencode/go-mod-sfdp`:
  - `go test ./correlation -run '^TestCardinalResolveDistinctTrustDomainsFalseMergeZero$' -count=1 -v`:
    exit 0 after repair.
  - `CGO_ENABLED=0 go test ./correlation -run 'Test(CardinalResolveDistinctTrustDomainsFalseMergeZero|SPIFFEFirstRepresentativeAcrossResolutionEntryPoints)$' -count=1 -v`:
    exit 0; both tests pass.
  - `CGO_ENABLED=0 go test ./... -count=1`: exit 0, complete cluster-free suite.
  - `go test ./... -count=1`: exit 1 at runtime/cgo compilation.
  - `go test -race ./correlation ./model -count=1`: exit 1 at runtime/cgo
    compilation, before any race-instrumented tests execute.
  - The race command also fails with the proposal preflight cache
    `GOCACHE=/tmp/gocache`. Both shell and context-mode execution paths fail.

Operative compiler error:

```text
# runtime/cgo
<command-line>: fatal error: /usr/include/stdc-predef.h: Permission denied
compilation terminated.
```

`CGO_ENABLED=0` is only cluster-free unit evidence. It is not race evidence and
cannot waive the required race lane. Compiler header access requires an external
execution-grant/environment repair; this card does not alter sandbox policy.

## Review and outstanding acceptance

Four independent read-only audits inspected the implementation, test assertions,
store seam, and epoch logic. `code_review(mode=dirty)` could not run because
roborev is not installed. No review-tool pass is claimed.

These inherited gaps remain unremediated and must be handled before delivery:

- Weak edges are attached to actors after confidence calculation; their numeric
  contribution is not integrated. Do not describe edge attachment as confidence
  accumulation.
- Negative rules still filter entire observations instead of producing only
  cannot-link constraints; the weak candidate store can retain filtered endpoints.
- Edge retraction currently adds a pairwise cannot-link. Its conservative
  identity-dispute semantics differ from simply deleting one redundant edge.
- Split-representative suffixes are asymmetric; canonical ID reuse can transfer
  promotion to a different component after retraction. Review promotion lineage.
- Concurrent writers mutate the resolver store before taking the epoch lock.
  Memory maps are locked, but intermediate input/epoch consistency needs testing.
- Existing concurrency test ignores Resolve errors and lacks a serial oracle.
  The thousand-observation stress test checks count, not exact mixed-edge output.
- Strengthen clock-skew/window, replay provenance, candidate-limit, and populated
  serialization coverage. Keep every labelled false-merge assertion intact.

No newly failing labelled fixture was observed in this retry. The authorized
trust-domain regression is repaired. This does not certify the other requirements.

## Boundaries and next action

Only correlation files changed in this retry. No DB, collector, HTTP, Makefile,
deployment, sibling, runtime state, push, PR, or integration merge changes.
Governor reconciliation remains pending. Restore required compiler header access,
complete the outstanding acceptance work, then rerun full unit and race lanes.
The proposal must remain `status=fail proceed=no blocking_drift=no` until then.
