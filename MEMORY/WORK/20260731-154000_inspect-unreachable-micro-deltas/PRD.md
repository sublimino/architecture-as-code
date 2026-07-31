---
task: Identify missed micro-deltas in unreachable commit contents
slug: 20260731-154000_inspect-unreachable-micro-deltas
effort: extended
phase: complete
progress: 16/16
mode: interactive
started: 2026-07-31T15:40:00+01:00
updated: 2026-07-31T15:41:00+01:00
---

## Context

Andrew requested a path-level review of source-relevant unreachable commits to find any useful small deltas omitted from the authoritative feature branch. This review must compare actual file content and current behavior, not infer solely from reachability. It must recommend only independently justified, minimal additions.

## Criteria

- [x] ISC-1: Every source-relevant unreachable commit is enumerated.
- [x] ISC-2: API candidate content is compared against feature files.
- [x] ISC-3: Dashboard candidate content is compared against feature files.
- [x] ISC-4: OIDC candidate content is compared against feature files.
- [x] ISC-5: Fleet candidate content is compared against feature files.
- [x] ISC-6: Runtime candidate content is compared against feature files.
- [x] ISC-7: SPIRE candidate content is compared against feature files.
- [x] ISC-8: Bao candidate content is compared against feature files.
- [x] ISC-9: Acceptance candidate content is compared against feature files.
- [x] ISC-10: Test-only candidate content is compared against feature files.
- [x] ISC-11: Explicit reverts are excluded from recovery recommendations.
- [x] ISC-12: Checkpoint objects are excluded from recovery recommendations.
- [x] ISC-13: Duplicate snapshots are excluded from recovery recommendations.
- [x] ISC-14: Potential micro-deltas have concrete feature absence evidence.
- [x] ISC-15: Recommended micro-deltas have focused validation commands.
- [x] ISC-16: Final recommendation reports each candidate disposition.

## Decisions

- A historic hunk needs current feature absence and independent value evidence.

## Verification

- Feature object `df8a47a` contains the Dex API client and trusted peer, proof-helper exchange flow, JWT configuration, bootstrap recreation, proof resets, and the least-privilege gateway-routes role.
- The only absent historical artifact is the RETEST-1 snapshot suite; its assertions target superseded topology and are covered by current resilience and focused contract suites.
