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
RESTRICTED_COUNT=0
CURRENT_WT=""
CURRENT_BRANCH="detached"

audit_one_worktree() {
  local wt="$1"
  local branch="$2"
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    return 0
  fi
  TOTAL_WORKTREES=$((TOTAL_WORKTREES + 1))
  local status_out=""
  if ! status_out=$(git -C "$wt" status --porcelain 2>/dev/null); then
    echo "  [RESTRICTED - PRESERVE] Path: ${wt}"
    echo "    Branch: ${branch} (unreadable under current sandbox; preserved)"
    RESTRICTED_COUNT=$((RESTRICTED_COUNT + 1))
    return 0
  fi
  local dirty_files=0
  if [ -n "$status_out" ]; then
    dirty_files=$(printf '%s\n' "$status_out" | wc -l | tr -d ' ')
  fi
  if [ "$dirty_files" -gt 0 ]; then
    echo "  [DIRTY - PRESERVE] Path: ${wt}"
    echo "    Branch: ${branch} | Modified files: ${dirty_files}"
    DIRTY_COUNT=$((DIRTY_COUNT + 1))
  else
    echo "  [CLEAN - CANDIDATE] Path: ${wt}"
    echo "    Branch: ${branch}"
    CLEAN_COUNT=$((CLEAN_COUNT + 1))
  fi
}

# Inspect git worktrees
while IFS= read -r line; do
  if [[ "$line" =~ ^worktree\ (.*)$ ]]; then
    audit_one_worktree "$CURRENT_WT" "$CURRENT_BRANCH"
    CURRENT_WT="${BASH_REMATCH[1]}"
    CURRENT_BRANCH="detached"
  elif [[ "$line" =~ ^branch\ refs/heads/(.*)$ ]]; then
    CURRENT_BRANCH="${BASH_REMATCH[1]}"
  fi
done < <(git worktree list --porcelain)

audit_one_worktree "$CURRENT_WT" "$CURRENT_BRANCH"

echo "=== Summary ==="
echo "Total Worktrees: ${TOTAL_WORKTREES}"
echo "Dirty / Uncommitted Worktrees: ${DIRTY_COUNT}"
echo "Clean Worktrees: ${CLEAN_COUNT}"
echo "Restricted / Unreadable Worktrees: ${RESTRICTED_COUNT}"

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

if [ -x "scripts/check-worktree-hygiene.sh" ]; then
  echo "Running worktree hygiene check (scripts/check-worktree-hygiene.sh)..."
  if bash scripts/check-worktree-hygiene.sh >/dev/null 2>&1; then
    echo "  [PASS] Worktree location hygiene: Zero in-repository worktrees"
  else
    echo "  [FAIL] In-repository worktree violation detected by scripts/check-worktree-hygiene.sh"
    echo "  [REMEDIATION] Move worktrees to ~/src/.worktrees/<repo>/<branch>/ and run 'git worktree prune'."
    exit 1
  fi
  STALE_OSRAMP_WTS="$(bash scripts/check-worktree-hygiene.sh --list-stale-osramp 2>/dev/null || true)"
  if [ -n "$STALE_OSRAMP_WTS" ]; then
    STALE_WT_COUNT="$(printf '%s\n' "$STALE_OSRAMP_WTS" | wc -l | tr -d ' ')"
    echo "  [ADVISORY - STALE OSRAMP WORKTREES] ${STALE_WT_COUNT} stale/clean worktree(s) detected by check-worktree-hygiene.sh --list-stale-osramp"
  fi
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
