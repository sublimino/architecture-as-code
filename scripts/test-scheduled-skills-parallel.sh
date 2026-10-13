#!/usr/bin/env bash
# scripts/test-scheduled-skills-parallel.sh
# Concurrent test runner for Signal Loom scheduled-run skills.
# Executes all 7 skills in parallel, isolates logs, prints summary table, and exits non-zero on failure.
set -eo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"

# Color output helpers (auto-disabled if not a tty)
if [ -t 1 ]; then
  C_RESET="\033[0m"
  C_RED="\033[31m"
  C_GREEN="\033[32m"
  C_YELLOW="\033[33m"
  C_BLUE="\033[34m"
  C_CYAN="\033[36m"
  C_BOLD="\033[1m"
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
  C_BOLD=""
fi

INCLUDE_ALL=0
KEEP_LOGS=0
VERBOSE=0

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --all)
        INCLUDE_ALL=1
        shift
        ;;
      --keep-logs)
        KEEP_LOGS=1
        shift
        ;;
      -v|--verbose)
        VERBOSE=1
        shift
        ;;
      -h|--help)
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  --all          Include all skills including two-axis drift-sweep"
        echo "  --keep-logs    Preserve isolated execution logs in /tmp even on success"
        echo "  -v, --verbose  Print execution output of all skills, not just failures"
        echo "  -h, --help     Display this help message"
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        echo "Run '$0 --help' for usage." >&2
        exit 2
        ;;
    esac
  done
}

# The canonical Signal Loom scheduled-run skills specification
# Format: "skill_name|tool_rel_path|description"
SKILL_SPECS=(
  "sl-drift-reconcile|Tools/drift-audit.sh|GitOps & Cluster Drift Audit"
  "sl-portforward-supervisor|Tools/portforward-check.sh|Ingress & Port-Forward Supervisor"
  "sl-silent-failure-audit|Tools/audit-invariants.sh|Silent Failure & Invariant Sentinel"
  "sl-containment-guard|Tools/check-containment.sh|Agent Containment & GitOps Suspension"
  "sl-pyramid-verify|Tools/pyramid-runner.sh|Offline Test Pyramid Battery"
  "sl-worktree-governor|Tools/worktree-audit.sh|Multi-Agent Worktree Governor"
  "sl-eap-evidence-sweep|Tools/evidence-sweep.sh|EAP Compliance Evidence Sweeper"
)

LOG_DIR=""
CHILD_PIDS=()

