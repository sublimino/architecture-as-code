# SFDP-P1-2 — legacy grouping contradicts zero false merges

Status: **FAIL — semantic hard blocker, implementation stopped.**

Base: `76b439c0` on `integration/signal-fusion-v0.1.0`. The isolated
runtime worktree passes `git merge-base --is-ancestor
integration/signal-fusion-v0.1.0 HEAD`. No integration merge is authorized.

## Reproduction

`correlation/legacy_resolution_blocker_test.go` runs the real default-rule
engine against the memory store, with a fixed timestamp and separate
ground-truth principal labels. It does not introduce a resolver or change
production code. Both observations have suggestive fidelity; their layers
are `identity_authorization` and `network_egress`.

| Labelled fixture | Sources | Actor hints | Legacy actor ID | False merges |
| --- | --- | --- | --- | --- |
| Same-principal control | shared-egress / shared-egress | alice / alice | actor-spiffe://test/alice | 0 |
| Distinct principals sharing source/time | shared-egress / shared-egress | alice / bob | actor-src-shared-egress | **1** |
| Distinct-principal separate-source control | shared-egress / other-egress | alice / bob | none (no match) | 0 |

Hints in the fixture are full `spiffe://test/alice` and `spiffe://test/bob`
strings. Each emitted actor has both original observation IDs in its evidence
chain. The distinct-source control returning no actor is legacy behaviour,
not a claim that a future resolver should drop unresolved observations.

Run from this worktree's `d2-signalloom/apps/signal-ingest` directory:

```sh
env LC_ALL=C LANG=C \
  GOMODCACHE=/tmp/opencode/sfdp-go/pkg/mod \
  GOCACHE=/tmp/opencode/sfdp-go/build \
  go test ./correlation/... -run '^TestLegacyResolutionBlocker$' -count=2 -v
```

Observed exit: **0**, with the following line on both runs:

```text
legacy actor_id="actor-src-shared-egress" actors=1 false-merge=1; required acceptance false-merge=0
```

**This is a passing characterization of a blocking defect, not a passing
acceptance test. SFDP-P1-2 is failed.** The test explicitly expects the
observed legacy defect. Once a revised contract authorizes a grouping
change, replace this characterization with the zero-false-merge gate.

## Why this triggers the declared STOP

1. `rules.go:21-24`: `timing_correlation` matches different layers sharing
   source and a five-minute window, without comparing principal hints.
2. `engine.go:137-147`: a positive match invokes `mergeIntoActor`.
3. `engine.go:205-213`: different nonempty hints bypass the preferred hint
   key and fall back to the identical source.
4. `engine.go:167-193`: the single source-derived actor receives both
   principals' evidence links.

Exact legacy grouping equivalence therefore preserves a false merge.
Separating the principals necessarily changes grouping. New additive fields
cannot change that logical contradiction for existing observations with
zero-valued additions. Calling the aggregate provisional does not solve it:
the same actor ID and evidence membership are what downstream identity and
attestation consumers would receive.

Independent Architect and Engineer reviews confirmed the conflict and the
reproducer's positive/negative controls. No choice between these semantics
has been silently made.

## Required deliverables and gates: qualified status

| Requirement | Evidence / status |
| --- | --- |
| Public Resolve and Correlate merge-site wiring | Not implemented: STOP applies before refactoring |
| Additive Observation / ProvisionalActor fields, omitempty and old-wire compatibility | Not implemented; production models unchanged |
| Stable actor ID derivation and typed unresolved contract | Not implemented; no new contract claimed |
| Composite-key-to-typed-input mapping | Not implemented; legacy fallback traced above |
| Equivalence versus legacy on labelled fixtures | Logical conflict demonstrated; no resolver equivalence claimed |
| Discriminator false-merge == 0 | **Fails in required legacy reference: observed 1** |
| FrostDB schema, memory mirror, round-trip and query negative space | Not implemented or verified |
| `make test-signal-ingest-frostdb` | Not run after semantic STOP; not green |
| `make test-signal-ingest` | Attempted with isolated caches; fails compiling runtime/cgo: `/usr/include/stdc-predef.h: Permission denied` |
| `go test -race ./... -count=1` | Not run after semantic STOP; not green |
| Resolve / Equivalence / ObsToMap / Rules / Promote / Deterministic / Unresolved acceptance selections | No new implementation, so not represented as completed acceptance gates |
| Builds with and without frostdb | Not verified |
| Repeated-run evidence | Reproducer ran twice with identical IDs and false-merge counts; not full resolver restart proof |
| Promotion / EvidenceLink behaviour preserved | Production code untouched; no post-refactor proof claimed |
| Live-mode / runtime-proven integration | Not performed; reserved for P1-GOV with P1-1 |
| Collector harness, main.go, CEL expressions | Untouched |
| Commit and proposal errata | Evidence-only commit; failure errata and Result recorded separately in the proposal |

The initial focused invocation also encountered an unreadable default Go
module cache (`.../cel-go/@v/v0.30.0.ziphash: permission denied`). Selecting
isolated writable caches enabled the focused reproduction without changing
the base, modules, build tags, or engine. The broader cgo permission failure
is separate from the proven semantic blocker; no cgo disabling or green
claim substitutes for the required suites.

## Required decision

**Escalate / re-plan:** explicitly authorize changing legacy grouping for
contradictory principals (and specify how unresolved/timing-only matches are
represented), or explicitly narrow the legacy-equivalence domain with
documented exceptions. Neither is authorized by this card. Do not integrate
this as a completed P1-2 implementation or advance dependent identity cards.
The Governor retains the joint P1-1/P1-2 integration boundary.
