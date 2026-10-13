---
name: cp-sl-worktree-governor
description: "Scheduled-run multi-agent worktree and lease governor for #partner-signal-loom. Audits active worktrees, detects dirty files and stranded branches, checks Kanban controller leases, and prunes merged worktrees. USE WHEN clean worktrees, worktree audit, stale worktrees, kanban lease status, cp-sl-worktree-governor, or on schedule '0 */6 * * *'."
---

# cp-sl-worktree-governor

Scheduled multi-agent worktree hygiene and lease governor for the **Signal Loom** (`#partner-signal-loom`) platform.

## Loop Lens & Schedule Contract

- **Cadence**: `0 */6 * * *` (Every 6 hours, or before initiating large multi-agent cards).
- **Trigger**: Cron notification, `/cp-sl-worktree-governor`, or manual prompt "audit agent worktrees".
- **Checkpoint**: Push right. Scan all worktrees for dirty state and unpushed commits. Automatically report clean candidates for pruning. Never delete a dirty worktree or unmerged branch without explicit confirmation.
- **Brief**: Emit a 4-bullet status: (1) Total worktrees, (2) Dirty worktrees to preserve, (3) Merged worktrees safe to prune, and (4) Active Kanban leases.

---

## Mandate & Non-Negotiable Invariants

1. **Zero Data Loss (Preserve Dirty State)**:
   - NEVER prune or delete a worktree containing uncommitted files (`git status --porcelain` is non-empty) or commits not reachable from remote or integration branches.

2. **Principal Repository Isolation**:
   - Automated subagents must run in isolated worktrees (`~/src/.worktrees/...`), never directly inside the principal repository checkout (`/home/andy/src/cp/osramp-demo`).

3. **Kanban Lease Authority**:
   - Stale or expired controller lease locks (`state.lease.name`) must be audited via `kanban-check.sh doctor --repo .` to prevent controller deadlock.

4. **Integration Branch Sync**:
   - Worktree branch tips must regularly rebase onto the active feature or integration branch (`feat/signal-loop-and-bootstrap-refactor` or `integration/slsi-v0.1.0`) to avoid merge conflicts.

---

## Information Hierarchy

- **Primary Workflow**: [`Workflows/Govern.md`](Workflows/Govern.md)
- **Worktree Lifecycle Reference**: [`References/WorktreeLifecycle.md`](References/WorktreeLifecycle.md)
- **Executable Auditor**: [`Tools/worktree-audit.sh`](Tools/worktree-audit.sh)

---

## Execution Sequence

1. **Worktree Discovery**:
   - Execute `git worktree list --porcelain`.
   - Inspect paths under `~/src/.worktrees/` and `~/.cline/worktrees/`.

2. **Dirty & Commit Divergence Audit**:
   - For each worktree:
     - Check `git status --porcelain`.
     - Count commits ahead/behind the main integration branch:
       `git rev-list --count HEAD ^origin/integration/slsi-v0.1.0`.

3. **Kanban Controller Doctor**:
   - Execute `scripts/kanban-check.sh doctor --repo .` if kanban harness present.
   - Report active leases and blocked card states.

4. **Prune Candidate Identification**:
   - Mark worktrees whose branch is fully merged into the target branch as PRUNE_READY.
   - Report uncommitted or unmerged worktrees as PRESERVE.

---

## Completion Criteria

- **Clarity**: Complete ledger of every active worktree, its branch tip, dirty status, and action.
- **Demand**: All worktree paths evaluated, with zero accidental deletion of unpushed commits.
