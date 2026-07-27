---
task: Tidy workspace, preserve memories, commit necessary changes
slug: 20260727-072600_tidy-workspace-preserve-memories-commit
effort: standard
phase: complete
progress: 8/8
mode: interactive
started: 2026-07-27T07:26:00+01:00
updated: 2026-07-27T07:36:00+01:00
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

- [x] ISC-1: Current repository status is recorded before cleanup.
- [x] ISC-2: Changed repository paths are classified before staging.
- [x] ISC-3: Task memory record is retained inside repository workspace.
- [x] ISC-4: Existing task-memory records remain unmodified by cleanup.
- [x] ISC-5: Staged paths contain only intended repository changes.
- [x] ISC-6: Commit captures every intended staged repository change.
- [x] ISC-7: New commit message describes the committed workspace changes.
- [x] ISC-8: Final repository working tree reports no pending changes.

## Decisions

- Preserve existing files and commit the complete current repository delta only after reviewing its scope.
- Restore deleted task records; commit only tracked and untracked memory records.
- Preserve local `AGENTS.md` metadata without committing its machine-specific paths.

## Verification

- Initial status recorded one modified PRD, three deleted PRDs, 31 untracked
  memory directories, and untracked local `AGENTS.md` metadata.
- Engineer review classified the deleted PRDs for restoration and all memory
  records for one documentation-only commit. `AGENTS.md` was excluded locally
  because it contains worktree-specific absolute paths.
- `git diff --cached --check` passed before commit.
- Commit `920c6133dd96e866bcc8adc2a08b888647f39ed5` is GPG-signed and titled
  `docs(signalloom): preserve task work records`.
- `git show --check HEAD` and `git diff --check` passed.
- CodeReview was invoked for the last commit; roborev is unavailable locally.
- The final metadata commit records this verification; its subsequent clean
  status check satisfies ISC-8.
