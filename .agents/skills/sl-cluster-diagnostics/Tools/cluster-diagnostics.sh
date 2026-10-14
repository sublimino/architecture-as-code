#!/usr/bin/env bash
#
# cluster-diagnostics.sh — Portable cluster diagnostics and log analysis tool.
#
# Part of sl-cluster-diagnostics skill for #partner-signal-loom.
# Provides continuous debugging and snapshot triage of Kubernetes cluster state,
# pod lifecycle faults, warning events, and aggregated logs using stern (when available)
# or falling back to native kubectl logging. Does NOT rely on tmux.
#
# @id      cluster-diagnostics
# @doc     .agents/skills/sl-cluster-diagnostics/SKILL.md
# @tests   test/sl-cluster-diagnostics.bats
#

set -euo pipefail

PROGNAME="cluster-diagnostics.sh"

# ANSI colors (disabled if not on a tty)
if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  C_RESET="\033[0m"
  C_BOLD="\033[1m"
  C_RED="\033[1;31m"
  C_GREEN="\033[1;32m"
  C_YELLOW="\033[1;33m"
  C_BLUE="\033[1;34m"
  C_CYAN="\033[1;36m"
  C_DIM="\033[2m"
else
  C_RESET=""
  C_BOLD=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
  C_DIM=""
fi

usage() {
  cat <<EOF
Usage: ${PROGNAME} [options]

Modes:
  --snapshot, -s           One-shot comprehensive cluster diagnostic report (default)
  --errors, -e             Scan and summarize recent cluster errors and warning events
  --stream, -w, --watch    Stream logs continuously across target pods/namespaces
  --json, -j               Output findings as structured JSON

Options:
  --since DURATION         Log search window (e.g. 2m, 5m, 15m, 1h) [default: 5m]
  --namespace, -n NS       Target specific namespace (default: core application filter)
  --all-namespaces, -A     Target all namespaces in the cluster
  --filter, -f REGEX       Custom namespace regex [default: ^(default|frontend|backend|(be|fe|inf)-)]
  --lines, -l NUM          Max log lines or errors to display [default: 50]
  --force-kubectl          Force native kubectl logs fallback even if stern is available
  --quiet, -q              Suppress informational banner headers
  --help, -h               Show this help message

Examples:
  ${PROGNAME}                         # Comprehensive cluster snapshot
  ${PROGNAME} -e --since 10m          # Scan errors from the last 10 minutes
  ${PROGNAME} -n fe-signalloom        # Diagnose Signal Loom frontend namespace
  ${PROGNAME} --force-kubectl -e      # Test portable kubectl fallback
  ${PROGNAME} --stream                # Continuous live log tail (no tmux required)
EOF
}

# Defaults
MODE="snapshot"
SINCE="5m"
NAMESPACE=""
ALL_NAMESPACES=0
FILTER='^(default|frontend|backend|(be|fe|inf)-)'
MAX_LINES=50
FORCE_KUBECTL=0
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot|-s)
      MODE="snapshot"
      shift
      ;;
    --errors|-e)
      MODE="errors"
      shift
      ;;
    --stream|-w|--watch)
      MODE="stream"
      shift
      ;;
    --json|-j)
      MODE="json"
      shift
      ;;
    --since)
      SINCE="$2"
      shift 2
      ;;
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -A|--all-namespaces)
      ALL_NAMESPACES=1
      shift
      ;;
    -f|--filter)
      FILTER="$2"
      shift 2
      ;;
    -l|--lines)
      MAX_LINES="$2"
      shift 2
      ;;
    --force-kubectl)
      FORCE_KUBECTL=1
      shift
      ;;
    -q|--quiet)
      QUIET=1
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

# Temporary workspace for captures
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cluster-diag.XXXXXX")"
ACTIVE_PIDS=()

