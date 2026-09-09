#!/usr/bin/env bash

# Canonical Signal Loom discovery-to-governance demonstration.
# No local port-forward is created: HTTP requests run through the existing
# dashboard pod, and bearer tokens travel over stdin rather than process argv.

ZSH_VERSION=${ZSH_VERSION:-}
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/wait.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/wait.sh"

AGENT_NAMESPACE="${AGENT_NAMESPACE:-fe-signalloom-agents}"
API_NAMESPACE="${API_NAMESPACE:-fe-signalloom}"
API_CLIENT_DEPLOYMENT="${API_CLIENT_DEPLOYMENT:-dashboard-signalloom}"
API_BASE_URL="${API_BASE_URL:-http://localhost:8080}"
DEMO_USER="${DEMO_DEX_USER:-demo-user@signalloom.local}"
DEMO_PASSWORD="${DEX_DEMO_PASSWORD:-demo-user}"
DEX_CLIENT="${DEMO_DEX_CLIENT:-signalloom-dashboard}"
TOKEN_BUDGET_LIMIT="${TOKEN_BUDGET_LIMIT:-250000}"
RESULT_FILE="${SLAC_DEMO_RESULT_FILE:-/tmp/slac-demo-result.json}"
WAIT_ATTEMPT_TIMEOUT="${WAIT_ATTEMPT_TIMEOUT:-10}"
export WAIT_ATTEMPT_TIMEOUT

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  RED="" GREEN="" YELLOW="" BLUE="" BOLD="" RESET=""
fi

TEMP_DIR=""
RESULT_WRITTEN=0
STEP=0
STARTED_EPOCH="$(date +%s)"
DISCOVERY_EPOCH=""
TOKEN=""
API_BODY=""
HTTP_STATUS=""

TARGET_WORKLOAD=""
TARGET_POD=""
TARGET_SERVICE_ACCOUNT=""
SPIFFE_ID=""
CLAIM_ID=""
AGENT_ID=""
POSTURE_SCORE=""
POSTURE_PERCENT=""
CONTROL_COUNT=""
AUDIT_EVENT_TYPE=""
AUDIT_ACTION=""
AUDIT_ACTOR=""
AUDIT_TIMESTAMP=""

usage() {
  cat <<'EOF'
Usage: scripts/demo-agent-autoclaim.sh [--reset|--help]

Run the seven-step Signal Loom agent discovery and auto-claim demonstration.

  --reset  Reset the shared demo agent registry, compliance rows, and linked
           audit rows, then restart the API so workloads appear discovered.
  --help   Show this help.

Environment overrides:
  DEX_DEMO_PASSWORD       Dex demo-user password (default: demo-user)
  SLAC_DEMO_RESULT_FILE   Machine evidence path (default: /tmp/slac-demo-result.json)
  NO_COLOR=1              Disable ANSI terminal colours
EOF
}

log()  { printf '%s\n' "$*"; }
info() { printf '%sℹ%s %s\n' "${BLUE}" "${RESET}" "$*"; }
warn() { printf '%s⚠%s %s\n' "${YELLOW}" "${RESET}" "$*" >&2; }