cleanup() {
  local exit_status=$?
  # Kill any child processes still running
  for pid in "${CHILD_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true

  if [ -n "$LOG_DIR" ] && [ -d "$LOG_DIR" ]; then
    if [ "$KEEP_LOGS" -eq 1 ] || [ "$exit_status" -ne 0 ]; then
      echo -e "${C_CYAN}Logs preserved in: ${LOG_DIR}${C_RESET}"
    else
      rm -rf "$LOG_DIR"
    fi
  fi
  exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

resolve_skill_tool() {
  local skill_name="$1"
  local tool_rel="$2"

  if [ -f "${REPO_ROOT}/.agents/skills/${skill_name}/${tool_rel}" ]; then
    echo "${REPO_ROOT}/.agents/skills/${skill_name}/${tool_rel}"
    return 0
  elif [ -f "${HOME}/.andy_sync/confExt/skills/${skill_name}/${tool_rel}" ]; then
    echo "${HOME}/.andy_sync/confExt/skills/${skill_name}/${tool_rel}"
    return 0
  else
    return 1
  fi
}

extract_summary() {
  local skill_name="$1"
  local log_file="$2"

  case "$skill_name" in
    sl-drift-reconcile)
      local patch_stat clus_stat
      patch_stat=$(grep -oE "PATCH_INDEX_INTEGRITY=[A-Z]+" "$log_file" | head -n1 || echo "")
      clus_stat=$(grep -oE "CLUSTER_STATUS=[A-Z]+" "$log_file" | head -n1 || echo "")
      echo "${patch_stat:-drift-audit}, ${clus_stat:-unknown}"
      ;;
    sl-portforward-supervisor)
      local pf_stat clus_stat
      pf_stat=$(grep -oE "PORT_5173_ALERT=[^ ]+" "$log_file" | head -n1 || echo "")
      clus_stat=$(grep -oE "CLUSTER_STATUS=[A-Z]+" "$log_file" | head -n1 || echo "")
      if [ -n "$clus_stat" ]; then
        echo "${pf_stat:-port-forward}, ${clus_stat}"
      else
        echo "${pf_stat:-port-forward}"
      fi
      ;;
    sl-silent-failure-audit)
      grep -oE "RESULT: .*" "$log_file" | head -n1 || echo "Invariants checked"
      ;;
    sl-containment-guard)
      local clus_stat
      clus_stat=$(grep -oE "CLUSTER_STATUS=[A-Z]+" "$log_file" | head -n1 || echo "")
      if [ -n "$clus_stat" ]; then
        echo "$clus_stat"
      else
        grep -oE "RESULT: .*" "$log_file" | head -n1 || echo "Containment verified"
      fi
      ;;
    sl-pyramid-verify)
      grep -oE "Status: .*" "$log_file" | head -n1 || echo "Pyramid verified"
      ;;
    sl-worktree-governor)
      local total dirty clean
      total=$(grep -oE "Total Worktrees: [0-9]+" "$log_file" | head -n1 || echo "")
      dirty=$(grep -oE "Dirty / Uncommitted Worktrees: [0-9]+" "$log_file" | sed 's/Dirty \/ Uncommitted Worktrees: /dirty:/' || echo "")
      clean=$(grep -oE "Clean Worktrees: [0-9]+" "$log_file" | sed 's/Clean Worktrees: /clean:/' || echo "")
      echo "${total:-worktrees}, ${dirty:-0}, ${clean:-0}"
      ;;
    sl-eap-evidence-sweep)
      grep -oE "STATUS: [A-Z_]+" "$log_file" | head -n1 || echo "Evidence swept"
      ;;
    sl-drift-sweep)
      grep -oE "STATUS: [A-Z_]+.*" "$log_file" | head -n1 || echo "Drift swept"
      ;;
    *)
      echo "Completed"
      ;;
  esac
}

