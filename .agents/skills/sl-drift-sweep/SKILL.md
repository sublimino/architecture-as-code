---
name: sl-drift-sweep
description: "Two-axis codebase drift and code-smell remediation sweeper for #partner-signal-loom. Runs Standards and Spec review across branch history. Pauses by default or runs end-to-end with --auto. USE WHEN drift sweep, codebase drift, code smell sweep, two-axis drift, clean up drift, sl-drift-sweep, or on schedule '0 4 * * *'."
---

# sl-drift-sweep

Two-axis codebase drift auditor and parallel worktree remediation orchestrator for the **Signal Loom** (`#partner-signal-loom`) platform.

### Separation from Sibling Skills
- **`sl-drift-sweep` (this skill)**: Audits static codebase health, Fowler code smells, multi-agent file churn, and micro-proposal sprawl across git commit history.
- **`sl-drift-reconcile`**: Audits live in-cluster Kubernetes state and Flux reconciliation against committed git artifacts (`git rev-parse HEAD`).

## Loop Lens & Schedule Contract

- **Cadence**: `0 4 * * *` (Daily post-sprint sweep, or on demand after a multi-agent commit wave).
- **Trigger**: `/sl-drift-sweep`, `/sl-drift-sweep --auto`, `/goal`, or manual prompt "sweep repo drift and mess".
- **Default Mode (`PAUSE_FOR_APPROVAL`)**:
  - Executes **Phase 1 (Two-Axis Drift & Churn Triage)** via `Tools/drift-sweep.sh`. Presents the **Standards** and **Spec** findings plus the **Cleanup Job Manifest**, then **STOPS** for user sign-off.
- **Autonomous Flag (`--auto` or `/goal` active)**:
  - Proceeds automatically from Phase 1 through **Phase 2 (Worktree Partitioning)**, **Phase 3 (Parallel Subagents with Mutation Proofs)**, and **Phase 4 (Rebase, Merge & Teardown)**.
- **Brief**: Emit a 4-bullet status: (1) Standards findings, (2) Spec findings, (3) Cleanup jobs ready or executed, and (4) Verification and hygiene status.

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
   - Define canonical helpers per runtime (`httputil.go`, `normalize_allow` / `_gate_route`, `http-gate.ts`) before fan-out. Check BATS grep tokens (`rg` across `test/*.bats`) so refactoring preserves contract tests.

5. **Mandatory Empirical Mutation Proof (Red → Green → Mutate-Red → Restore-Green)**:
   - Every subagent must prove its tests are falsifiable. Apply a forced mutation, confirm `git diff` is non-empty, observe a real assertion failure, and restore the code to green before committing.

6. **Sequential Rebase, One-by-One Test, Fast-Forward Merge**:
   - Never octopus-merge untested branches. Rebase each branch onto the target tip, run its focused test suite, and fast-forward merge one by one. Run the cross-cutting contract suite (`bats test/http-guard-dedup-contracts.bats test/worktree-hygiene.bats test/docs-index-sync.bats` and `make docs-lint`), then remove temporary worktrees.

---

## Information Hierarchy

- **Primary Workflow**: [`Workflows/Sweep.md`](Workflows/Sweep.md)
- **Two-Axis Smell & Drift Reference**: [`References/DriftAndSmellBaseline.md`](References/DriftAndSmellBaseline.md)
- **Executable Drift Scanner**: [`Tools/drift-sweep.sh`](Tools/drift-sweep.sh)

---

## Execution Sequence

1. **Phase 1 — Two-Axis Drift & Churn Triage**:
   - Run `bash .agents/skills/sl-drift-sweep/Tools/drift-sweep.sh [--base <ref>] [--auto]`.
   - Inspect Axis A (docs-lint, multi-pass file churn, duplicated boilerplate, worktree hygiene) and Axis B (proposal sprawl, unindexed records, uncommitted drift).
   - If `EXECUTION_MODE=PAUSE_FOR_APPROVAL` (no `--auto` and no `/goal`), present the **Cleanup Job Manifest** and wait for approval.
2. **Phase 2 — Shared Pattern Extraction & Worktree Creation**:
   - Create isolated worktrees for each approved job chunk and distribute shared runtime/toolchain rules.
3. **Phase 3 — Parallel Subagent Remediation & Mutation Proofs**:
   - Spawn one subagent per worktree (`invoke_subagent`) enforcing strict file boundaries and fail→fix mutation verification.
4. **Phase 4 — Sequential Rebase, Merge & End-to-End Verification**:
   - Rebase and test each branch one by one, fast-forward merge onto the active branch, run `make docs-lint` and `bats test/http-guard-dedup-contracts.bats`, and prune temporary worktrees.

---

## Completion Criteria

- **Clarity**: Two-axis verdict (`CLEAN` or `DRIFT_DETECTED` with explicit counts for Axis A Standards and Axis B Spec).
- **Demand**: In interactive mode (`PAUSE_FOR_APPROVAL`), pause after emitting the Cleanup Job Manifest for approval. In `--auto` mode, subagents execute with empirical mutation falsifiability proofs (Red → Green → Mutate-Red → Restore-Green), sequential rebase, fast-forward merge, and clean worktree teardown.
