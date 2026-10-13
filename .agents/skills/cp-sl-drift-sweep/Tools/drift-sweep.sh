#!/usr/bin/env bash
# .agents/skills/cp-sl-drift-sweep/Tools/drift-sweep.sh
# Two-axis drift, multi-agent churn, and code-smell scanner for Signal Loom.
# Default mode: PAUSE_FOR_APPROVAL (emits Two-Axis Report + Cleanup Job Manifest and pauses).
# Autonomous mode (--auto or GOAL_MODE=1): emits manifest and sets EXECUTION_MODE=AUTO.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
BASE_REF=""
AUTO_MODE="${GOAL_MODE:-0}"
CHURN_THRESHOLD=5
PROPOSAL_SPRAWL_THRESHOLD=5
SKIP_DOCS_LINT=0
IGNORE_DIRTY=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --auto                              Run in autonomous mode (EXECUTION_MODE=AUTO; do not pause after Phase 1)
  --pause                             Run in interactive pause mode (EXECUTION_MODE=PAUSE_FOR_APPROVAL, default)
  --base <git-ref>                    Base git ref for churn comparison (default: auto-detected)
  --repo-root <dir>                   Override repository root directory
  --churn-threshold <n>               Commits touching a single file before flagging churn (default: 5)
  --proposal-sprawl-threshold <n>     Ungrouped 'Mission: —' proposals before flagging sprawl (default: 5)
  --skip-docs-lint                    Skip full docs-lint execution (for fast unit tests)
  --ignore-dirty                      Ignore uncommitted working-tree files during check
  -h, --help                          Show this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --auto)
      AUTO_MODE=1
      shift
      ;;
    --pause)
      AUTO_MODE=0
      shift
      ;;
    --base)
      BASE_REF="${2:-}"
      shift 2
      ;;
    --repo-root)
      REPO_ROOT="${2:-}"
      shift 2
      ;;
    --churn-threshold)
      CHURN_THRESHOLD="${2:-5}"
      shift 2
      ;;
    --proposal-sprawl-threshold)
      PROPOSAL_SPRAWL_THRESHOLD="${2:-5}"
      shift 2
      ;;
    --skip-docs-lint)
      SKIP_DOCS_LINT=1
      shift
      ;;
    --ignore-dirty)
      IGNORE_DIRTY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cd "$REPO_ROOT"

if [ "$AUTO_MODE" -eq 1 ]; then
  EXECUTION_MODE="AUTO"
else
  EXECUTION_MODE="PAUSE_FOR_APPROVAL"
fi

if [ -z "$BASE_REF" ]; then
  if git rev-parse --verify -q HEAD~20 >/dev/null 2>&1; then
    BASE_REF="HEAD~20"
  elif git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    BASE_REF="$(git rev-list --max-parents=0 HEAD | tail -n1)"
  else
    BASE_REF="HEAD"
  fi
fi

STANDARDS_FINDINGS=0
SPEC_FINDINGS=0
declare -a JOBS=()

echo "=== Signal Loom Two-Axis Drift Sweep (cp-sl-drift-sweep) ==="
echo "Repository     : $REPO_ROOT"
echo "Base Ref       : $BASE_REF..HEAD"
echo "Execution Mode : $EXECUTION_MODE"
echo ""

# ------------------------------------------------------------------------------
# Axis A: Standards & Fowler Code-Smell Baseline
# ------------------------------------------------------------------------------
echo "## Axis A: Standards & Code-Smell Baseline"

# A1. Worktree Hygiene
WT_GUARD_STATUS="PASS"
STALE_OSRAMP_COUNT=0
if [ -x "$REPO_ROOT/scripts/check-worktree-hygiene.sh" ]; then
  if ! "$REPO_ROOT/scripts/check-worktree-hygiene.sh" --repo-root "$REPO_ROOT" >/dev/null 2>&1; then
    WT_GUARD_STATUS="FAIL"
    STANDARDS_FINDINGS=$((STANDARDS_FINDINGS + 1))
    JOBS+=("job-hygiene: Resolve in-repo worktree violations via scripts/check-worktree-hygiene.sh")
  fi
  STALE_OSRAMP_COUNT="$("$REPO_ROOT/scripts/check-worktree-hygiene.sh" --repo-root "$REPO_ROOT" --list-stale-osramp --max-age-days 21 2>/dev/null | grep -c 'STATUS=CLEAN' || true)"
fi
if [ "${STALE_OSRAMP_COUNT:-0}" -gt 0 ]; then
  STANDARDS_FINDINGS=$((STANDARDS_FINDINGS + 1))
  JOBS+=("job-worktree-prune: Prune $STALE_OSRAMP_COUNT clean >21d osramp worktree(s) via scripts/check-worktree-hygiene.sh --prune-stale-osramp")
fi
echo "  [A1] Worktree Hygiene Guard : $WT_GUARD_STATUS (prunable clean >21d osramp worktrees: $STALE_OSRAMP_COUNT)"

# A2. Documentation Lint
DOCS_LINT_FINDINGS=0
if [ "$SKIP_DOCS_LINT" -eq 0 ] && [ -x "$REPO_ROOT/scripts/docs-lint.sh" ]; then
  LINT_OUT=""
  if ! LINT_OUT="$("$REPO_ROOT/scripts/docs-lint.sh" 2>&1)"; then
    DOCS_LINT_FINDINGS="$(printf '%s\n' "$LINT_OUT" | sed -n 's/.*docs-lint: \([0-9][0-9]*\) finding(s).*/\1/p' | tail -n1)"
    DOCS_LINT_FINDINGS="${DOCS_LINT_FINDINGS:-1}"
    STANDARDS_FINDINGS=$((STANDARDS_FINDINGS + 1))
    JOBS+=("job-docs-lint: Fix $DOCS_LINT_FINDINGS docs-lint finding(s) across docs/ and policy/")
  fi
