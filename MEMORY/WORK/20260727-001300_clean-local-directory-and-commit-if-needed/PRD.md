---
task: Clean local directory and commit if needed
slug: 20260727-001300_clean-local-directory-and-commit-if-needed
effort: standard
phase: execute
progress: 6/8
mode: interactive
started: 2026-07-27T00:13:00+01:00
updated: 2026-07-27T00:17:00+01:00
---

## Context

Recheck the current integration worktree after the previous cleanup, identify
any remaining local changes, and commit only files that are intentionally part
of this repository's session state. Do not remove other agent worktrees without
clear stale-ownership evidence.

### Risks

- Detached worktrees may still contain active Governor context.
- Ignored files may be useful local runtime state.
- The session PRD itself is the only current untracked file.

## Criteria

- [x] ISC-1: Current worktree status is inspected before cleanup
- [x] ISC-2: Current untracked paths are enumerated before cleanup
- [x] ISC-3: Registered worktrees are inspected for ownership evidence
- [x] ISC-4: Kanban self-test passes during cleanup verification
- [x] ISC-5: Ambiguous agent worktrees remain untouched
- [x] ISC-6: Intentional remaining file is staged for commit
- [ ] ISC-7: A commit records the staged cleanup state
- [ ] ISC-8: Final current worktree status is empty

## Decisions

- Treat the current integration worktree as the only mutation boundary.
- Commit the session PRD because it is the only untracked intentional file.
- Do not run destructive worktree removal or broad `git clean` without ownership evidence.

## Verification