cleanup() {
  if [[ "${#ACTIVE_PIDS[@]}" -gt 0 ]]; then
    kill "${ACTIVE_PIDS[@]}" 2>/dev/null || true
    wait "${ACTIVE_PIDS[@]}" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

log_info() {
  if [[ "$QUIET" -eq 0 ]]; then
    echo -e "${C_CYAN}ℹ${C_RESET} $*"
  fi
}

log_warn() {
  echo -e "${C_YELLOW}⚠${C_RESET} $*"
}

log_error() {
  echo -e "${C_RED}✗${C_RESET} $*"
}

log_success() {
  echo -e "${C_GREEN}✓${C_RESET} $*"
}

# 1. Validate Cluster Reachability
check_cluster() {
  if ! command -v kubectl >/dev/null 2>&1; then
    log_error "kubectl command not found on PATH"
    return 1
  fi

  if ! kubectl cluster-info --request-timeout=3s >/dev/null 2>&1; then
    log_error "Kubernetes cluster is unreachable (KUBECONFIG='${KUBECONFIG:-<default>}')"
    echo "  Advisory: verify Kind cluster with 'make up' or check 'kind get clusters'."
    return 1
  fi
  return 0
}

# 2. Resolve Logging Engine (Stern vs Kubectl fallback)
detect_logging_engine() {
  if [[ "$FORCE_KUBECTL" -eq 0 ]] && command -v stern >/dev/null 2>&1; then
    echo "stern"
  else
    echo "kubectl"
  fi
}

# 3. Resolve Target Pods
resolve_pods() {
  local output_file="$1"
  if [[ -n "$NAMESPACE" ]]; then
    kubectl get pods -n "$NAMESPACE" --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,READY:.status.containerStatuses[0].ready' 2>/dev/null > "$output_file" || true
  elif [[ "$ALL_NAMESPACES" -eq 1 ]]; then
    kubectl get pods -A --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,READY:.status.containerStatuses[0].ready' 2>/dev/null > "$output_file" || true
  else
    kubectl get pods -A --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,READY:.status.containerStatuses[0].ready' 2>/dev/null \
      | awk -v pattern="$FILTER" '$1 ~ pattern' > "$output_file" || true
  fi
}

# 4. Fetch Logs via Stern
fetch_logs_stern() {
  local log_output="$1"
  local -a stern_args=()

  if [[ "$ALL_NAMESPACES" -eq 1 ]]; then
    stern_args+=(--all-namespaces)
  elif [[ -n "$NAMESPACE" ]]; then
    stern_args+=(-n "$NAMESPACE")
  else
    # Stern supports regex namespace matching with --namespace <regex>
    stern_args+=(--all-namespaces)
  fi

  stern_args+=(
    --since "$SINCE"
    --no-follow
    --exclude '(panics\.go:76|leaderelection\.go:247)'
    --max-log-requests 100
    -o raw
  )

  if [[ -z "$NAMESPACE" && "$ALL_NAMESPACES" -eq 0 ]]; then
    # Filter output by namespace regex
    stern "${stern_args[@]}" . 2>/dev/null | awk -v pat="$FILTER" '$1 ~ pat' > "$log_output" || true
  else
    stern "${stern_args[@]}" . 2>/dev/null > "$log_output" || true
  fi
}

# 5. Fetch Logs via Native Kubectl Fallback
fetch_logs_kubectl() {
  local pods_file="$1"
  local log_output="$2"

  local pids=()
  local count=0

  # Read resolved pods and fetch bounded logs in parallel batches (up to 8 concurrent workers)
  while read -r ns pod phase restarts ready; do
    [[ -n "$pod" ]] || continue
    # Skip Completed pods unless requested
    if [[ "$phase" == "Succeeded" || "$phase" == "Completed" ]]; then
      continue
    fi

    (
      kubectl logs --since="$SINCE" --all-containers=true -n "$ns" "$pod" 2>/dev/null \
        | grep -vE 'panics\.go:76|leaderelection\.go:247' \
        | sed "s/^/${ns} ${pod} /" >> "$log_output" || true
    ) &
    pids+=($!)
    count=$((count + 1))

    if [[ "$count" -ge 8 ]]; then
      for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
      done
      pids=()
      count=0
    fi
  done < "$pods_file"

  if [[ "${#pids[@]}" -gt 0 ]]; then
    for pid in "${pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
  fi
}

# 6. Extract Error Lines and Match Signatures
analyze_errors() {
  local log_file="$1"
  local errors_file="$TMP_DIR/extracted_errors.txt"

  grep -Ei 'error|fail|exception|fatal|panic|backoff|refused|crash|unhealthy' "$log_file" 2>/dev/null \
    | grep -vE 'kube-probe|GET /readyz 200|GET /livez 200|GET /health 200' \
    | head -n "$MAX_LINES" > "$errors_file" || true

  echo "$errors_file"
}

# 7. Signature Matching Engine
match_known_signatures() {
  local errors_file="$1"
  local events_file="$2"
  local pods_file="$3"
  local signatures_found=()

  # Signature 1: cert-manager challenge finalizer loop
  if grep -q "error cleaning up challenge" "$errors_file" 2>/dev/null || grep -q "cloudflare-api-token" "$errors_file" 2>/dev/null; then
    signatures_found+=("CERT_MANAGER_ACME_FINALIZER_LOOP: cert-manager cannot delete DNS-01 challenges due to missing cloudflare secret. Remediation: run 'make clean-test-artifacts'.")
  fi

  # Signature 2: Dashboard OIDC redirect storm (302 loop)
  if grep -qE "GET /dex/auth.*prompt=login.*HTTP/1\.[01]\" 302" "$errors_file" 2>/dev/null; then
    signatures_found+=("DASHBOARD_OIDC_REDIRECT_STORM: Frontend auth loop repeatedly redirecting to /dex/auth. Remediation: verify oidc single-flight lock and token refresh guard in dashboard-signalloom.")
  fi

  # Signature 3: eBPF Warden Correlator Hold
  if grep -q "thaw_refused_correlator_hold" "$errors_file" 2>/dev/null; then
    local held_pod
    held_pod="$(grep -oE 'pod":"[^"]+' "$errors_file" | head -n 1 | cut -d'"' -f3 || true)"
    signatures_found+=("WARDEN_CORRELATOR_HOLD: Pod '${held_pod:-<agent>}' held by signalloom-warden eBPF detector. Remediation: inspect sys_enter_openat syscall or containment status.")
  fi

  # Signature 4: OpenBao unseeded secrets
  if grep -q "no secret exists at secret/data/agents" "$errors_file" 2>/dev/null; then
    signatures_found+=("OPENBAO_UNSEEDED_AGENT_SECRETS: openbao-agent sidecars retrying missing vault secrets. Remediation: run 'scripts/swarm-seed-secrets.sh'.")
  fi

  # Signature 5: ImagePullBackOff / ErrImagePull
  if grep -qE "ImagePullBackOff|ErrImagePull" "$pods_file" "$events_file" 2>/dev/null; then
    signatures_found+=("CONTAINER_IMAGE_PULL_FAILURE: One or more pods failed to pull images. Remediation: run 'CLUSTER_NAME=osramp ./scripts/kind-load-verified.sh <image>' or check Zot registry.")
  fi

  # Signature 6: CrashLoopBackOff
  if grep -q "CrashLoopBackOff" "$pods_file" "$events_file" 2>/dev/null; then
    signatures_found+=("POD_CRASH_LOOP: Containers restarting in CrashLoopBackOff. Remediation: check 'kubectl logs --previous -n <ns> <pod>' and exit status codes.")
  fi

  for sig in "${signatures_found[@]}"; do
    echo "$sig"
  done
}