write_result() {
  local status="$1" reason="${2:-}" elapsed
  elapsed=$(( $(date +%s) - STARTED_EPOCH ))
  local tmp_result="${RESULT_FILE}.tmp.$$"

  jq -n \
    --arg status "${status}" \
    --arg reason "${reason}" \
    --arg workload "${TARGET_WORKLOAD:-}" \
    --arg pod "${TARGET_POD:-}" \
    --arg claim_id "${CLAIM_ID:-}" \
    --arg agent_id "${AGENT_ID:-}" \
    --arg spiffe_id "${SPIFFE_ID:-}" \
    --arg posture_score "${POSTURE_SCORE:-}" \
    --arg posture_percent "${POSTURE_PERCENT:-}" \
    --arg control_count "${CONTROL_COUNT:-}" \
    --arg audit_event_type "${AUDIT_EVENT_TYPE:-}" \
    --arg audit_action "${AUDIT_ACTION:-}" \
    --arg audit_actor "${AUDIT_ACTOR:-}" \
    --arg audit_timestamp "${AUDIT_TIMESTAMP:-}" \
    --argjson steps_completed "${STEP:-0}" \
    --argjson elapsed_seconds "${elapsed}" \
    '{
      schema_version: 1,
      status: $status,
      reason: (if $reason == "" then null else $reason end),
      steps_completed: $steps_completed,
      workload: $workload,
      pod_name: $pod,
      claim_id: $claim_id,
      agent_id: $agent_id,
      spiffe_id: $spiffe_id,
      controls_evaluated: (if $control_count == "" then null else ($control_count | tonumber) end),
      posture_score: (if $posture_score == "" then null else ($posture_score | tonumber) end),
      posture_percent: (if $posture_percent == "" then null else ($posture_percent | tonumber) end),
      audit: {
        stored_event_type: $audit_event_type,
        action: $audit_action,
        semantic_event_type: (if $audit_action == "claimed" then "agent.claimed" else null end),
        actor: $audit_actor,
        timestamp: $audit_timestamp
      },
      elapsed_seconds: $elapsed_seconds,
      orphan_background_processes: 0
    }' >"${tmp_result}"
  mv "${tmp_result}" "${RESULT_FILE}"
  RESULT_WRITTEN=1
}

cleanup() {
  local rc=$?
  if [[ -n "${TEMP_DIR}" ]]; then
    rm -rf -- "${TEMP_DIR}"
  fi
  if (( rc != 0 && RESULT_WRITTEN == 0 )); then
    write_result "fail" "unexpected failure; inspect the preceding diagnostic" || true
  fi
  trap - EXIT
  exit "${rc}"
}
trap cleanup EXIT

die() {
  local message="$1" hint="${2:-Inspect: make doctor}"
  printf '%s✗ ERROR:%s %s\n' "${RED}" "${RESET}" "${message}" >&2
  printf '  Troubleshooting: %s\n' "${hint}" >&2
  write_result "fail" "${message}"
  exit 1
}

hard_blocker() {
  local message="$1" evidence="$2"
  printf '%s✗ HARD BLOCKER:%s %s\n' "${RED}" "${RESET}" "${message}" >&2
  printf '  Evidence: %s\n' "${evidence}" >&2
  printf '  Stop condition reached; no alternate endpoint or cluster was attempted.\n' >&2
  write_result "fail" "${message}"
  exit 1
}

pass_step() {
  local message="$1"
  STEP=$((STEP + 1))
  printf '%s✓ [%d/7]%s %s\n' "${GREEN}" "${STEP}" "${RESET}" "${message}"
}

require_command() {
  local command_name="$1" install_hint="$2"
  command -v "${command_name}" >/dev/null 2>&1 || \
    die "required command '${command_name}' is unavailable" "${install_hint}"
}

mint_token() {
  local response
  # The single-quoted program expands only inside the dashboard container.
  # shellcheck disable=SC2016
  response="$({
    printf '%s\n' "${DEMO_USER}"
    printf '%s\n' "${DEMO_PASSWORD}"
    printf '%s\n' "${DEX_CLIENT}"
  } | kubectl -n "${API_NAMESPACE}" exec -i "deploy/${API_CLIENT_DEPLOYMENT}" -- sh -c '
    IFS= read -r demo_user
    IFS= read -r demo_password
    IFS= read -r dex_client
    exec curl -sS --max-time 15 -X POST \
      --data-urlencode "grant_type=password" \
      --data-urlencode "client_id=${dex_client}" \
      --data-urlencode "username=${demo_user}" \
      --data-urlencode "password=${demo_password}" \
      --data-urlencode "scope=openid profile email groups audience:server:client_id:signalloom-api" \
      http://localhost:8080/dex/token
  ')" || die "Dex token request failed" "Check Dex and dashboard readiness with: make doctor"

  TOKEN="$(jq -er '.id_token | select(type == "string" and length > 0)' <<<"${response}" 2>/dev/null)" || \
    die "Dex did not return a usable ID token" "Check demo credentials and the /dex/token route"
}

