---
task: Add isolated backend schemas and integration tests
slug: 20260727-001500_isolated-backend-schemas-integration-tests
effort: advanced
phase: complete
progress: 1/24
mode: interactive
started: 2026-07-27T00:15:00+01:00
updated: 2026-07-27T00:24:00+01:00
---

## Context

Implement the scoped local persistence schema, migrations, deterministic seed data, and backend adapters in the isolated Signalloom task worktree. Cover PostgreSQL, Redis, MinIO, OpenBao, fake-integration-proxy, and fake backends with integration and negative tests. The worktree must be descended from `integration/signalloom-d2-v2.5.0` before mutation. Commit only the scoped repository changes. Append evidence and a machine-readable kanban check to the named proposal. Do not edit `board.json`, another worktree, remotes, or a pull request.

### Risks

The task worktree may again lack the required integration ancestor. Local service images or a cluster may be unavailable, requiring hermetic integration tests or a documented failure. Existing service boundaries may already encode adapters and migrations, so implementation must extend rather than duplicate them. The proposal is open in Obsidian; errata must be appended through Obsidian-aware tooling where available.

### Plan

1. Gate changes on the required integration ancestry.
2. If valid, inspect existing persistence and adapter conventions, then implement only the scoped extension and tests.
3. Run focused tests and quality checks, commit the scoped delta, and append pass evidence.
4. If invalid, make no scoped repository changes or commit; append an explicit machine-readable fail erratum with command evidence.

## Criteria

- [ ] ISC-1: Required integration ref is ancestor before repository mutation.
- [ ] ISC-2: Existing persistence boundary is identified before implementation begins.
- [ ] ISC-3: PostgreSQL schema migration defines required local platform tables.
- [ ] ISC-4: PostgreSQL migration has deterministic forward application behavior.
- [ ] ISC-5: Seed data creates deterministic local platform records.
- [ ] ISC-6: Redis adapter uses the isolated configured Redis endpoint.
- [ ] ISC-7: MinIO adapter uses the isolated configured MinIO endpoint.
- [ ] ISC-8: OpenBao adapter uses the isolated configured OpenBao endpoint.
- [ ] ISC-9: Proxy adapter targets the internal fake-integration-proxy service.
- [ ] ISC-10: Fake backend adapter returns deterministic local integration responses.
- [ ] ISC-11: Adapter configuration rejects absent required backend endpoints.
- [ ] ISC-12: Adapter configuration rejects nonlocal fake proxy targets.
- [ ] ISC-13: Migration integration test applies schema to PostgreSQL successfully.
- [ ] ISC-14: Seed integration test verifies expected PostgreSQL records.
- [ ] ISC-15: Redis integration test verifies isolated adapter operations.
- [ ] ISC-16: MinIO integration test verifies isolated adapter operations.
- [ ] ISC-17: OpenBao integration test verifies isolated adapter operations.
- [ ] ISC-18: Proxy integration test verifies fake service routing.
- [ ] ISC-19: Fake backend test verifies deterministic response payloads.
- [ ] ISC-20: Negative test rejects incomplete backend configuration.
- [ ] ISC-21: Negative test rejects external fake integration target.
- [ ] ISC-22: Focused test commands exit successfully with recorded evidence.
- [ ] ISC-23: Scoped repository changes are committed on task branch.
- [x] ISC-24: Proposal errata records machine-readable kanban check evidence.

## Decisions

- 2026-07-27 00:17: Use advanced effort because this spans persistence, adapters, tests, evidence, and commit.
- 2026-07-27 00:20: Treat integration ancestry as a hard safety constraint; no scoped mutation is permitted after exit 1.

## Verification

- ISC-1: `git merge-base --is-ancestor integration/signalloom-d2-v2.5.0 HEAD` exited 1, so the mutation gate failed.
- ISC-24: Proposal lines 456-476 contain canonical JSON and flat `kanban-check` fail status.
- Capabilities: FirstPrinciples, Delegation, Engineer Task, and CodeReview tool were invoked; roborev is unavailable locally.
- Final revalidation: ref `59d00c43de1481885d78327ff472ce775db7d626` remains non-ancestor of HEAD `86e6de27ed041ea98d64ece669ce474f4df58d3a`.
