# Workflow: Signal Loom Six-Phase Drift, Architecture & Guardrail Sweep

Execute after a multi-agent build wave, on scheduled cadence (`0 4 * * *`), or via `/sl-drift-sweep [--auto]`.

---

## Phase 1: Two-Axis Drift & Bug Triage (`code-review`, `diagnosing-bugs`)

### Step 1.1: Run the Automated Drift & Toolchain Scanner
```bash
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
cd "${REPO_ROOT}"

# Pass --auto only after explicit user approval. An active /goal is not approval.
bash .agents/skills/sl-drift-sweep/Tools/drift-sweep.sh "$@"
```

### Step 1.2: Execute Two-Axis Review & Triage Any Red Tests
- Consult [`code-review`](../vendor/pocock-skills/code-review/SKILL.md) to evaluate **Axis A (Standards & Fowler Code Smells)** and **Axis B (Spec Fidelity)** in parallel.
- If baseline tests fail, consult [`diagnosing-bugs`](../vendor/pocock-skills/diagnosing-bugs/SKILL.md). Build a tight red loop, minimise the repro, and rank 3 to 5 hypotheses before editing code.

---

## Phase 2: Whole-Codebase Architectural Deepening & Seam Scan (`improve-codebase-architecture`, `codebase-design`, `setup-ts-deep-modules`, `domain-modeling`)

### Step 2.1: Scan High-Churn Hot Spots & Whole-Codebase Seams
- Consult [`improve-codebase-architecture`](../vendor/pocock-skills/improve-codebase-architecture/SKILL.md) and [`codebase-design`](../vendor/pocock-skills/codebase-design/SKILL.md) ([`DEEPENING.md`](../vendor/pocock-skills/codebase-design/DEEPENING.md)).
- Weight high-churn files from `drift-sweep.sh` first, then scan across Go (`d2-signalloom/apps/*`), Python (`d2-agent-trust/`, `fe-signalloom/`, `olly-replica/`), and TypeScript (`dashboard-signalloom/`, `docs-signalloom/`, `test/acceptance/harness/`).
- Apply the **deletion test** to identify shallow pass-through modules and copy-pasted seams.

### Step 2.2: Audit TypeScript Entry-Point Boundaries & Consolidate ADRs
- Consult [`setup-ts-deep-modules`](../vendor/pocock-skills/setup-ts-deep-modules/SKILL.md) to verify TypeScript packages expose small root entry points and hide internal implementation subtrees.
- Consult [`domain-modeling`](../vendor/pocock-skills/domain-modeling/SKILL.md) ([`ADR-FORMAT.md`](../vendor/pocock-skills/domain-modeling/ADR-FORMAT.md), [`GLOSSARY-FORMAT.md`](../vendor/pocock-skills/domain-modeling/GLOSSARY-FORMAT.md)) to identify fragmented micro-proposals (`Mission: —` in `docs/README.md`) that should consolidate into a single canonical ADR.

---

## Phase 3: Tracer-Bullet Job Decomposition & Pause Gate (`to-tickets`)

### Step 3.1: Synthesize Three-Axis Report & Cleanup Job Manifest
Consult [`to-tickets`](../vendor/pocock-skills/to-tickets/SKILL.md) to partition findings into vertical tracer-bullet tickets or **expand–contract** batches for wide refactors. Present under three separate headings:
- **`## Axis A: Standards & Code Smell Findings`** (`docs-lint`, worktree hygiene, Fowler *Shotgun Surgery*, *Duplicated Code*, *Divergent Change*, *Speculative Generality*).
- **`## Axis B: Spec & Proposal Sprawl Findings`** (ungrouped micro-proposals, unindexed decision records, uncommitted working-tree drift).
- **`## Axis C: Whole-Codebase Architectural Deepening Candidates`** (shallow modules, missing shared seams, TypeScript boundary leaks).

Emit the numbered **Cleanup Job Manifest** with explicit `Blocked by` edges and disjoint file globs per job.

### Step 3.2: Approval Gate
- **Default, active `/goal`, or no explicit approval**:
  - **STOP HERE.** Ask Andrew to approve or adjust the Cleanup Job Manifest before creating worktrees or modifying code.
- **Explicit approval plus `--auto`**:
  - Continue immediately to Phase 4.

---

## Phase 4: Shared Seam Design & Parallel Isolated Worktree Execution (`codebase-design`, `tdd`, `implement`)

