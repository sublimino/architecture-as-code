---
name: cp-sl-drift-sweep
description: "Two-axis codebase drift, multi-agent churn, and code-smell remediation sweeper for the #partner-signal-loom platform. Runs Matt Pocock's two-axis review (Standards + Fowler smell baseline vs Spec + proposal sprawl) across branch history, emits a partitioned Cleanup Job Manifest, pauses for approval by default (or executes end-to-end with --auto / /goal) using isolated git worktrees, shared helper extraction, mandatory fail-to-fix mutation proofs, and sequential fast-forward merges. USE WHEN drift sweep, clean up drift and mess, review jobs, multi-agent churn cleanup, consolidate proposals, deduplicate boilerplate, cp-sl-drift-sweep, /cp-sl-drift-sweep, or on schedule '0 4 * * *'."
---

# cp-sl-drift-sweep

Two-axis codebase drift auditor and parallel worktree remediation orchestrator for the **Signal Loom** (`#partner-signal-loom`) platform.

## Loop Lens & Execution Contract

- **Cadence**: `0 4 * * *` (Daily post-sprint sweep, or on demand after a multi-agent commit wave).
- **Trigger**: `/cp-sl-drift-sweep`, `/cp-sl-drift-sweep --auto`, `/goal`, or manual prompt "sweep repo drift and mess".
- **Default Mode (`PAUSE_FOR_APPROVAL`)**:
  - Executes **Phase 1 (Two-Axis Drift & Churn Triage)** via `Tools/drift-sweep.sh`, presents the findings along both axes (**Standards** and **Spec**) plus the partitioned **Cleanup Job Manifest**, and **STOPS** for explicit user sign-off before creating worktrees or spawning remediation subagents.
- **Autonomous Flag (`--auto` or `/goal` active)**:
  - Proceeds automatically from Phase 1 through **Phase 2 (Shared Pattern & Worktree Partitioning)**, **Phase 3 (Parallel Subagent Execution with Mandatory Mutation Proofs)**, and **Phase 4 (Sequential Rebase, One-by-One Verification, Fast-Forward Merge & Teardown)**.
- **Brief**: Emit a 4-bullet executive status: (1) Standards & smell findings count, (2) Spec & proposal sprawl findings count, (3) Partitioned cleanup jobs ready/executed, (4) End-to-end verification and worktree hygiene status.

---

## Mandate & Non-Negotiable Invariants

1. **Two-Axis Separation (Never Merge Axes)**:
   - Always report **Axis A (Standards & Fowler Code Smells)** separately from **Axis B (Spec & Proposal Fidelity)** so neither masks the other.

2. **Worktree Isolation & 21-Day `osramp` Prune Rule**:
   - Remediation subagents MUST run in isolated git worktrees outside the repository root (`/tmp/osramp-worktrees/<job>` or `~/src/.worktrees/osramp-demo/<job>`), NEVER inside `$REPO_ROOT/.claude/worktrees/`.
   - Never prune existing worktrees unless they are strictly **> 21 days old**, of **`osramp` type**, and have a clean working tree (`git status --porcelain` is empty).

3. **Disjoint File Ownership Across Parallel Agents**:
   - Every remediation worktree must own a strictly non-overlapping set of file globs. Shared index files (such as `docs/README.md`) belong to at most one agent so sequential fast-forward merges (`git merge --ff-only`) never conflict.

4. **Shared Pattern Extraction Before Fan-Out**:
   - Before spawning code-refactoring agents, define the canonical helper contract per runtime (Go `httputil.go`, Python `normalize_allow` / `_gate_route`, TypeScript `http-gate.ts`) and verify static BATS grep tokens (`rg` across `test/*.bats`) so refactoring never breaks static contract tests.

5. **Mandatory Empirical Mutation Proof (Red → Green → Mutate-Red → Restore-Green)**:
   - Every subagent must prove its tests are falsifiable: apply a forced mutation to the implementation, confirm via `git diff` that the mutation landed on disk, run the test suite to observe a real assertion failure (no fake green-lights), and restore the code to green before committing.

6. **Sequential Rebase, One-by-One Test, Fast-Forward Merge**:
   - Never octopus-merge untested branches. Rebase each completed worktree branch onto the target branch tip, run its focused test suite, fast-forward merge one by one, run the full cross-cutting contract suite (`bats test/http-guard-dedup-contracts.bats test/worktree-hygiene.bats test/docs-index-sync.bats` and `make docs-lint`), and remove all temporary worktrees.

---

## Information Hierarchy

- **Primary Workflow**: [`Workflows/Sweep.md`](Workflows/Sweep.md)
- **Two-Axis Smell & Drift Reference**: [`References/DriftAndSmellBaseline.md`](References/DriftAndSmellBaseline.md)
- **Executable Drift Scanner**: [`Tools/drift-sweep.sh`](Tools/drift-sweep.sh)

---

## Execution Sequence

1. **Phase 1 — Two-Axis Drift & Churn Triage**:
   - Run `bash .agents/skills/cp-sl-drift-sweep/Tools/drift-sweep.sh [--base <ref>] [--auto]`.
   - Inspect Axis A (docs-lint, multi-pass file churn, duplicated boilerplate, worktree hygiene) and Axis B (proposal sprawl, unindexed records, uncommitted drift).
   - If `EXECUTION_MODE=PAUSE_FOR_APPROVAL` (no `--auto` and no `/goal`), present the **Cleanup Job Manifest** and wait for approval.
2. **Phase 2 — Shared Pattern Extraction & Worktree Creation**:
   - Create isolated worktrees for each approved job chunk and distribute shared runtime/toolchain rules.
3. **Phase 3 — Parallel Subagent Remediation & Mutation Proofs**:
   - Spawn one subagent per worktree (`invoke_subagent`) enforcing strict file boundaries and fail→fix mutation verification.
4. **Phase 4 — Sequential Rebase, Merge & End-to-End Verification**:
   - Rebase and test each branch one by one, fast-forward merge onto the active branch, run `make docs-lint` and `bats test/http-guard-dedup-contracts.bats`, and prune temporary worktrees.
