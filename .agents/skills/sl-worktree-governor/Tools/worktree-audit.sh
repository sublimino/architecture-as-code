#!/usr/bin/env bash
# worktree-audit.sh — Scan and audit active git worktrees across the environment
set -eo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
cd "${REPO_ROOT}"

echo "=== Signal Loom Multi-Agent Worktree Governor ==="
DATE_STR=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Audit Timestamp: ${DATE_STR}"

TOTAL_WORKTREES=0
DIRTY_COUNT=0
CLEAN_COUNT=0
CURRENT_WT=""
CURRENT_BRANCH="detached"

# Inspect git worktrees
while IFS= read -r line; do
  if [[ "$line" =~ ^worktree\ (.*)$ ]]; then
    if [ -n "$CURRENT_WT" ] && [ -d "$CURRENT_WT" ]; then
      TOTAL_WORKTREES=$((TOTAL_WORKTREES + 1))
      DIRTY_FILES=$(git -C "$CURRENT_WT" status --porcelain 2>/dev/null | wc -l || echo "0")
      if [ "$DIRTY_FILES" -gt 0 ]; then
        echo "  [DIRTY - PRESERVE] Path: ${CURRENT_WT}"
        echo "    Branch: ${CURRENT_BRANCH} | Modified files: ${DIRTY_FILES}"
        DIRTY_COUNT=$((DIRTY_COUNT + 1))
      else
        echo "  [CLEAN - CANDIDATE] Path: ${CURRENT_WT}"
        echo "    Branch: ${CURRENT_BRANCH}"
        CLEAN_COUNT=$((CLEAN_COUNT + 1))
      fi
    fi
    CURRENT_WT="${BASH_REMATCH[1]}"
    CURRENT_BRANCH="detached"
  elif [[ "$line" =~ ^branch\ refs/heads/(.*)$ ]]; then
    CURRENT_BRANCH="${BASH_REMATCH[1]}"
  fi
done < <(git worktree list --porcelain)

if [ -n "$CURRENT_WT" ] && [ -d "$CURRENT_WT" ]; then
  TOTAL_WORKTREES=$((TOTAL_WORKTREES + 1))
  DIRTY_FILES=$(git -C "$CURRENT_WT" status --porcelain 2>/dev/null | wc -l || echo "0")
  if [ "$DIRTY_FILES" -gt 0 ]; then
    echo "  [DIRTY - PRESERVE] Path: ${CURRENT_WT}"
    echo "    Branch: ${CURRENT_BRANCH} | Modified files: ${DIRTY_FILES}"
    DIRTY_COUNT=$((DIRTY_COUNT + 1))
  else
    echo "  [CLEAN - CANDIDATE] Path: ${CURRENT_WT}"
    echo "    Branch: ${CURRENT_BRANCH}"
    CLEAN_COUNT=$((CLEAN_COUNT + 1))
  fi
fi

echo "=== Summary ==="
echo "Total Worktrees: ${TOTAL_WORKTREES}"
echo "Dirty / Uncommitted Worktrees: ${DIRTY_COUNT}"
echo "Clean Worktrees: ${CLEAN_COUNT}"

if [ "$DIRTY_COUNT" -gt 0 ]; then
  echo "  [REMEDIATION - DIRTY WORKTREES] ${DIRTY_COUNT} worktree(s) contain uncommitted modifications."
  echo "  Do NOT delete or prune dirty worktrees automatically."
  echo "  To inspect modified files: 'git -C <worktree-path> status -s'"
  echo "  To preserve: commit changes with 'git commit' or stash with 'git stash'."
fi

if [ "$CLEAN_COUNT" -gt 0 ]; then
  echo "  [ADVISORY - CLEAN WORKTREES] ${CLEAN_COUNT} worktree(s) are clean candidates for retirement."
  echo "  To safely prune merged clean worktrees: 'git worktree remove <worktree-path>' and 'git worktree prune'."
fi

if [ -f "scripts/kanban-check.sh" ]; then
  echo "Running kanban health check..."
  DOCTOR_OUT=$(bash scripts/kanban-check.sh doctor --repo . 2>/dev/null || true)
  if echo "$DOCTOR_OUT" | grep -q "UNHEALTHY"; then
    echo "  [WARN] Kanban doctor reported exceptions:"
    echo "$DOCTOR_OUT" | grep -E 'FAIL:|EXCEPTION' | head -n 5
    echo "  [REMEDIATION - KANBAN] To investigate or remediate kanban tasks:"
    echo "  1. Run 'bash scripts/kanban-check.sh doctor --repo .'"
    echo "  2. Check running agents: 'bash scripts/kanban-check.sh stall-check --repo .'"
    echo "  3. Remediate failed task: 'bash scripts/kanban-check.sh remediate --task-id <id> --repo .'"
  else
    echo "  [PASS] Kanban controller state: Healthy"
  fi
fi

echo "=== Worktree Audit Completed ==="
exit 0