# 8. Main Execution Workflows

if ! check_cluster; then
  exit 1
fi

ENGINE="$(detect_logging_engine)"

if [[ "$MODE" == "stream" ]]; then
  log_info "Starting continuous cluster log stream (Engine: ${ENGINE}, Filter: ${NAMESPACE:-$FILTER})..."
  echo -e "${C_DIM}Press Ctrl+C to terminate.${C_RESET}\n"

  if [[ "$ENGINE" == "stern" ]]; then
    local_args=(--since "$SINCE" --exclude '(panics\.go:76|leaderelection\.go:247)')
    if [[ "$ALL_NAMESPACES" -eq 1 ]]; then
      exec stern "${local_args[@]}" --all-namespaces .
    elif [[ -n "$NAMESPACE" ]]; then
      exec stern "${local_args[@]}" -n "$NAMESPACE" .
    else
      # Stream with filter
      exec stern "${local_args[@]}" --all-namespaces . | awk -v pat="$FILTER" '$1 ~ pat { print; fflush() }'
    fi
  else
    # Fallback streaming using kubectl logs -f across current running pods
    log_info "Streaming via kubectl logs fallback (listening to target pods)..."
    resolve_pods "$TMP_DIR/stream_pods.txt"
    while read -r ns pod phase restarts ready; do
      [[ "$phase" == "Running" ]] || continue
      kubectl logs -f --tail=10 -n "$ns" "$pod" 2>/dev/null | sed "s/^/[${ns}\/${pod}] /" &
      ACTIVE_PIDS+=($!)
    done < "$TMP_DIR/stream_pods.txt"
    wait "${ACTIVE_PIDS[@]}" 2>/dev/null || true
  fi
  exit 0
