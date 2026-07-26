---
task: Restore default Codex task model routing
slug: 20260726-182000_restore-codex-task-routing
effort: standard
phase: build
progress: 0/8
mode: interactive
started: 2026-07-26T18:20:00+01:00
updated: 2026-07-26T18:25:00+01:00
---

## Context

Andrew requires newly created Kanban tasks to default to his Codex subscription. CPAI LiteLLM Gateway must be used only when explicitly selected through `--via-gateway` or a sensitivity policy. Inspect the board backlog, task-launch defaults, and Kanban integration before changing routing.

## Criteria

- [ ] ISC-1: Active Kanban backlog agent assignments are inventoried.
- [ ] ISC-2: Active Kanban task launch commands are inventoried.
- [ ] ISC-3: Kanban default agent resolution is identified.
- [ ] ISC-4: Kanban skill default agent guidance is identified.
- [ ] ISC-5: Default task launches use Codex subscription credentials.
- [ ] ISC-6: Gateway launches require explicit via-gateway selection.
- [ ] ISC-7: Existing task agent assignments remain unchanged without approval.
- [ ] ISC-8: New-task routing behavior is verified with configuration evidence.

## Decisions

- Preserve existing board tasks until the default routing cause is verified.
- The initial evidence identifies skill-mandated `cpai-opencode` card overrides as the likely gateway routing cause.

## Verification
