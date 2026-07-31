---
task: Assess unreachable commits for feature branch inclusion
slug: 20260731-153000_assess-unreachable-feature-commits
effort: standard
phase: complete
progress: 8/8
mode: interactive
started: 2026-07-31T15:30:00+01:00
updated: 2026-07-31T15:31:10+01:00
---

## Context

Andrew requested a fresh assessment of unreachable commits and whether they belong on `feat/signal-loop-and-bootstrap-refactor`. The feature branch already contains the merged main lineage. This is read-only classification; inclusion requires a missing, intended behavior with supporting evidence.

### Risks

- Patch identity can differ despite equivalent behavior after refactoring.
- Checkpoint commits can resemble source commits by changed path.

## Criteria

- [x] ISC-1: Unreachable commits are enumerated from the object database.
- [x] ISC-2: Source-relevant commits are separated from orchestration artifacts.
- [x] ISC-3: Each source candidate has changed paths inspected.
- [x] ISC-4: Each source candidate is compared against feature behavior.
- [x] ISC-5: Reverted candidates are identified from commit topology.
- [x] ISC-6: Duplicate candidates are identified using patch comparison.
- [x] ISC-7: Missing intended behavior is identified with implementation evidence.
- [x] ISC-8: Recommendation lists inclusion decisions for every candidate.

## Decisions

- Do not restore a commit solely because it is unreachable.

## Verification

- Fresh Git fsck found 206 unreachable commits and 18 source-relevant candidates.
- All 18 are superseded, duplicate, explicitly reverted, or checkpoint/autostash objects.
- No feature-branch modification is warranted.
