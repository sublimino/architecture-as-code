---
task: Stage commit and clean preflight worktree
slug: 20260727-000500_stage-commit-and-clean-preflight-worktree
effort: standard
phase: execute
progress: 4/8
mode: interactive
started: 2026-07-27T00:05:00+01:00
updated: 2026-07-27T00:08:00+01:00
---

## Context

Stage and commit the existing changes in this integration worktree, then verify
the Kanban pre-flight worktree state so other Governor agents can continue.
The request does not authorize deleting unrelated active worktrees or changing
source content beyond the existing working-tree changes.

### Risks

- Staging everything could include unrelated generated files.
- Cleaning the wrong worktree could disrupt another active agent.
- The bundled Bats test currently lacks its expected helper path.

## Criteria

- [x] ISC-1: Current worktree branch is identified before mutation
- [x] ISC-2: Existing tracked modifications are enumerated before staging
- [x] ISC-3: Existing untracked files are enumerated before staging
- [x] ISC-4: Kanban self-test passes before cleanup validation
- [ ] ISC-5: All current-worktree files are staged intentionally
- [ ] ISC-6: A commit records the staged current-worktree files
- [ ] ISC-7: Post-commit worktree has no pending changes
- [ ] ISC-8: Pre-flight worktree validation reports no actionable orphan

## Decisions

- Use the current integration worktree as the mutation boundary.
- Run the skill-owned `branch-check.bats` test with only temporary test-path
  compatibility if its bundled relative helper is unavailable.
- Do not remove another agent's active worktree without direct evidence it is
  an orphan and outside the current task scope.

## Verification