fi

# Collect Pod status
PODS_FILE="$TMP_DIR/pods.txt"
resolve_pods "$PODS_FILE"

# Collect Warning Events
EVENTS_FILE="$TMP_DIR/events.txt"
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null | tail -n 25 > "$EVENTS_FILE" || true

# Collect Logs
LOGS_FILE="$TMP_DIR/logs.raw"
if [[ "$ENGINE" == "stern" ]]; then
  fetch_logs_stern "$LOGS_FILE"
else
  fetch_logs_kubectl "$PODS_FILE" "$LOGS_FILE"
fi

ERRORS_FILE="$(analyze_errors "$LOGS_FILE")"
mapfile -t SIGNATURES < <(match_known_signatures "$ERRORS_FILE" "$EVENTS_FILE" "$PODS_FILE")

# Count Metrics
TOTAL_PODS="$(wc -l < "$PODS_FILE" | tr -d ' \n' || echo 0)"
UNHEALTHY_PODS="$(grep -cvE 'Running|Completed|Succeeded' "$PODS_FILE" 2>/dev/null || true)"
UNHEALTHY_PODS="$(echo "$UNHEALTHY_PODS" | tr -d ' \n')"
[[ -z "$UNHEALTHY_PODS" ]] && UNHEALTHY_PODS=0
RESTARTING_PODS="$(awk '$4 > 0 {c++} END {print c+0}' "$PODS_FILE" | tr -d ' \n')"
WARNING_EVENTS="$(wc -l < "$EVENTS_FILE" | tr -d ' \n' || echo 0)"
ERROR_LOG_LINES="$(wc -l < "$ERRORS_FILE" | tr -d ' \n' || echo 0)"
SIGNATURE_COUNT="${#SIGNATURES[@]}"

# ── JSON Output ─────────────────────────────────────────────────────────────
if [[ "$MODE" == "json" ]]; then
  python3 -c "
import json, sys

data = {
    'engine': sys.argv[1],
    'since': sys.argv[2],
    'total_pods': int(sys.argv[3].strip() or 0),
    'unhealthy_pods': int(sys.argv[4].strip() or 0),
    'restarting_pods': int(sys.argv[5].strip() or 0),
    'warning_events_count': int(sys.argv[6].strip() or 0),
    'error_log_lines_count': int(sys.argv[7].strip() or 0),
    'signatures': [s for s in sys.argv[8].split('@@@') if s],
}
print(json.dumps(data, indent=2))
" "$ENGINE" "$SINCE" "$TOTAL_PODS" "$UNHEALTHY_PODS" "$RESTARTING_PODS" "$WARNING_EVENTS" "$ERROR_LOG_LINES" "$(IFS=@@@; echo "${SIGNATURES[*]}")"
  exit 0
