---
task: Integrate task commit into v2.5 branch
slug: 20260727-071000_integrate-signalloom-task-commit
effort: standard
phase: observe
progress: 0/8
mode: interactive
started: 2026-07-27T07:10:00+01:00
updated: 2026-07-27T07:10:00+01:00
---

## Context

Safely commit pending task changes and integrate the resulting commit into
`integration/signalloom-d2-v2.5.0`. Preserve existing worktree changes, use a
stash only when the target worktree is dirty, and resolve conflicts without
discarding user edits. No destructive Git commands or repository-path deletes
are permitted.

## Criteria

- [ ] ISC-1: Current task worktree pending changes are committed.
- [ ] ISC-2: Integration branch worktree location is identified.
- [ ] ISC-3: Target worktree checks out required integration branch.
- [ ] ISC-4: Target pre-existing changes are preserved before cherry-pick.
- [ ] ISC-5: Task commit is cherry-picked into integration branch.
- [ ] ISC-6: Cherry-pick conflicts preserve intended and existing changes.
- [ ] ISC-7: Target stash is restored after cherry-pick completion.
- [ ] ISC-8: Final integration commit hash and message are verified.

## Decisions

- Follow the requested worktree/stash/cherry-pick protocol exactly.

## Verification

- Pending execution.
