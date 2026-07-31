---
task: Preserve commits and establish feature branch authority
slug: 20260731-150000_establish-feature-branch-authority
effort: advanced
phase: complete
progress: 24/24
mode: interactive
started: 2026-07-31T15:00:00+01:00
updated: 2026-07-31T15:05:20+01:00
---

## Context

Andrew explicitly set the goal: no commits may be lost, and `feat/signal-loop-and-bootstrap-refactor` must become the source of truth. The current feature branch is 62 commits ahead of `main`; `main` has 28 unique commits. A merge forecast reports seven conflicts. Reconciliation must preserve both branch lineages, resolve conflicts in an isolated worktree, verify outcomes, and avoid touching existing dirty worktrees.

### Risks

- Merge resolution can silently discard one branch's intended behavior.
- Existing worktrees may contain uncommitted work requiring preservation.
- Sparse checkout can block application-level validation.
- Current remote tracking refs may be stale during reconciliation.

### Plan

Create date-stamped safety refs, merge `main` into a detached copy of the feature tip, resolve each conflict using both branch versions as evidence, validate in isolation, then advance the feature ref only after ancestry and test gates pass. Integration remains unchanged unless its dirty owner worktree can be handled safely.

## Criteria

- [x] ISC-1: Current main ref is recorded before reconciliation begins.
- [x] ISC-2: Current feature ref is recorded before reconciliation begins.
- [x] ISC-3: Integration ref is recorded before reconciliation begins.
- [x] ISC-4: Main unique commit count is recorded before reconciliation.
- [x] ISC-5: Feature unique commit count is recorded before reconciliation.
- [x] ISC-6: Local worktree ownership is recorded before reconciliation begins.
- [x] ISC-7: Dirty worktree paths are recorded before reconciliation begins.
- [x] ISC-8: Immutable safety ref preserves original main tip.
- [x] ISC-9: Immutable safety ref preserves original feature tip.
- [x] ISC-10: Isolated worktree is created from feature branch head.
- [x] ISC-11: Main lineage is merged into isolated feature worktree.
- [x] ISC-12: Makefile conflict has an intentional resolution.
- [x] ISC-13: Fleet kustomization conflict has an intentional resolution.
- [x] ISC-14: Fleet SignalLoom manifest conflict has intentional resolution.
- [x] ISC-15: Gateway route conflict has an intentional resolution.
- [x] ISC-16: Legacy fleet manifest deletion has intentional resolution.
- [x] ISC-17: Acceptance script conflict has an intentional resolution.
- [x] ISC-18: Authentication setup conflict has an intentional resolution.
- [x] ISC-19: Playwright configuration conflict has an intentional resolution.
- [x] ISC-20: Reconciled commit contains original main ancestry.
- [x] ISC-21: Reconciled commit contains original feature ancestry.
- [x] ISC-22: Required static D2 validation commands pass.
- [x] ISC-23: Feature branch ref advances to reconciled commit.
- [x] ISC-24: Final topology shows feature as authoritative source branch.

## Decisions

- Preserve both original tips using immutable local safety refs.
- Perform reconciliation only in a new isolated worktree.
- Never reset, force-push, or alter an existing dirty worktree.
- Feature authority is established by a merge commit retaining both original tips.
- The legacy duplicated Signal Loom fleet manifest remains deleted.

## Verification

- ISC-1–7: pre-reconciliation refs, divergence, worktree ownership, and dirty paths were captured.
- ISC-8–9: annotated safety tags preserve the original main, feature, and integration tips.
- ISC-10–11: isolated recovery worktree merged main into the feature lineage.
- ISC-12–19: all seven merge conflicts were resolved according to the documented topology ownership policy.
- ISC-20–21: merge `a5a82ea` has parents `0d250f0` and `432faea`; final feature `df8a47a` descends from both.
- ISC-22: `make -C d2-signalloom test` passed 37 checks; API pytest passed 83 tests with 66 expected skips; fleet render passed using the required load-restrictor.
- ISC-23: `feat/signal-loop-and-bootstrap-refactor` now resolves to `df8a47a`.
- ISC-24: feature contains the original main and feature tips; root main remains unchanged.
- Integration remains at its safety-tip predecessor because its owned worktree has four unrelated local changes; feature is intentionally ahead and authoritative until that worktree is clean.
- Code review: roborev review jobs 32 and 33 were enqueued for the merge and follow-up commits.
- QA preparation: browser acceptance prerequisites and final integrated command were independently assessed; full runtime gate was attempted but timed out during cluster runtime validation after its static and API stages exposed then confirmed resolved contract defects.
