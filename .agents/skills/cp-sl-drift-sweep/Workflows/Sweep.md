# Workflow: Signal Loom Two-Axis Drift Sweep & Parallel Remediation

Execute after a multi-agent build wave, on scheduled cadence (`0 4 * * *`), or via `/cp-sl-drift-sweep [--auto]`.

---

## Phase 1: Two-Axis Drift & Churn Triage (Read-Only Audit)

### Step 1.1: Run the Automated Drift Scanner
```bash
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
cd "${REPO_ROOT}"

# Pass --auto if invoked with --auto or under /goal
bash .agents/skills/cp-sl-drift-sweep/Tools/drift-sweep.sh "$@"
```

### Step 1.2: Synthesize Two-Axis Report & Cleanup Job Manifest
Present the findings under two strictly separate headings:
- **`## Axis A: Standards & Code Smell Findings`**
  - `make docs-lint` violations (`scripts/docs-lint.sh`).
  - Worktree hygiene (`scripts/check-worktree-hygiene.sh` and `> 21` day `osramp` stale count).
  - Fowler smell baseline: *Shotgun Surgery*, *Duplicated Code* (e.g. inline HTTP method/header/drain guards missing `httputil.go` or `http-gate.ts`), *Divergent Change* (files churned ≥5x in the branch range), *Speculative Generality*.
- **`## Axis B: Spec & Proposal Sprawl Findings`**
  - Micro-proposal fragmentation in `docs/Proposal *` (`Mission: —` count in `docs/README.md`).
  - Unindexed decision records (`bats test/docs-index-sync.bats`).
  - Uncommitted working-tree drift (`git status --short`).

Emit the numbered **Cleanup Job Manifest** with non-overlapping file ownership per job.

### Step 1.3: Pause Gate vs `--auto` / `/goal` Continuation
- **Default (No `--auto` and no `/goal`)**:
  - **STOP HERE.** Ask the user to approve or adjust the Cleanup Job Manifest before creating worktrees or modifying code.
- **With `--auto` or `/goal`**:
  - Continue immediately to Phase 2.

---

## Phase 2: Shared Pattern Extraction & Isolated Worktree Partitioning

### Step 2.1: Commit or Triage Working Tree First
If the base branch has uncommitted work, verify its tests and commit it first. Every subagent must start from the same clean HEAD.

### Step 2.2: Provision Isolated Worktrees Outside `$REPO_ROOT`
Never create worktrees inside `$REPO_ROOT/.claude/worktrees/`. Use `/tmp/osramp-worktrees/` (or `~/src/.worktrees/osramp-demo/` when writable):
```bash
BASE_REF="$(git rev-parse --abbrev-ref HEAD)"
WT_ROOT="/tmp/osramp-worktrees"
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
  [ -d "$wt_path" ] && git worktree remove --force "$wt_path"
  git worktree prune
  git branch -f "$branch" "$BASE_REF"
  git worktree add "$wt_path" "$branch"
done
```

### Step 2.3: Inject Shared Sandbox & Toolchain Rules into Subagent Prompts
Every subagent prompt must include:
1. **Go Sandbox Toolchain**:
   ```bash
   export GOPATH=/tmp/gopath GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache GONOSUMDB="*" CGO_ENABLED=0
   export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/bin:$PATH"
   mkdir -p "$GOPATH" "$GOCACHE" "$GOMODCACHE"
   ```
2. **Unsigned Commits inside Sandbox**: Use `git commit --no-gpg-sign` (or `bin/agent-git`).
3. **Static BATS Grep Preservation**: Before refactoring a service, run `rg "<service-or-token>" test/*.bats d2-signalloom/test/*.bats` so static grep assertions in BATS suites stay green.

---

## Phase 3: Parallel Subagent Execution & Mandatory Mutation Proof

Spawn all chunk subagents concurrently via `invoke_subagent`. Each subagent MUST execute the **4-step Mutation Falsifiability Protocol** before committing:
1. **Baseline Green**: Run the focused test suite (`go test`, `pytest`, `bun test`, or `bats`) and confirm pass.
2. **Forced Mutation + Diff Proof**: Mutate the production helper or script (such as dropping `OPTIONS` from `Allow`). Assert `git diff <file>` is non-empty on disk.
3. **Mutated Red**: Re-run the test suite and confirm it exits non-zero on the expected assertion failure (never a syntax error or unrelated setup failure).
4. **Restored Green**: Restore the file from backup, confirm `git diff` is clean, and re-run the test suite to confirm pass.

---

## Phase 4: Sequential Rebase, One-by-One Verification, Merge & Teardown

As subagents complete, integrate them sequentially onto the target branch (`$BASE_REF`):

```bash
# For each completed worktree branch:
git -C "$WT_PATH" rebase "$BASE_REF"
# Run that chunk's focused test suite inside $WT_PATH
git -C "$REPO_ROOT" merge --ff-only "$BRANCH_NAME"
```

After all branches are fast-forward merged:
1. Remove temporary worktrees and branches:
   ```bash
   for dir in /tmp/osramp-worktrees/cleanup-*; do
     [ -d "$dir" ] && git worktree remove --force "$dir"
   done
   rmdir /tmp/osramp-worktrees 2>/dev/null || true
   git worktree prune
   ```
2. Run the full end-to-end verification battery on the target branch:
   ```bash
   make docs-lint
   make docs-lint-test
   bats test/worktree-hygiene.bats test/http-guard-dedup-contracts.bats
   ./scripts/check-worktree-hygiene.sh
   ```
