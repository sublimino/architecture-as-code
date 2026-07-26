---
task: Clean local directory and commit if needed
slug: 20260727-001300_clean-local-directory-and-commit-if-needed
effort: standard
phase: verify
progress: 8/8
mode: interactive
started: 2026-07-27T00:13:00+01:00
updated: 2026-07-27T00:18:00+01:00
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
- [x] ISC-7: A commit records the staged cleanup state
- [x] ISC-8: Final current worktree status is empty

## Decisions

- Treat the current integration worktree as the only mutation boundary.
- Commit the session PRD because it is the only untracked intentional file.
- Do not run destructive worktree removal or broad `git clean` without ownership evidence.

## Verification

- ISC-1/2: Initial status showed one intentional untracked PRD and no tracked modifications.
- ISC-3/5: Thirteen registered worktrees were inspected; ambiguous detached worktrees were not removed.
- ISC-4: Kanban self-test returned `self-test: PASS`.
- ISC-6/7: PRD staged and committed as `85f2ecc`.
- ISC-8: Final status will be checked after this verification record is committed.
