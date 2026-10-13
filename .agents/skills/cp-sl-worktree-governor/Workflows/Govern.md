# Workflow: Signal Loom Worktree & Lease Governance

Execute on scheduled cadence (`0 */6 * * *`) or before launching multi-agent swarm tasks.

## Steps

### Step 1: Scan Active Worktrees
```bash
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
cd "${REPO_ROOT}"

echo "Step 1: Listing registered git worktrees..."
git worktree list
```

### Step 2: Run Automated Worktree Auditor Tool
```bash
TOOL_PATH="$(dirname "$0")/../Tools/worktree-audit.sh"
if [ -x "$TOOL_PATH" ]; then
  "$TOOL_PATH"
else
  bash "${TOOL_PATH}"
fi
```

### Step 3: Run Kanban Doctor
Audit active Kanban boards and controller lease status:
```bash
if [ -f "scripts/kanban-check.sh" ]; then
  echo "Step 3: Running kanban doctor..."
  bash scripts/kanban-check.sh doctor --repo . || true
elif [ -f "${HOME}/.andy_sync/confExt/skills/ajm-auto-kanban/Tools/kanban-check.sh" ]; then
  bash "${HOME}/.andy_sync/confExt/skills/ajm-auto-kanban/Tools/kanban-check.sh" doctor --repo . || true
fi
```

### Step 4: Evaluate Safe Pruning
- If a worktree has `DIRTY=NO` and `AHEAD=0` (all commits exist on integration branch), it is eligible for removal:
  ```bash
  git worktree remove <worktree_path>
  ```
- If a worktree has `DIRTY=YES` or `AHEAD > 0`, preserve it and output warning.

### Step 5: Executive Brief
Deliver worktree count, branch status, and disk space freed.