main() {
  parse_args "$@"

  if [ "$INCLUDE_ALL" -eq 1 ]; then
    SKILL_SPECS+=("sl-drift-sweep|Tools/drift-sweep.sh|Two-Axis Codebase Drift & Smell Sweeper")
  fi

  LOG_DIR=$(mktemp -d /tmp/scheduled-skills-XXXXXX)

  echo -e "${C_BOLD}=== Running ${#SKILL_SPECS[@]} Signal Loom Scheduled Skills Concurrently ===${C_RESET}"
  echo "Repository root: ${REPO_ROOT}"
  echo "Execution log directory: ${LOG_DIR}"
  echo ""

  local overall_start
  overall_start=$(date +%s)

  declare -A P_SKILL_NAME
  declare -A P_TOOL_PATH
  declare -A P_DESC
  CHILD_PIDS=()

  local idx=0
  for spec in "${SKILL_SPECS[@]}"; do
    IFS='|' read -r skill_name tool_rel desc <<< "$spec"
    
    local tool_path
    if ! tool_path=$(resolve_skill_tool "$skill_name" "$tool_rel"); then
      echo -e "${C_RED}ERROR: Tool script not found for skill: ${skill_name} (${tool_rel})${C_RESET}" >&2
      exit 1
    fi

    local log_file="${LOG_DIR}/${skill_name}.log"
    local meta_file="${LOG_DIR}/${skill_name}.meta"

    # Spawn in background with isolated output and timing
    (
      local job_start
      job_start=$(date +%s)
      local rc=0
      bash "$tool_path" > "$log_file" 2>&1 || rc=$?
      local job_end
      job_end=$(date +%s)
      local duration=$((job_end - job_start))
      echo "${rc}|${duration}" > "$meta_file"
    ) &
    local child_pid=$!

    CHILD_PIDS+=("$child_pid")
    P_SKILL_NAME["$child_pid"]="$skill_name"
    P_TOOL_PATH["$child_pid"]="$tool_path"
    P_DESC["$child_pid"]="$desc"
    
    echo -e "  [START] ${C_CYAN}${skill_name}${C_RESET} (${desc}) [PID ${child_pid}]"
    idx=$((idx + 1))
  done

  echo ""
  echo "Waiting for all ${#SKILL_SPECS[@]} concurrent skill checks to complete..."

  # Wait for all child processes
  for pid in "${CHILD_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  local overall_end
  overall_end=$(date +%s)
  local total_duration=$((overall_end - overall_start))

  echo ""
  echo -e "${C_BOLD}=== Aggregated Scheduled Skills Status ===${C_RESET}"
  printf "%-30s %-8s %-10s %-10s %-35s\n" "Skill Name" "Status" "Exit Code" "Duration" "Summary / Invariant Metric"
  printf "%-30s %-8s %-10s %-10s %-35s\n" "------------------------------" "------" "---------" "--------" "-----------------------------------"

  local fail_count=0
  local pass_count=0
  local failed_skills=()

  for spec in "${SKILL_SPECS[@]}"; do
    IFS='|' read -r skill_name tool_rel desc <<< "$spec"
    local log_file="${LOG_DIR}/${skill_name}.log"
    local meta_file="${LOG_DIR}/${skill_name}.meta"

    local rc="1"
    local duration="0"
    if [ -f "$meta_file" ]; then
      IFS='|' read -r rc duration < "$meta_file"
    fi

    local summary
    summary=$(extract_summary "$skill_name" "$log_file")

    local status_str
    if [ "$rc" -eq 0 ]; then
      status_str="${C_GREEN}PASS${C_RESET}"
      pass_count=$((pass_count + 1))
    else
      status_str="${C_RED}FAIL${C_RESET}"
      fail_count=$((fail_count + 1))
      failed_skills+=("$skill_name")
    fi

    printf "%-30s %-17b %-10s %-10s %-35s\n" "$skill_name" "$status_str" "$rc" "${duration}s" "$summary"
  done

  printf "%-30s %-8s %-10s %-10s %-35s\n" "------------------------------" "------" "---------" "--------" "-----------------------------------"
  echo -e "Total Concurrent Runtime: ${C_BOLD}${total_duration}s${C_RESET}"
  echo -e "Aggregated Verdict: ${pass_count}/${#SKILL_SPECS[@]} Passed, ${fail_count} Failed"

  # Verbose or Failure Log Dumps
  if [ "$VERBOSE" -eq 1 ]; then
    echo ""
    echo -e "${C_BOLD}=== Detailed Execution Logs (Verbose Mode) ===${C_RESET}"
    for spec in "${SKILL_SPECS[@]}"; do
      IFS='|' read -r skill_name tool_rel desc <<< "$spec"
      local log_file="${LOG_DIR}/${skill_name}.log"
      echo ""
      echo -e "${C_CYAN}--- Output: ${skill_name} (${tool_rel}) ---${C_RESET}"
      cat "$log_file"
    done
  elif [ "$fail_count" -gt 0 ]; then
    echo ""
    echo -e "${C_RED}${C_BOLD}=== Failures Detected - Reviewing Remediations ===${C_RESET}"
    for failed in "${failed_skills[@]}"; do
      local log_file="${LOG_DIR}/${failed}.log"
      echo ""
      echo -e "${C_RED}--- [FAIL] Log: ${failed} ---${C_RESET}"
      cat "$log_file"
    done
  fi

  if [ "$fail_count" -gt 0 ]; then
    echo ""
    echo -e "${C_RED}RESULT: FAILED (${fail_count} skills reported invariant violations or errors)${C_RESET}" >&2
    exit 1
  else
    echo ""
    echo -e "${C_GREEN}RESULT: ALL ${#SKILL_SPECS[@]} SCHEDULED SKILLS PASSED${C_RESET}"
    exit 0
  fi
}

main "$@"
