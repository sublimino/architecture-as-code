---
task: Repair live SLDPB25 dependency graph links
slug: 20260727-101700_repair-live-sldpb25-dependency-graph-links
effort: standard
phase: execute
progress: 0/12
mode: interactive
started: 2026-07-27T10:17:00+01:00
updated: 2026-07-27T10:19:00+01:00
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

## Verification
