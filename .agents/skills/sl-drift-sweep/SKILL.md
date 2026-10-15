---
name: sl-drift-sweep
description: "Six-phase codebase drift, architectural deepening, and code-smell sweeper for #partner-signal-loom. Orchestrates 12 bundled Matt Pocock skills across Standards, Spec, and Architecture axes. Pauses by default or runs end-to-end with explicitly approved --auto. USE WHEN drift sweep, clean up drift, review jobs, sl-drift-sweep, /sl-drift-sweep, or on schedule '0 4 * * *'."
---

# sl-drift-sweep

Whole-codebase drift auditor, architectural deepening scanner, and parallel worktree remediation orchestrator for the **Signal Loom** (`#partner-signal-loom`) platform.

### Separation from Sibling Skills
- **`sl-drift-sweep` (this skill)**: Audits static codebase health, Fowler code smells, multi-agent file churn, and micro-proposal sprawl across git commit history.
- **`sl-drift-reconcile`**: Audits live in-cluster Kubernetes state and Flux reconciliation against committed git artifacts (`git rev-parse HEAD`).

## Loop Lens & Execution Contract

- **Cadence**: `0 4 * * *` (Daily post-sprint sweep, or on demand after a multi-agent commit wave).
- **Trigger**: `/sl-drift-sweep`, `/sl-drift-sweep --auto`, `/goal`, or manual prompt "sweep repo drift and mess".
- **Default Mode (`PAUSE_FOR_APPROVAL`)**:
  - Executes **Phase 1 (Two-Axis Drift & Bug Triage)**, **Phase 2 (Whole-Codebase Architectural Deepening Scan)**, and **Phase 3 (Tracer-Bullet Job Decomposition)**. Presents the report and **Cleanup Job Manifest**, then **STOPS** for user sign-off.
- **Autonomous Flag (`--auto`, only after explicit approval)**:
  - Runs Phase 1 through **Phase 4 (Worktrees & Mutation Proofs)**, **Phase 5 (Rebase & Merge)**, and **Phase 6 (Retro & Guardrails)**.
  - An active `/goal` never enables autonomous execution by itself. Without explicit approval and `--auto`, remain in `PAUSE_FOR_APPROVAL` mode.
- **Brief**: Emit 4 bullets: (1) Standards and Spec findings, (2) Deepening candidates, (3) Tracer-bullet jobs, and (4) Verification and retro status.

---

## 12 Integrated Matt Pocock Skills (Bundled in This Skill)

| Phase | Bundled Skill | Role in `sl-drift-sweep` |
|---|---|---|
| **Phase 1: Two-Axis Review** | [`code-review`](vendor/pocock-skills/code-review/SKILL.md) | Parallel **Standards** (Fowler smells) vs **Spec** review |
| **Phase 1: Red Build Triage** | [`diagnosing-bugs`](vendor/pocock-skills/diagnosing-bugs/SKILL.md) | Tight red loop, minimise, rank 3 to 5 falsifiable hypotheses |
| **Phase 2: Deepening Scan** | [`improve-codebase-architecture`](vendor/pocock-skills/improve-codebase-architecture/SKILL.md) | Whole-codebase scan for shallow modules and deletion-test seams |
| **Phase 2 & 4: Seam Design** | [`codebase-design`](vendor/pocock-skills/codebase-design/SKILL.md) | Deep-module vocabulary and parallel `DESIGN-IT-TWICE.md` interfaces |
| **Phase 2: TS Boundaries** | [`setup-ts-deep-modules`](vendor/pocock-skills/setup-ts-deep-modules/SKILL.md) | Enforce package root entry points and hide internal subtrees |
| **Phase 2: ADR Consolidation** | [`domain-modeling`](vendor/pocock-skills/domain-modeling/SKILL.md) | Consolidate micro-proposals into ADRs and sharpen `GLOSSARY.md` |
| **Phase 3: Job Decomposition** | [`to-tickets`](vendor/pocock-skills/to-tickets/SKILL.md) | Decompose into tracer bullets or expand-contract batches with blocking edges |
| **Phase 4: Seam TDD** | [`tdd`](vendor/pocock-skills/tdd/SKILL.md) | Vertical red-green slices at public seams, paired with mutation proofs |
| **Phase 4: Implementation** | [`implement`](vendor/pocock-skills/implement/SKILL.md) | Scoped worktree execution per ticket or batch |
| **Phase 6: Post-Sweep Retro** | [`retro`](vendor/pocock-skills/retro/SKILL.md) | Turn mechanical agent mistakes into deterministic BATS or linter checks |
| **Phase 6: Agent Docs Pruning** | [`writing-for-agents`](vendor/pocock-skills/writing-for-agents/SKILL.md) | Prune `AGENTS.md` sediment, sharpen pointers, and cut no-op prose |
| **Phase 6: Git Guardrails** | [`git-guardrails-claude-code`](vendor/pocock-skills/git-guardrails-claude-code/SKILL.md) | Block destructive git operations and in-repo worktrees |

