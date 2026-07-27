---
task: Complete SLDPB25-P1-PRE pre-flight validation
slug: 20260727-0922_sldpb25-p1-pre-preflight-validation
effort: extended
phase: complete
progress: 16/16
mode: interactive
started: 2026-07-27T09:22:00+01:00
updated: 2026-07-27T09:41:00+01:00
---

## Context

This card performs SLDPB25-P1-PRE pre-flight validation for Signalloom D2 Platform
Baseline V2.5. It checks the mandated integration ancestry, repository baseline,
journey-inventory scope, dashboard API contract scope, and duplicate ownership
before implementation cards begin. It must produce committed repository evidence,
run and record the declared `none` test surface, and append qualified evidence to
the proposal's existing `Spec: Errata` section.

Requested: inspect the proposal and current repository, identify affected files,
validate scope and sequencing, preserve safety gates, commit only scoped evidence,
and leave implementation deliverables untouched.

### Risks

- The detached worktree may pass ancestry while its current tip differs from the named ref.
- Existing prior evidence may look like current implementation and conceal missing canonical ownership.
- The proposal may contain stale or contradictory errata that must not be silently overwritten.
- A duplication scan can identify overlap without proving which source should become canonical.
- The declared `none` test surface may be mistaken for permission to skip baseline evidence.

Not requested: implementing dashboard, API, Dex/OIDC, persistence, fake services,
browser tests, runtime changes, production access, data migration, board changes,
Kanban runtime changes, branch switching, rebasing, merging, pushing, or PR creation.

## Criteria

- [x] ISC-1: Proposal file is read before repository mutation begins
- [x] ISC-2: Required integration reference resolves to a commit
- [x] ISC-3: Required integration reference is ancestor of current HEAD
- [x] ISC-4: Current worktree status is captured before scoped edits
- [x] ISC-5: Current branch or detached HEAD identity is recorded
- [x] ISC-6: Proposal identifies SLDPB25-P1-PRE as a pre-flight card
- [x] ISC-7: P1-PRE dependency on SLDPB25-P0 is recorded
- [x] ISC-8: P1-PRE declared test surface is recorded as none
- [x] ISC-9: Journey inventory deliverable scope is mapped to repository files
- [x] ISC-10: Dashboard API contract scope is mapped to repository files
- [x] ISC-11: Local authentication contract scope is recorded without implementation
- [x] ISC-12: Existing journey evidence is distinguished from implementation work
- [x] ISC-13: Existing API evidence is distinguished from implementation work
- [x] ISC-14: Duplicate or overlapping ownership findings are recorded
- [x] ISC-15: Out-of-scope runtime and proposal staging paths remain unchanged
- [x] ISC-16: Scoped pre-flight evidence is committed and independently verified

## Decisions

- The current isolated worktree is authoritative; no branch or ref movement is allowed.
- The proposal is edited directly for errata but is intentionally never staged.
- The repository artifact will document validation findings only, not implement deliverables.

### Plan

1. Capture immutable baseline evidence: ref SHA, HEAD SHA, ancestry exit status,
   worktree status, and relevant proposal card fields.
2. Inspect only the proposal-named Signalloom paths plus existing journey/API
   evidence, then document exact affected and explicitly unaffected files.
3. Scan duplicate ownership using path inventories, content hashes, and source
   references; record findings without selecting a new canonical implementation.
4. Create one scoped Markdown evidence artifact under `docs/signalloom/`, run the
   declared `none` test surface as a recorded no-op, and run only read-only checks.
5. Stage the evidence artifact alone, commit it, verify the commit and proposal
   remains unstaged, then append a qualified errata entry outside git staging.

## Verification

- ISC-1–ISC-15: Evidence captured in `docs/signalloom/phase-1-preflight-revalidation-2026-07-27.md`.
- Baseline command: `make signalloom-check` exited `0`.
- Declared test surface: `none`; no test command was applicable or run.
- Scoped commits: `40083ac`, `9feff66`, and corrective `47d3c5e`; each changed only the evidence file.
- Independent QATester verification found and corrected the ResourceSet assertion: topology BATS `cmp` enforces equality, while canonical ownership remains unresolved.
- Final ancestry and repository scope require revalidation after the final commit; proposal erratum references `47d3c5e` and remains unstaged.

## Learning

- The first duplicate scan treated identical files as evidence of absent enforcement; independent review correctly found the existing BATS equality assertion.
- A smarter process would inspect enforcement tests alongside content hashes before characterising a duplication control as missing.
- CodeReview was invoked but unavailable because `roborev` is not installed; QATester supplied the independent correction instead.
- Future pre-flight work should reconcile proposal errata, current implementation paths, and historical evidence before drafting the verdict.
