---
task: Tidy workspace, preserve memories, commit necessary changes
slug: 20260727-072600_tidy-workspace-preserve-memories-commit
effort: standard
phase: execute
progress: 0/8
mode: interactive
started: 2026-07-27T07:26:00+01:00
updated: 2026-07-27T07:32:00+01:00
---

## Context

Andrew requested a tidy worktree, a commit for the changes that belong here,
and preserved memories. The cleanup must be surgical: classify existing paths
before staging, preserve prior task records, avoid destructive Git operations,
and leave no pending worktree changes.

### Risks

- Pending files may span unfinished parallel cards.
- Generated artifacts may conceal required source changes.
- A broad staging command could include unrelated files.
- Git hooks may reject an otherwise correctly scoped commit.

## Criteria

- [ ] ISC-1: Current repository status is recorded before cleanup.
- [ ] ISC-2: Changed repository paths are classified before staging.
- [ ] ISC-3: Task memory record is retained inside repository workspace.
- [ ] ISC-4: Existing task-memory records remain unmodified by cleanup.
- [ ] ISC-5: Staged paths contain only intended repository changes.
- [ ] ISC-6: Commit captures every intended staged repository change.
- [ ] ISC-7: New commit message describes the committed workspace changes.
- [ ] ISC-8: Final repository working tree reports no pending changes.

## Decisions

- Preserve existing files and commit the complete current repository delta only after reviewing its scope.
- Restore deleted task records; commit only tracked and untracked memory records.
- Preserve local `AGENTS.md` metadata without committing its machine-specific paths.

## Verification

- Pending status inspection, scoped staging, commit, review, and final clean-tree check.