---

## Mandate & Non-Negotiable Invariants

1. **Three-Axis Separation (Never Merge Axes)**:
   - Report **Axis A (Standards & Fowler Code Smells)**, **Axis B (Spec & Proposal Fidelity)**, and **Axis C (Architectural Depth & Seams)** separately.

2. **Containment Remains Authoritative**:
   - Never resume, restart, reconcile, replace, or otherwise mutate a stunned or contained workload during a drift sweep. Treat containment state as an immutable boundary and defer containment verification to [`sl-containment-guard`](../sl-containment-guard/SKILL.md).

3. **Worktree Isolation & 21-Day `osramp` Prune Rule**:
   - Remediation subagents MUST run in isolated git worktrees under `~/src/.worktrees/osramp-demo/<job>`, NEVER inside `$REPO_ROOT/.claude/worktrees/` or an ad hoc `/tmp` worktree root.
   - Never prune existing worktrees unless they are strictly **> 21 days old**, of **`osramp` type**, and have a clean working tree (`git status --porcelain` is empty).

4. **Disjoint File Ownership & Blocking Edges (`to-tickets`)**:
   - Every remediation worktree must own a non-overlapping set of file globs. Shared index files (such as `docs/README.md`) belong to at most one agent so sequential fast-forward merges (`git merge --ff-only`) never conflict.

5. **Shared Seam Design Before Fan-Out (`codebase-design`)**:
   - Define canonical helpers per runtime (`httputil.go`, `normalize_allow` / `_gate_route`, `http-gate.ts`) before fan-out. Check BATS grep tokens (`rg` across `test/*.bats`) so refactoring preserves contract tests.

6. **Mandatory Empirical Mutation Proof (`tdd` + Diff Proof)**:
   - Every subagent must prove its tests are falsifiable. Apply a forced mutation, confirm `git diff` is non-empty, observe a real assertion failure, and restore the code to green before committing.

7. **Sequential Rebase, One-by-One Test, Fast-Forward Merge, and Retro (`retro`)**:
   - Rebase each branch onto the target tip, run its focused test suite, and fast-forward merge one by one. Run the cross-cutting contract suite (`bats test/http-guard-dedup-contracts.bats test/worktree-hygiene.bats test/docs-index-sync.bats` and `make docs-lint`), remove temporary worktrees, and convert new mechanical findings into automated checks.

---

## Information Hierarchy

- **Primary Workflow**: [`Workflows/Sweep.md`](Workflows/Sweep.md)
- **Three-Axis & Deep-Module Reference**: [`References/DriftAndSmellBaseline.md`](References/DriftAndSmellBaseline.md)
- **Executable Drift Scanner**: [`Tools/drift-sweep.sh`](Tools/drift-sweep.sh)
- **Bundled Upstream Notice**: [`vendor/pocock-skills/THIRD_PARTY_NOTICES.md`](vendor/pocock-skills/THIRD_PARTY_NOTICES.md)

---

## Completion Criteria

- **Clarity**: Emit the scanner verdict line (`STATUS: CLEAN` or `STATUS: DRIFT_DETECTED`) with its Standards, Spec, and job counts. Report Axis C as `ARCHITECTURE_STATUS=UNVERIFIED` until a human or agent review covers it.
- **Demand**: In `PAUSE_FOR_APPROVAL` mode, stop after the Cleanup Job Manifest. In approved `--auto` mode, every job carries a mutation proof (Green, Mutate-Red, Restore-Green), a sequential fast-forward merge, and worktree teardown.