fi

# ── Human / Terminal Output ──────────────────────────────────────────────────
echo -e "${C_BOLD}=== Signal Loom Cluster Diagnostics (${MODE}) ===${C_RESET}"
echo -e "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ") │ Logging Engine: ${C_CYAN}${ENGINE}${C_RESET} │ Window: ${SINCE}"
echo -e "Scope: ${NAMESPACE:-all matching '${FILTER}'}\n"

# Section 1: Workload Health
echo -e "${C_BOLD}1. Workload Lifecycle Summary${C_RESET}"
echo "   Total Pods Inspected: ${TOTAL_PODS}"
if [[ "$UNHEALTHY_PODS" -gt 0 ]]; then
  echo -e "   ${C_RED}Unhealthy / Non-Running Pods: ${UNHEALTHY_PODS}${C_RESET}"
  grep -vE 'Running|Completed|Succeeded' "$PODS_FILE" | head -n 10 | while read -r ns name phase restarts ready; do
    echo -e "     - ${C_RED}${ns}/${name}${C_RESET} [phase=${phase}, restarts=${restarts}, ready=${ready}]"
  done
else
  echo -e "   ${C_GREEN}✓ All inspected pods in Running/Completed state${C_RESET}"
fi

if [[ "$RESTARTING_PODS" -gt 0 ]]; then
  echo -e "   ${C_YELLOW}Pods With Restarts (>0): ${RESTARTING_PODS}${C_RESET}"
  awk '$4 > 0 {print}' "$PODS_FILE" | head -n 5 | while read -r ns name phase restarts ready; do
    echo -e "     - ${ns}/${name} (${restarts} restarts)"
  done
fi

# Section 2: Warning Events
echo -e "\n${C_BOLD}2. Recent Warning Events (Kubernetes API)${C_RESET}"
if [[ -s "$EVENTS_FILE" ]]; then
  tail -n 8 "$EVENTS_FILE" | while IFS= read -r line; do
    echo -e "   ${C_YELLOW}⚠${C_RESET} $line"
  done
else
  echo -e "   ${C_GREEN}✓ No recent warning events recorded${C_RESET}"
fi

# Section 3: Log Errors
echo -e "\n${C_BOLD}3. Extracted Error Log Chunks (last ${SINCE})${C_RESET}"
if [[ -s "$ERRORS_FILE" ]]; then
  echo "   Errors Extracted (${ERROR_LOG_LINES} lines found, showing top):"
  head -n 15 "$ERRORS_FILE" | while IFS= read -r line; do
    echo -e "     ${C_RED}•${C_RESET} ${line}"
  done
  if [[ "$ERROR_LOG_LINES" -gt 15 ]]; then
    echo -e "     ${C_DIM}... (${ERROR_LOG_LINES} total error lines in buffer)${C_RESET}"
  fi
else
  echo -e "   ${C_GREEN}✓ Zero error lines detected in scanned window${C_RESET}"
fi

# Section 4: Signature Remediation
echo -e "\n${C_BOLD}4. Automated Pattern & Signature Analysis${C_RESET}"
if [[ "$SIGNATURE_COUNT" -gt 0 ]]; then
  for sig in "${SIGNATURES[@]}"; do
    sig_name="${sig%%:*}"
    sig_detail="${sig#*: }"
    echo -e "   ${C_RED}[ALARM: ${sig_name}]${C_RESET}"
    echo -e "     ${sig_detail}"
  done
else
  echo -e "   ${C_GREEN}✓ No known cluster failure patterns or signature alarms matched${C_RESET}"
fi

echo -e "\n${C_BOLD}Verdict:${C_RESET} Found=${ERROR_LOG_LINES} log errors, ${UNHEALTHY_PODS} unhealthy pods, ${SIGNATURE_COUNT} matched signatures."

if [[ "$SIGNATURE_COUNT" -gt 0 || "$UNHEALTHY_PODS" -gt 0 ]]; then
  exit 1
fi
exit 0
