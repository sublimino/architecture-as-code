---
task: Repair live SLDPB25 dependency graph links
slug: 20260727-101700_repair-live-sldpb25-dependency-graph-links
effort: standard
phase: complete
progress: 7/12
mode: interactive
started: 2026-07-27T10:17:00+01:00
updated: 2026-07-27T10:26:00+01:00
---

## Context

Repair only the live Kanban dependency graph for shortcode `SLDPB25` after Governor `90403` was trashed and replacement Governor `aafb0` was created. The reported defects are missing R3 P3-PRE → P2-GOV and orphaned R5 P1-PRE/P2-GOV dependencies. Use the approved Kanban CLI and preserve edge direction. Do not create cards, hand-edit `board.json`, or change code, proposals, or integration references.

### Risks

- A stale trashed identifier could be selected from historical output.
- CLI dependency syntax may reverse the intended edge direction.
- R5 inheritance may require a source edge not named in the report.

## Criteria

- [ ] ISC-1: Approved Kanban CLI command is identified before graph mutations.
- [ ] ISC-2: Live SLDPB25 task inventory is inspected through approved CLI.
- [ ] ISC-3: Canonical live P3-PRE task identifier is recorded.
- [ ] ISC-4: Canonical live P2-GOV identifier equals aafb0.
- [ ] ISC-5: Canonical live P1-PRE task identifier is recorded.
- [ ] ISC-6: R3 predecessor edge targets live P2-GOV task.
- [ ] ISC-7: R5 P1-PRE predecessor edge targets canonical inherited dependency.
- [ ] ISC-8: R5 P2-GOV predecessor edge targets canonical inherited dependency.
- [ ] ISC-9: Every added edge uses preserve-direction CLI option.
- [ ] ISC-10: No Kanban card is created during repair.
- [ ] ISC-11: Link-check reports no SLDPB25 graph defect.
- [ ] ISC-12: Branch-check result is captured after link repair.

## Decisions

- Inspect the live inventory before reconstructing inherited dependencies.
- Treat `aafb0` as the only valid live P2 Governor.
- Canonical recreated P1-PRE is `28d82`; canonical P0 is `a4e53`.
- Canonical P2 implementation IDs are `a6639`, `458b1`, `cfac6`, and `afee5`.
- The approved CLI rejects every link containing a done/trash endpoint.
- The approved helper untrashed `28d82` and `aafb0`; no task was created.

## Verification

- [x] ISC-1: `kanban-check.sh self-test` passed and exposed `--preserve-direction`.
- [x] ISC-2: Approved CLI inventory was inspected for shortcode `SLDPB25`.
- [x] ISC-3: Canonical live P3-PRE identifier recorded as `4ed47`.
- [x] ISC-4: Canonical replacement P2-GOV identifier verified as `aafb0`.
- [x] ISC-5: Canonical recreated P1-PRE identifier verified as `28d82`.
- [x] ISC-10: No `task create` command was issued during this repair.
- [x] ISC-12: `branch-check` exited 0; it reported five pre-existing orphan-worktree warnings.
- [ ] ISC-6/7/8/9/11: Blocked. `task link --preserve-direction` rejects the remaining required done/trash prerequisite endpoints. Latest `link-check` exits 1 with R5 P2-GOV orphan and R1 P3-PRE discovery warnings.
