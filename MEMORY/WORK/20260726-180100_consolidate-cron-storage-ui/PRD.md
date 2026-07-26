---
task: Consolidate cron storage and fix UI plugin
slug: 20260726-180100_consolidate-cron-storage-ui
effort: standard
phase: complete
progress: 8/8
mode: interactive
started: 2026-07-26T18:01:00+01:00
updated: 2026-07-26T18:10:00+01:00
---

## Context

The live OpenCode process uses `~/.local/share/cpai-cron/cron.db`, while a stale legacy database exists at `~/.opencode/cpai-cron.db`. Andrew requested removal of the stale database and verification that the cron UI plugin reads the live path. Preserve the active scheduler database, its jobs, and its watcher.

### Risks

- The old database might be open; delete only after descriptor verification.
- The sidebar can be implemented correctly but omitted from configured plugins.
- Sidebar session ownership filtering can legitimately show zero for another session.

## Criteria

- [x] ISC-1: Legacy cron database file no longer exists.
- [x] ISC-2: Legacy cron WAL companion file no longer exists.
- [x] ISC-3: Legacy cron SHM companion file no longer exists.
- [x] ISC-4: Active cron database retains supervisor job record.
- [x] ISC-5: Active OpenCode process holds active cron database.
- [x] ISC-6: UI plugin defines the active cron database path.
- [x] ISC-7: UI plugin queries jobs from active database.
- [x] ISC-8: UI plugin contains no legacy database path.

## Decisions

- Remove only the inactive legacy SQLite database and sidecars after confirming no process holds them.
- Treat `~/.local/share/cpai-cron/cron.db` as the canonical live scheduler store.

## Verification

- `~/.opencode/cpai-cron.db`, its WAL, and its SHM are absent.
- PID 1392293 holds the canonical database plus its WAL and SHM.
- The active database contains enabled `sld21-kanban-supervisor` for this session.
- `cron-state.ts` resolves the canonical XDG data path for scheduler and sidebar.
- `cron-sidebar.tsx` opened the live database and returned the supervisor job.
- `opencode.json` registers `./plugins/cron-sidebar.tsx` beside the scheduler.