api_request() {
  local method="$1" path="$2" body="${3:-}" response
  # Tokens and bodies stay on stdin; the static shell program contains neither.
  # shellcheck disable=SC2016
  response="$({
    printf '%s\n' "${TOKEN}"
    printf '%s\n' "${body}"
  } | kubectl -n "${API_NAMESPACE}" exec -i "deploy/${API_CLIENT_DEPLOYMENT}" -- sh -c '
    IFS= read -r token
    IFS= read -r body
    method="$1"
    path="$2"
    if [ -n "${body}" ]; then
      exec curl -sS --max-time 15 -X "${method}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        --data-binary "${body}" \
        -w "\n__SLAC_HTTP_STATUS__:%{http_code}" \
        "http://localhost:8080${path}"
    fi
    exec curl -sS --max-time 15 -X "${method}" \
      -H "Authorization: Bearer ${token}" \
      -w "\n__SLAC_HTTP_STATUS__:%{http_code}" \
      "http://localhost:8080${path}"
  ' sh "${method}" "${path}")" || \
    die "API request failed for ${method} ${path}" "Check deployment/fe-signalloom and dashboard proxy readiness"

  [[ "${response}" == *$'\n__SLAC_HTTP_STATUS__:'* ]] || \
    die "API response omitted HTTP status for ${method} ${path}" "Inspect dashboard and fe-signalloom pod logs"
  HTTP_STATUS="${response##*$'\n__SLAC_HTTP_STATUS__:'}"
  API_BODY="${response%$'\n__SLAC_HTTP_STATUS__:'*}"
}

require_http_success() {
  local operation="$1"
  if [[ "${HTTP_STATUS}" =~ ^2[0-9][0-9]$ ]]; then
    return 0
  fi
  local api_error
  api_error="$(jq -r '.error.message // .detail // empty' <<<"${API_BODY}" 2>/dev/null || true)"
  die "${operation} returned HTTP ${HTTP_STATUS}${api_error:+: ${api_error}}" \
    "Inspect: kubectl -n ${API_NAMESPACE} logs deploy/fe-signalloom --tail=100"
}

reset_demo() {
  warn "Reset removes the shared demo agent registry and its linked governance evidence."
  "${SCRIPT_DIR}/signalloom-data.sh" reset agents
  kubectl -n "${API_NAMESPACE}" rollout restart deployment/fe-signalloom >/dev/null
  wait_rollout fe-signalloom -n "${API_NAMESPACE}" 45 || \
    die "fe-signalloom did not become ready after reset" "Run: make doctor"
  write_result "reset" "shared demo agent registry reset to discovered state"
  printf '%s✓%s Agent registry reset; running workloads will reappear as discovered.\n' \
    "${GREEN}" "${RESET}"
}

MODE="demo"
case "${1:-}" in
  "") ;;
  --reset) MODE="reset" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; die "unknown argument: ${1}" "Use --help for supported options" ;;
