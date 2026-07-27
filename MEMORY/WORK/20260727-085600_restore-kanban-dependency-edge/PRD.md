---
task: Restore one safe Kanban dependency edge
slug: 20260727-085600_restore-kanban-dependency-edge
effort: standard
phase: complete
progress: 8/8
mode: interactive
started: 2026-07-27T08:56:00+01:00
updated: 2026-07-27T09:06:00+01:00
---

## Context

Restore precisely one missing active-board dependency for `SLDPB25-P1-PRE` in `/home/andy/src/cp/osramp-demo`. The repair must use the approved Kanban CLI/helper and `--preserve-direction`; it must not hand-edit `board.json`, modify code or the proposal, or change the main checkout or integration branch. Historical and trash-card dependencies must remain untouched.

### Risks

The graph checker indexes active cards only. Inventory showed P0 and Phase 1 completion cards as historical/trash, so their preserved edges cannot repair P1-PRE's active orphan state. The active Phase 2 Governor is the valid live completion boundary; it must wait on P1-PRE.

## Criteria

- [x] ISC-1: Target repository resolves to the requested osramp-demo checkout.
- [x] ISC-2: SLDPB25 task inventory identifies the live P1-PRE card.
- [x] ISC-3: Reviewed dependency specification names P0 as P1-PRE prerequisite.
- [x] ISC-4: Repair command includes the preserve-direction option.
- [x] ISC-5: Repair command creates exactly one active board edge.
- [x] ISC-6: Repair command does not edit board.json directly.
- [x] ISC-7: Historical card dependencies remain outside repair command scope.
- [x] ISC-8: Final link-check reports no orphaned P1-PRE task.

## Decisions

- Original contract is P1-PRE → P0, but P0 is historical/trash. Preserve that relationship and add the only valid active completion boundary: P2-GOV → P1-PRE.

## Verification

- ISC-1: Canonical repository path passed to every Kanban command.
- ISC-2: Active inventory identified P1-PRE as task `3683e`.
- ISC-3: Reviewed scaffold specifies P1-PRE → P0; P0 is historical/trash in live inventory.
- ISC-4/5: Approved locked CLI command created preserved edge `90403` → `3683e` (dependency `9adbd549`).
- ISC-6: The mutation was `task link`; no runtime JSON file was edited.
- ISC-7: Existing historical/trash edges were neither deleted nor changed.
- ISC-8: Post-mutation link-check has zero failures and no P1-PRE orphan.
