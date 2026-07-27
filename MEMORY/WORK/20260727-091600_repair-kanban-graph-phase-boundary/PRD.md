---
task: Repair scoped kanban graph phase boundary safely
slug: 20260727-091600_repair-kanban-graph-phase-boundary
effort: standard
phase: complete
progress: 8/8
mode: interactive
started: 2026-07-27T09:16:00+01:00
updated: 2026-07-27T09:27:00+01:00
---

## Context

Repair only the live `SLDPB25` Kanban dependency defect in `/home/andy/src/cp/osramp-demo`. The live P0 harness-smoke card `a4e53` is backlog and has no dependency. The canonical lifecycle inventory shows the original Phase 1 pre-flight `3683e` is trashed, preserving its historical evidence. The requested phase boundary is `P1-PRE waits on P0`; no board JSON, proposal, repository code, or integration state may change.

### Risks

- Recreating a historical pre-flight card would discard lifecycle continuity without need.
- Starting ready work could start an unrelated Governor candidate; use dry-run only.
- Omitting `--preserve-direction` could reorient or later drop the repaired edge.

## Criteria

- [x] ISC-1: Skill-owned self-test reports preserve-direction link support.
- [x] ISC-2: Canonical inventory identifies active SLDPB25 card lifecycle states.
- [x] ISC-3: Canonical inventory identifies trashed P1 pre-flight card identifier.
- [x] ISC-4: P1 pre-flight waits on P0 through preserved direction.
- [x] ISC-5: Historical P1 pre-flight card identifier remains unchanged after restoration.
- [x] ISC-6: Link-check reports zero graph failures after repair.
- [x] ISC-7: Dry-run identifies P0 as an eligible ready card.
- [x] ISC-8: No task card starts during scoped graph repair.

## Decisions

- Preserve the original P1 pre-flight card `3683e` because P0 is active and not obsolete; untrash it through skill-owned lifecycle tooling so the restored edge remains live and historical card identity is retained.
- Create preserved edge `3683e → a4e53`; `3683e` waits on P0.

## Verification

- `self-test`: PASS; preserve-direction support available.
- Canonical inventory: P0 `a4e53` was backlog; P1-PRE `3683e` was trash.
- Skill-owned untrash restored `3683e` to backlog without recreating it.
- Link transport created dependency `fc376d3f`: waiter `3683e`, prerequisite `a4e53`, with `--preserve-direction`.
- Final phase checks: P0 blocks P1-PRE; P1-PRE waits on P0.
- Final `link-check`: all six rules pass; CRITICAL=0, FAIL=0, WARN=0.
- Final `start-ready` dry-run names only P0 `a4e53`; no `--apply` was issued.