esac
[[ $# -le 1 ]] || die "too many arguments" "Use --help for supported options"

require_command kubectl "Install kubectl and configure the osramp Kind context"
require_command curl "Install curl; it is required by the in-cluster HTTP probe contract"
require_command jq "Install jq 1.6 or newer"
require_command date "Install GNU coreutils"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/slac-autoclaim.XXXXXX")"

log "${BOLD}════ SIGNAL LOOM — AGENT AUTO-CLAIM DEMONSTRATION ════${RESET}"
info "Evidence file: ${RESULT_FILE}"

if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
  hard_blocker "Kubernetes API server is unreachable" \
    "kubectl version --request-timeout=5s exited non-zero"
fi

if [[ "${MODE}" == "reset" ]]; then
  reset_demo
  exit 0
fi

wait_pods_ready "app.kubernetes.io/managed-by=kagent" -n "${AGENT_NAMESPACE}" 20 || \
  die "Kagent workloads did not become ready" \
    "Inspect: kubectl get pods -n ${AGENT_NAMESPACE} -o wide"
kubectl -n "${API_NAMESPACE}" exec "deploy/${API_CLIENT_DEPLOYMENT}" -- \
  sh -c 'command -v curl >/dev/null' || \
  die "dashboard pod lacks curl" "Rebuild the dashboard image with its runtime curl dependency"

mint_token
api_request GET "/api/agents?namespace=${AGENT_NAMESPACE}&limit=100"
require_http_success "agent inventory preflight"
AGENTS_JSON="${API_BODY}"

PODS_JSON="$(kubectl get pods -n "${AGENT_NAMESPACE}" \
  -l "signalloom.ai/agent=true" -o json)" || \
  die "failed to enumerate agent pods" "Inspect namespace ${AGENT_NAMESPACE}"

READY_WORKLOADS="$(jq -c '
  [.items[]
   | select(.status.phase == "Running")
   | select((.status.containerStatuses // []) | length > 0)
   | select([.status.containerStatuses[] | .ready] | all)
   | {
       pod: .metadata.name,
       workload: (.metadata.labels["app.kubernetes.io/name"] // .metadata.labels["signalloom.ai/agent-name"] // .metadata.name),
       service_account: (.spec.serviceAccountName // "default"),
       harness: (.metadata.labels["signalloom.ai/harness"] // .metadata.labels["signalloom.ai/framework"] // "kagent"),
       model: (.metadata.labels["signalloom.ai/model"] // "anthropic-claude")
     }]
  | sort_by([(.workload != "kagent-k8s-reader"), .workload])
' <<<"${PODS_JSON}")" || die "could not parse Kubernetes workload inventory" "Inspect kubectl pod JSON"

while IFS=$'\t' read -r workload pod service_account harness model; do
  [[ -n "${workload}" ]] || continue
  candidate="$(jq -c --arg name "${workload}" '
    [.agents[]
     | select(.name == $name)
     | select(.record_class == "discovered")
     | select(.is_registry_linked == false)
     | select((.compliance_summary.total_controls // 0) == 0)]
    | first // empty
  ' <<<"${AGENTS_JSON}")"
  if [[ -n "${candidate}" ]]; then
    TARGET_WORKLOAD="${workload}"
    TARGET_POD="${pod}"
    TARGET_SERVICE_ACCOUNT="${service_account}"
    TARGET_HARNESS="${harness}"
    TARGET_MODEL="${model}"
    INITIAL_AGENT="${candidate}"
    break
  fi
done < <(jq -r '.[] | [.workload, .pod, .service_account, .harness, .model] | @tsv' <<<"${READY_WORKLOADS}")

[[ -n "${TARGET_WORKLOAD}" ]] || \
  die "no running unclaimed agent with zero controls was found" \
    "Run '${SCRIPT_DIR}/demo-agent-autoclaim.sh --reset' to restore discovered state"

DISCOVERY_EPOCH="$(date +%s)"
pass_step "Discovered running workload ${TARGET_WORKLOAD} (pod ${TARGET_POD})"

INITIAL_CONTROLS="$(jq -r '.compliance_summary.total_controls // 0' <<<"${INITIAL_AGENT}")"
INITIAL_LINKED="$(jq -r '.is_registry_linked' <<<"${INITIAL_AGENT}")"
INITIAL_POSTURE="$(jq -r '.compliance_summary.posture_score // 0' <<<"${INITIAL_AGENT}")"
[[ "${INITIAL_LINKED}" == "false" && "${INITIAL_CONTROLS}" == "0" ]] || \
  die "selected workload was not initially unclaimed" "Refresh /api/agents and choose a discovered record"
pass_step "Initial state: unclaimed, ${INITIAL_CONTROLS} controls, ${INITIAL_POSTURE}% posture"

SPIFFE_ID="spiffe://signalloom.demo/ns/${AGENT_NAMESPACE}/sa/${TARGET_SERVICE_ACCOUNT}"
CLAIM_PAYLOAD="$(jq -nc \
  --arg pod_name "${TARGET_WORKLOAD}" \
  --arg namespace "${AGENT_NAMESPACE}" \
  --arg spiffe_id "${SPIFFE_ID}" \
  --arg harness "${TARGET_HARNESS:-kagent}" \
  --arg model "${TARGET_MODEL:-anthropic-claude}" \
  --argjson token_budget_limit "${TOKEN_BUDGET_LIMIT}" \
  '{pod_name:$pod_name, namespace:$namespace, spiffe_id:$spiffe_id,
    harness:$harness, model:$model, declared_tools:["k8s_get_resources"],
    token_budget_limit:$token_budget_limit}')"

api_request POST "/api/v1/agents/claim" "${CLAIM_PAYLOAD}"
if [[ "${HTTP_STATUS}" == "500" ]]; then
  api_error="$(jq -r '.error.message // .detail // "internal server error"' <<<"${API_BODY}" 2>/dev/null || true)"
  hard_blocker "Claim API returned HTTP 500" "${api_error}"
fi
require_http_success "agent claim"

CLAIM_STATUS="$(jq -er '.status' <<<"${API_BODY}")" || die "claim response omitted status" "Inspect the claim API response contract"
SVID_VERIFIED="$(jq -er '.spiffe_svid_verified' <<<"${API_BODY}")" || die "claim response omitted SPIFFE verification" "Inspect the claim API response contract"
CLAIM_ID="$(jq -er '.claim_id | select(type == "string" and length > 0)' <<<"${API_BODY}")" || die "claim response omitted claim_id" "Inspect the claim API response contract"
AGENT_ID="$(jq -er '.agent_id | select(type == "string" and length > 0)' <<<"${API_BODY}")" || die "claim response omitted agent_id" "Inspect the claim API response contract"
ALLOCATED_BUDGET="$(jq -er '.allocated_token_budget' <<<"${API_BODY}")" || die "claim response omitted allocated budget" "Inspect the claim API response contract"
[[ "${CLAIM_STATUS}" == "granted" && "${SVID_VERIFIED}" == "true" && "${ALLOCATED_BUDGET}" == "${TOKEN_BUDGET_LIMIT}" ]] || \
  die "claim response failed governance assertions" "Expected granted, verified=true, budget=${TOKEN_BUDGET_LIMIT}"
pass_step "Claim granted (${CLAIM_ID}); SPIFFE SVID verified"

api_request GET "/api/agents?search=${TARGET_WORKLOAD}&limit=100"
require_http_success "post-claim registry lookup"
REGISTERED_AGENT="$(jq -c --arg name "${TARGET_WORKLOAD}" '
  [.agents[]
   | select(.name == $name)
   | select(.is_registry_linked == true)
   | select(.record_class == "resolved")]
  | first // empty
' <<<"${API_BODY}")"
[[ -n "${REGISTERED_AGENT}" ]] || \
  die "claimed workload was not linked in agent_registry" "Inspect agent_registry and /api/agents reconciliation"
REGISTRY_AGENT_ID="$(jq -r '.id' <<<"${REGISTERED_AGENT}")"
[[ "${REGISTRY_AGENT_ID}" == "${AGENT_ID}" ]] || \
  die "claim agent_id does not match registry record" "Claim=${AGENT_ID}; registry=${REGISTRY_AGENT_ID}"
pass_step "Registered ${TARGET_WORKLOAD} in agent_registry as ${AGENT_ID}"

CONTROL_COUNT="$(jq -er '.compliance_summary.total_controls' <<<"${REGISTERED_AGENT}")"
PASSING_CONTROLS="$(jq -er '.compliance_summary.passing' <<<"${REGISTERED_AGENT}")"
FAILING_CONTROLS="$(jq -er '.compliance_summary.failing' <<<"${REGISTERED_AGENT}")"
PENDING_CONTROLS="$(jq -er '.compliance_summary.pending' <<<"${REGISTERED_AGENT}")"
POSTURE_SCORE="$(jq -er '.compliance_summary.posture_score' <<<"${REGISTERED_AGENT}")"
POSTURE_PERCENT="$(jq -n --argjson passing "${PASSING_CONTROLS}" --argjson total "${CONTROL_COUNT}" \
  'if $total > 0 then (($passing * 100 / $total) | round) else 0 end')"
SCORE_PERCENT="$(jq -n --argjson score "${POSTURE_SCORE}" '($score * 100 | round)')"
[[ "${CONTROL_COUNT}" == "6" && "${POSTURE_PERCENT}" -gt 0 && "${POSTURE_PERCENT}" == "${SCORE_PERCENT}" ]] || \
  die "compliance posture assertion failed" \
    "Expected 6 controls and a calculated positive score; observed ${CONTROL_COUNT} controls at ${POSTURE_SCORE}"
pass_step "Evaluated ${CONTROL_COUNT} controls: ${PASSING_CONTROLS} pass, ${FAILING_CONTROLS} fail, ${PENDING_CONTROLS} pending (${POSTURE_PERCENT}%)"

api_request GET "/api/audit?limit=100"
require_http_success "audit trail lookup"
AUDIT_EVENT="$(jq -c --arg name "${TARGET_WORKLOAD}" --arg claim_id "${CLAIM_ID}" '
  [.events[]
   | select(.agent_name == $name)
   | select(.detail.action == "claimed")
   | select(.detail.claim_id == $claim_id)]
  | first // empty
' <<<"${API_BODY}")"
[[ -n "${AUDIT_EVENT}" ]] || \
  die "claim audit event was not recorded" "Inspect /api/audit and audit_events for claim ${CLAIM_ID}"
AUDIT_EVENT_TYPE="$(jq -er '.event_type' <<<"${AUDIT_EVENT}")"
AUDIT_ACTION="$(jq -er '.detail.action' <<<"${AUDIT_EVENT}")"
AUDIT_ACTOR="$(jq -er '.actor | select(type == "string" and length > 0)' <<<"${AUDIT_EVENT}")" || \
  die "claim audit event omitted actor" "Inspect audit_events actor attribution"
AUDIT_TIMESTAMP="$(jq -er '.timestamp | select(type == "string" and length > 0)' <<<"${AUDIT_EVENT}")" || \
  die "claim audit event omitted timestamp" "Inspect audit_events timestamp"
[[ "${AUDIT_ACTION}" == "claimed" ]] || die "claim audit action was not claimed" "Observed action=${AUDIT_ACTION}"
if [[ "${AUDIT_EVENT_TYPE}" != "agent.claimed" ]]; then
  warn "Stored audit vocabulary is '${AUDIT_EVENT_TYPE}' with action='claimed'; semantic event is agent.claimed."
fi
pass_step "Audit recorded agent.claimed semantics for ${TARGET_WORKLOAD} by ${AUDIT_ACTOR}"

ELAPSED_FROM_DISCOVERY=$(( $(date +%s) - DISCOVERY_EPOCH ))
(( ELAPSED_FROM_DISCOVERY < 60 )) || \
  die "discovery-to-verification exceeded 60 seconds" "Observed ${ELAPSED_FROM_DISCOVERY}s; inspect wait telemetry"
write_result "pass"
pass_step "Evidence saved in ${RESULT_FILE}; verified in ${ELAPSED_FROM_DISCOVERY}s"

log ""
log "${BOLD}════ VERIFIED GOVERNANCE EVIDENCE ════${RESET}"
printf '  %-22s %s\n' "Workload" "${TARGET_WORKLOAD}"
printf '  %-22s %s\n' "Claim ID" "${CLAIM_ID}"
printf '  %-22s %s\n' "Registry agent ID" "${AGENT_ID}"
printf '  %-22s %s\n' "SPIFFE identity" "${SPIFFE_ID}"
printf '  %-22s %s%% (%s/%s passing)\n' "Compliance posture" "${POSTURE_PERCENT}" "${PASSING_CONTROLS}" "${CONTROL_COUNT}"
printf '  %-22s %s / action=%s\n' "Stored audit event" "${AUDIT_EVENT_TYPE}" "${AUDIT_ACTION}"
printf '  %-22s %ss\n' "Discovery → proof" "${ELAPSED_FROM_DISCOVERY}"
printf '  %-22s %s\n' "Background processes" "0 created"
log "${GREEN}${BOLD}PASS: all seven demonstration steps completed.${RESET}"