fi
echo "  [A2] Documentation Lint     : ${DOCS_LINT_FINDINGS} finding(s)"

# A3. Shared HTTP Guard Deduplication Coverage (Go, TS, Python)
MISSING_HELPERS=0
for go_app in fleet-manager hosted-daytona-coder cardvault prompt-commit-summarizer triage-ci-worker workspace-connector cpai-engineer prod-deploy-gate; do
  if [ -d "$REPO_ROOT/d2-signalloom/apps/$go_app" ] && [ ! -f "$REPO_ROOT/d2-signalloom/apps/$go_app/httputil.go" ]; then
    MISSING_HELPERS=$((MISSING_HELPERS + 1))
  fi
done
if [ -d "$REPO_ROOT/test/acceptance/harness" ] && [ ! -f "$REPO_ROOT/test/acceptance/harness/http-gate.ts" ]; then
  MISSING_HELPERS=$((MISSING_HELPERS + 1))
fi
if [ "$MISSING_HELPERS" -gt 0 ]; then
  STANDARDS_FINDINGS=$((STANDARDS_FINDINGS + 1))
  JOBS+=("job-dedup-http-guards: Extract shared HTTP method-gate/body-lifecycle helpers ($MISSING_HELPERS module(s) missing shared helper)")
fi
echo "  [A3] Shared HTTP Helpers    : $((9 - MISSING_HELPERS))/9 canonical helper modules present"

# A4. Multi-Pass Divergent Change (File Churn Heatmap)
CHURN_HOTSPOTS="$(
  git -C "$REPO_ROOT" log "$BASE_REF..HEAD" --name-only --pretty=format: 2>/dev/null \
    | sed '/^$/d' \
    | sort | uniq -c | sort -nr \
    | awk -v thresh="$CHURN_THRESHOLD" '$1 >= thresh && $2 != "docs/README.md" { print $1 "x " $2 }' \
    | head -n 5 || true
)"
CHURN_COUNT=0
if [ -n "$CHURN_HOTSPOTS" ]; then
  CHURN_COUNT="$(printf '%s\n' "$CHURN_HOTSPOTS" | wc -l | tr -d ' ')"
fi
echo "  [A4] High-Churn Files (>=$CHURN_THRESHOLD): $CHURN_COUNT hotspot(s) in $BASE_REF..HEAD"

echo ""
# ------------------------------------------------------------------------------
# Axis B: Spec & Proposal Fidelity
# ------------------------------------------------------------------------------
echo "## Axis B: Spec & Proposal Sprawl"

# B1. Ungrouped Micro-Proposal Sprawl in docs/README.md
UNGROUPED_PROPOSALS=0
if [ -f "$REPO_ROOT/docs/README.md" ]; then
  UNGROUPED_PROPOSALS="$(grep -c '| — | Delivered |' "$REPO_ROOT/docs/README.md" || true)"
fi
if [ "$UNGROUPED_PROPOSALS" -gt "$PROPOSAL_SPRAWL_THRESHOLD" ]; then
  SPEC_FINDINGS=$((SPEC_FINDINGS + 1))
  JOBS+=("job-proposal-consolidation: Consolidate $UNGROUPED_PROPOSALS ungrouped (Mission: —) micro-proposals in docs/ into canonical ADR")
fi
echo "  [B1] Ungrouped Proposals    : $UNGROUPED_PROPOSALS (threshold: $PROPOSAL_SPRAWL_THRESHOLD)"

# B2. Dirty Working Tree Check
DIRTY_FILES=0
if [ "$IGNORE_DIRTY" -eq 0 ]; then
  DIRTY_FILES="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$DIRTY_FILES" -gt 0 ]; then
    SPEC_FINDINGS=$((SPEC_FINDINGS + 1))
    JOBS+=("job-working-tree-triage: Triage and commit/revert $DIRTY_FILES uncommitted working-tree file(s)")
  fi
fi
echo "  [B2] Working Tree Dirty     : $DIRTY_FILES file(s)"

echo ""
# ------------------------------------------------------------------------------
# Summary & Cleanup Job Manifest
# ------------------------------------------------------------------------------
TOTAL_JOBS="${#JOBS[@]}"
echo "## Cleanup Job Manifest ($TOTAL_JOBS job(s))"
if [ "$TOTAL_JOBS" -eq 0 ]; then
  echo "  None — repository is clean across both Standards and Spec axes."
else
  idx=1
  for job in "${JOBS[@]}"; do
    echo "  $idx. $job"
    idx=$((idx + 1))
  done
fi

echo ""
if [ "$TOTAL_JOBS" -eq 0 ]; then
  echo "STATUS: CLEAN (standards=$STANDARDS_FINDINGS, spec=$SPEC_FINDINGS, jobs=0, mode=$EXECUTION_MODE)"
else
  echo "STATUS: DRIFT_DETECTED (standards=$STANDARDS_FINDINGS, spec=$SPEC_FINDINGS, jobs=$TOTAL_JOBS, mode=$EXECUTION_MODE)"
  if [ "$EXECUTION_MODE" = "PAUSE_FOR_APPROVAL" ]; then
    echo "ACTION: PAUSE — Present the Two-Axis Report and Cleanup Job Manifest to the user for approval (or re-run with --auto / /goal)."
  else
    echo "ACTION: AUTO_EXECUTE — Proceed to Phase 2 (Isolated Worktree Partitioning & Subagent Dispatch)."
  fi
fi
