---
task: Commit task changes onto V2.5 integration branch
slug: 20260726-232700_commit-task-changes-v25-integration
effort: extended
phase: plan
progress: 0/18
mode: interactive
started: 2026-07-26T23:27:00+01:00
updated: 2026-07-26T23:30:00+01:00
---

## Context

Commit the pending isolated task changes from the current detached task worktree and transfer that commit onto `integration/signalloom-d2-v2.5.0`. The integration checkout must be discovered through `git worktree list --porcelain`, verified on the named branch, and protected with an untracked-inclusive stash before cherry-picking. Any original integration edits must be restored afterward. No reset, clean, worktree removal, repository-path deletion, push, PR, or unrelated editing is permitted.

## Criteria

- [ ] ISC-1: Current task worktree identity is recorded before staging.
- [ ] ISC-2: Pending task files are identified before staging begins.
- [ ] ISC-3: Pre-existing task files remain excluded from staged changes.
- [ ] ISC-4: Task changes are committed with a focused message.
- [ ] ISC-5: Task commit hash is recorded after commit succeeds.
- [ ] ISC-6: Worktree metadata identifies integration checkout location.
- [ ] ISC-7: Integration checkout branch equals required branch name.
- [ ] ISC-8: Integration worktree status is recorded before stashing.
- [ ] ISC-9: Integration changes are stashed when status is nonempty.
- [ ] ISC-10: Stash reference is recorded when a stash is created.
- [ ] ISC-11: Task commit cherry-picks onto integration branch successfully.
- [ ] ISC-12: Cherry-pick conflicts preserve intended task changes.
- [ ] ISC-13: Cherry-pick conflicts preserve integration user changes.
- [ ] ISC-14: Created stash is restored after cherry-pick completion.
- [ ] ISC-15: Stash-pop conflicts preserve pre-existing integration changes.
- [ ] ISC-16: Integration HEAD contains the task commit changes.
- [ ] ISC-17: Final integration commit hash is recorded.
- [ ] ISC-18: Final integration commit message is recorded.