### Step 4.1: Commit or Triage Working Tree & Design Shared Interfaces Twice
- If the base branch has uncommitted work, stop and ask how to handle it. Never commit or revert pre-existing work without explicit approval. Every subagent must start from the same clean HEAD.
- For any new shared helper seam (`httputil.go`, `http-gate.ts`, `_gate_route`), apply [`DESIGN-IT-TWICE.md`](../vendor/pocock-skills/codebase-design/DESIGN-IT-TWICE.md) to compare candidate interfaces on **depth**, **payoff**, and **locality** before fan-out.

### Step 4.2: Provision Isolated Worktrees Outside `$REPO_ROOT`
Never create worktrees inside `$REPO_ROOT/.claude/worktrees/` or under `/tmp`. The authoritative root is `~/src/.worktrees/osramp-demo/`:
```bash
BASE_REF="$(git rev-parse --abbrev-ref HEAD)"
WT_ROOT="${HOME}/src/.worktrees/osramp-demo"
mkdir -p "$WT_ROOT"

for spec in \
  "cleanup-job1-hygiene:cleanup/job1-worktree-hygiene" \
  "cleanup-job3-docs-lint:cleanup/job3-docs-lint" \
  "cleanup-job4-proposals:cleanup/job4-proposals" \
  "cleanup-job5a-http-go:cleanup/job5a-http-go" \
  "cleanup-job5b-http-py-ts:cleanup/job5b-http-py-ts"
do
  dir="${spec%%:*}"
  branch="${spec##*:}"
  wt_path="$WT_ROOT/$dir"
  if [ -d "$wt_path" ]; then
    echo "ERROR: worktree path already exists: $wt_path" >&2
    exit 1
  fi
  git worktree add -b "$branch" "$wt_path" "$BASE_REF"
done
```

### Step 4.3: Parallel Subagent Execution & Mandatory Mutation Proof
Spawn chunk subagents concurrently. Each subagent follows [`tdd`](../vendor/pocock-skills/tdd/SKILL.md) and [`implement`](../vendor/pocock-skills/implement/SKILL.md) plus our **4-step Mutation Falsifiability Protocol**:
1. **Baseline Green**: Run the focused test suite (`go test`, `pytest`, `bun test`, or `bats`) at the public seam and confirm pass.
2. **Forced Mutation + Diff Proof**: Mutate the production helper or script (such as dropping `OPTIONS` from `Allow`). Assert `git diff <file>` is non-empty on disk.
3. **Mutated Red**: Re-run the test suite and confirm it exits non-zero on the expected assertion failure (never a syntax error or setup failure).
4. **Restored Green**: Restore the file, confirm `git diff` is clean, and re-run the test suite to confirm pass.

No remediation may resume, restart, reconcile, replace, or otherwise mutate a stunned or contained workload.

---

## Phase 5: Sequential Rebase, One-by-One Verification, Merge & Teardown

As subagents complete, integrate them sequentially onto the target branch (`$BASE_REF`) only after explicit approval for integration:

```bash
# For each completed worktree branch:
git -C "$WT_PATH" rebase "$BASE_REF"
# Run that chunk's focused test suite inside $WT_PATH
git -C "$REPO_ROOT" merge --ff-only "$BRANCH_NAME"
```

After all branches are fast-forward merged:
1. Remove only the worktrees created for the approved sweep. Never use a wildcard removal loop.
2. Run the full end-to-end verification battery on the target branch:
   ```bash
   make docs-lint
   make docs-lint-test
   bats test/worktree-hygiene.bats test/http-guard-dedup-contracts.bats test/sl-drift-sweep.bats
   ./scripts/check-worktree-hygiene.sh
   ```

---

## Phase 6: Post-Sweep Retro & Agent Guardrail Hardening (`retro`, `writing-for-agents`, `git-guardrails-claude-code`)

1. **Convert Mechanical Drift into Deterministic Checks ([`retro`](../vendor/pocock-skills/retro/SKILL.md))**:
   - Classify every drift finding fixed in the sweep: mechanical violations get a BATS contract test or script check (`test/http-guard-dedup-contracts.bats`, `scripts/check-worktree-hygiene.sh`), never just a prose warning.
2. **Prune Agent Instructions ([`writing-for-agents`](../vendor/pocock-skills/writing-for-agents/SKILL.md))**:
   - Audit `AGENTS.md` and `.agents/skills/` for sediment, duplicated rules, or weak context pointers, and verify every step ends with a checkable completion criterion (`Clarity` and `Demand`).
3. **Verify Git Safety Hooks ([`git-guardrails-claude-code`](../vendor/pocock-skills/git-guardrails-claude-code/SKILL.md))**:
   - Confirm destructive git operations and in-repo worktree creation remain blocked.
