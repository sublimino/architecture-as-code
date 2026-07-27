---
task: Safely repair Signalloom integration ancestry drift
slug: 20260726-232400_repair-integration-ancestry
effort: advanced
phase: complete
progress: 24/24
mode: interactive
started: 2026-07-26T23:24:00+01:00
updated: 2026-07-26T23:29:00+01:00
token_estimate: 12000
---

## Context

Repair the isolated Signalloom task worktree so `integration/signalloom-d2-v2.5.0` is an ancestor of its HEAD. Preserve all unrelated tracked and untracked work already present, avoid board, remote, push, and PR changes, and record command-backed evidence. The current task worktree is on an older integration branch and has unrelated dirty state, so safety requires inspecting the full worktree topology and preserving before altering branch ancestry.

### Risks

- Switching the dirty worktree could overwrite or conflict with unrelated work.
- Rewriting the existing integration branch could disrupt another worktree.
- A target branch might already be checked out elsewhere, requiring a new local task branch.

### Plan

Capture refs, worktrees, and dirty paths; create an immutable backup reference for the current HEAD; then create a new task branch whose base is the required v2.5 integration commit without checking out or resetting away unrelated filesystem state. Verify ancestry and preservation using path snapshots. The precise Git operation is contingent on worktree topology.

## Criteria

- [x] ISC-1: Current branch name is captured before ancestry repair.
- [x] ISC-2: Current HEAD SHA is captured before ancestry repair.
- [x] ISC-3: Required integration ref resolves to a commit.
- [x] ISC-4: Initial required ancestry check exit code is recorded.
- [x] ISC-5: Tracked pre-existing changes are captured before repair.
- [x] ISC-6: Untracked pre-existing paths are captured before repair.
- [x] ISC-7: Repository worktree topology is captured before repair.
- [x] ISC-8: Target branch checkout location is identified before repair.
- [x] ISC-9: Repair strategy preserves tracked pre-existing changes.
- [x] ISC-10: Repair strategy preserves untracked pre-existing paths.
- [x] ISC-11: Repair strategy avoids destructive reset operations.
- [x] ISC-12: Repair strategy avoids forced branch updates.
- [x] ISC-13: Repair strategy avoids remote repository writes.
- [x] ISC-14: Repair strategy avoids board.json modifications.
- [x] ISC-15: Backup reference records original task branch HEAD.
- [x] ISC-16: Repaired task worktree HEAD contains required integration history.
- [x] ISC-17: Repaired ancestry command exits zero.
- [x] ISC-18: Final branch name is recorded after repair.
- [x] ISC-19: Final HEAD SHA is recorded after repair.
- [x] ISC-20: Pre-existing tracked changes remain present after repair.
- [x] ISC-21: Pre-existing untracked paths remain present after repair.
- [x] ISC-22: Repair evidence is written to a scoped artifact.
- [x] ISC-23: Repository review capability is invoked before verification.
- [x] ISC-24: Final verification records no push or pull request.

## Decisions

- The v2.5 integration ref (`c95ac2f`) fast-forwards the current v2.0 task ref (`4bdfc29`). Create a backup ref, then use compare-and-swap `git update-ref` to move only the checked-out local task branch. This leaves index and worktree bytes untouched and requires neither checkout nor reset.

## Verification

- Pre-repair: branch `integration/signalloom-d2-v2.0.0`; HEAD `4bdfc2912b1d75fa73baa5fe58893817a4b47e3e`; target `c95ac2f02c1fe73adfed9af9ed7f815f3254ee2a`; required ancestry exited 1.
- Topology showed the v2.5 integration branch checked out separately under the task worktree's nested `worktrees/signalloom-d2-v2.5.0/governor` path.
- Tracked and untracked snapshots were captured before repair; final snapshots retained the same five unstaged tracked paths and the recorded untracked task artifacts. `board.json` remains absent from status.
- Created backup `safety/signalloom-d2-v2.0.0-pre-v2.5-20260726-2326` at original HEAD `4bdfc2912b1d75fa73baa5fe58893817a4b47e3e`.
- Used only compare-and-swap `git update-ref` fast-forwards: old task HEAD to `c95ac2f`, then to concurrently advanced v2.5 target `4abd4c8e8b2ea667bed49074478a85ffa6a32859`. No checkout, reset, merge, rebase, force update, remote operation, push, or PR occurred.
- Final: branch `integration/signalloom-d2-v2.0.0`; HEAD and required target both `4abd4c8e8b2ea667bed49074478a85ffa6a32859`; `git merge-base --is-ancestor integration/signalloom-d2-v2.5.0 HEAD` exited 0.
- CodeReview capability was invoked; roborev is not installed, so no automated review results were available.
- Obsidian proposal received `kanban-check status=pass proceed=yes blocking_drift=no` with repair evidence.
