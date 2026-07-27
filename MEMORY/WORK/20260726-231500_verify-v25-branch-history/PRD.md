---
task: Verify V2.5 branch history and classify orphan commits
slug: 20260726-231500_verify-v25-branch-history
effort: standard
phase: complete
progress: 8/8
mode: interactive
started: 2026-07-26T23:15:00+01:00
updated: 2026-07-26T23:21:00+01:00
---

## Context
Andrew asked to continue the clean-history audit rather than stop for clarification. The target is the V2.5 integration branch and its relationship to the V2.0.0 base, current main, active task worktrees, and repository-wide unreachable objects. This is read-only: no commits, resets, deletions, rebases, or worktree cleanup are requested.

### Risks
- Current `main` may have advanced independently from the V2.5 integration branch.
- Unreachable objects may be stale historical work or active detached worktree commits.
- Signature output can corrupt naïve line-based commit parsing.
- Worktree filesystem state may differ from Git branch reachability.

## Criteria
- [x] ISC-1: V2.5 integration worktree reports no uncommitted changes
- [x] ISC-2: V2.5 branch ancestry relative to V2.0.0 is measured
- [x] ISC-3: V2.5 branch ancestry relative to current main is measured
- [x] ISC-4: V2.5 recent history is readable without signature noise
- [x] ISC-5: Active task worktree heads are enumerated separately
- [x] ISC-6: Repository-wide unreachable commits are counted safely
- [x] ISC-7: Unreachable commits are not misclassified as branch orphans
- [x] ISC-8: Any ancestry drift is reported without destructive changes

## Decisions
- Preserve all worktrees and unreachable objects until ownership is confirmed.
- Treat commits in active task worktrees as pending work, not orphans.
- Use machine-readable Git output with signature display disabled.
- Compare V2.5 against both V2.0.0 and current `main`; do not repair drift during this audit.

## Verification
- ISC-1: Dedicated V2.5 worktree at `worktrees/signalloom-d2-v2.5.0/governor` is clean.
- ISC-2: V2.5 is six commits ahead and zero behind V2.0.0.
- ISC-3: V2.5 is 90 commits ahead and one behind current `main`; `main` is not an ancestor.
- ISC-4: `git log --no-show-signature` produced clean recent history, headed by `5feea13`.
- ISC-5: Nine worktrees were enumerated; detached `9856262` heads are isolated as pending active work.
- ISC-6: `git fsck --no-reflogs --unreachable` counted 78 repository-level unreachable commits.
- ISC-7: Unreachable objects are not on the V2.5 ref; active detached heads were classified separately.
- ISC-8: No commits, resets, deletions, rebases, or cleanup actions were performed.
